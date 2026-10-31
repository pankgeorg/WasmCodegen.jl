# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`): a program of @async tasks, Channels,
# Conditions, fetch, sleep, exceptions across waits, Timers, Events and @sync, with
# interleavings that check task-local runtime state, whose output (stdout) is compared with
# native Julia's (`main`). The other exports run in Wasm only (they wait on the host's
# handles, or check the host's lifecycle): `pingpong(n)` measures task switches;
# `downloads(port, n, workers)` fetches n URLs with a pool of tasks.

module TasksProgram

using Random
import WasmCodegen
const H = WasmCodegen.Runtime.Host
const IO_ = WasmCodegen.Runtime.JuliaIO

# producer/consumer over a buffered Channel
function producer_consumer()
    c = Channel{Int}(2)
    p = @async begin
        for i in 1:5
            put!(c, i)
            println(Core.stdout, "put ", i)
        end
        close(c)
        :producer_done
    end
    s = 0
    for x in c
        println(Core.stdout, "took ", x)
        s += x
    end
    println(Core.stdout, "sum ", s, " ", fetch(p)::Symbol)
end

# wait/notify on a Condition, passing a value
function condition_notify()
    cond = Condition()
    w = @async begin
        v = wait(cond)::Int
        println(Core.stdout, "woken with ", v)
        2v
    end
    yield()
    println(Core.stdout, "notified ", notify(cond, 21))
    println(Core.stdout, "fetch ", fetch(w)::Int)
end

# fetch of a task's result after a sleep inside it; sleeps interleave
function sleeps()
    t = @async (sleep(0.02); 6 * 7)
    println(Core.stdout, "fetch2 ", fetch(t)::Int)
    out = String[]
    # (Task handles kept typed: `@sync`'s Vector{Any} is a dynamic `wait`, not trim-safe)
    ts = Task[@async((sleep(0.06); push!(out, "slow"))),
              @async((sleep(0.01); push!(out, "fast"))),
              @async((sleep(0.03); push!(out, "mid")))]
    foreach(wait, ts)
    println(Core.stdout, join(out, ","))
end

# exceptions crossing waits
function exceptions()
    # a Channel closed while a task waits in take!: InvalidStateException in that task
    c = Channel{Int}(0)
    t = @async try
        take!(c)
        "no"
    catch e
        e isa InvalidStateException ? "closed: " * e.msg : "other"
    end
    yield()
    close(c)
    println(Core.stdout, "t ", fetch(t)::String)
    # a task that throws after a wait: fetch throws TaskFailedException
    t3 = @async (sleep(0.001); error("boom"))
    try
        fetch(t3)
        println(Core.stdout, "t3 no error")
    catch e
        r = e isa TaskFailedException ? (e.task.result::ErrorException).msg::String : "other"
        println(Core.stdout, "t3 failed: ", r, " ", istaskfailed(t3))
    end
    # an exception thrown into a waiting task
    cnd = Condition()
    t4 = @async try
        wait(cnd)
        "no"
    catch e
        "got " * (e::ErrorException).msg::String
    end
    yield()
    schedule(t4, ErrorException("interrupt"); error=true)
    println(Core.stdout, "t4 ", fetch(t4)::String)
    # try/finally across a wait, unwinding in a task
    log = String[]
    t5 = @async try
        try
            sleep(0.001)
            throw(ArgumentError("inner"))
        finally
            push!(log, "finally")
        end
    catch e
        push!(log, "caught " * (e::ArgumentError).msg::String)
    end
    wait(t5)
    println(Core.stdout, "t5 ", join(log, ";"))
end

# task-local state: storage and the RNG stream are per task
function task_local()
    task_local_storage(:k, 1)
    t = @async begin
        task_local_storage(:k, 5)
        sleep(0.001)
        task_local_storage(:k)::Int
    end
    yield()
    println(Core.stdout, "tls ", fetch(t)::Int, " ", task_local_storage(:k)::Int)
end

# many tasks, a pool of workers over a Channel of jobs
function pool()
    jobs = Channel{Int}(100)
    results = Channel{Pair{Int,Int}}(100)
    for i in 1:20
        put!(jobs, i)
    end
    close(jobs)
    ts = Task[]
    for w in 1:4
        t = @async for j in jobs
            sleep(0.001 * (j % 3))
            put!(results, j => j * j)
        end
        push!(ts, t)
    end
    foreach(wait, ts)
    close(results)
    total = 0
    n = 0
    for (j, sq) in results
        total += sq
        n += 1
    end
    println(Core.stdout, "pool ", n, " ", total)
end

# the root task's state before any other task exists (first in `main`)
function root_state()
    task_local_storage(:root, 1)
    println(Core.stdout, "root tls ", task_local_storage(:root)::Int, " started ", istaskstarted(current_task()))
end

# the current exception is per task: two tasks suspended in catch blocks each
# rethrow their own; a task started in a handler has none; the handler's is kept
function rethrow_interleaved()
    a = @async try
        try
            error("A")
        catch
            yield(); yield()
            rethrow()
        end
    catch e
        (e::ErrorException).msg
    end
    b = @async try
        try
            error("B")
        catch
            yield(); yield()
            rethrow()
        end
    catch e
        (e::ErrorException).msg
    end
    println(Core.stdout, "rethrow ", fetch(a)::String, " ", fetch(b)::String)
    try
        error("root")
    catch
        t = @async try
            rethrow()
            "no error"
        catch e
            e isa ErrorException ? e.msg : "other"
        end
        println(Core.stdout, "new task in a handler: ", fetch(t)::String)
        try
            rethrow()
        catch e
            println(Core.stdout, "the handler's own: ", (e::ErrorException).msg::String)
        end
    end
end

# a task yielding in a loop does not starve a timer another task waits for
function yield_until_timer()
    flag = Ref(false)
    t = @async (sleep(0.005); flag[] = true)
    n = 0
    while !flag[]
        yield()
        n += 1
    end
    wait(t)
    println(Core.stdout, "timer fired while yielding: ", flag[], " ", n > 0)
end

# Timer (one-shot, interval, callback, closed while waited), timedwait, Event
function timers()
    t = Timer(0.01)
    wait(t)
    println(Core.stdout, "one-shot fired, open ", isopen(t))
    n = 0
    ti = Timer(0.005; interval=0.005)
    for i in 1:3
        wait(ti)
        n += 1
    end
    close(ti)
    println(Core.stdout, "interval ", n, " open ", isopen(ti))
    hits = Ref(0)
    tc = Timer(_ -> (hits[] += 1), 0.002; interval=0.002)
    r = timedwait(() -> hits[] >= 3, 5.0; pollint=0.001)
    close(tc)
    println(Core.stdout, "callback ", r, " ", hits[] >= 3)
    t2 = Timer(10.0)
    w = @async try
        wait(t2)
        "fired"
    catch e
        e isa EOFError ? "EOFError" : "other"
    end
    yield()
    close(t2)
    println(Core.stdout, "closed while waited: ", fetch(w)::String)
    println(Core.stdout, "timedwait ", timedwait(() -> false, 0.02; pollint=0.005))
    ev = Base.Event()
    ws = Task[@async((wait(ev); i)) for i in 1:3]
    yield()
    notify(ev)
    println(Core.stdout, "event ", sum(fetch(x)::Int for x in ws))
end

# errormonitor: the failure goes to stderr (not compared: natively with a backtrace)
function monitor()
    t = errormonitor(@async error("monitored"))
    try
        wait(t)
    catch
    end
    yield()
    println(Core.stdout, "monitored failed ", istaskfailed(t))
end

# Channel(f) and bind; close with blocked producers; several waiters for one task
function channels()
    c = Channel{Int}(2) do ch
        for i in 1:4
            put!(ch, i)
        end
    end
    s = 0
    for x in c
        s += x
    end
    println(Core.stdout, "channel(f) ", s, " ", isopen(c))
    d = Channel{Int}(0) do ch
        put!(ch, 1)
        error("producer failed")
    end
    v = take!(d)
    r = try
        take!(d)
        "no error"
    catch e
        e isa TaskFailedException ? "TaskFailedException" : e isa InvalidStateException ? "closed" : "other"
    end
    println(Core.stdout, "bind failure ", v, " ", r)
    ch0 = Channel{Int}(0)
    ps = Task[@async(try
                         put!(ch0, i)
                         "put"
                     catch x
                         x isa InvalidStateException ? "closed" : "other"
                     end) for i in 1:2]
    yield()
    close(ch0)
    println(Core.stdout, "blocked producers: ", fetch(ps[1])::String, ",", fetch(ps[2])::String)
    t = @async (sleep(0.002); 7)
    ws = Task[@async(fetch(t)::Int + i) for i in 1:3]
    println(Core.stdout, "waiters ", fetch(ws[1])::Int, " ", fetch(ws[2])::Int, " ", fetch(ws[3])::Int)
end

# @sync collects failures in a CompositeException; Threads.@spawn runs a task
function sync_spawn()
    r = try
        @sync begin
            @async (sleep(0.001); error("e1"))
            Threads.@spawn error("e2")
            @async 1
        end
        "no error"
    catch e
        e isa CompositeException ? string("CompositeException ", length(e.exceptions)) : "other"
    end
    println(Core.stdout, "sync ", r)
    t = Threads.@spawn (yield(); 40 + 2)
    println(Core.stdout, "spawn ", fetch(t)::Int)
end

# the random streams of tasks: split from the parent's (`jl_rng_split`), as natively
function rng()
    Random.seed!(1234)
    a = fetch(@async rand(UInt64))::UInt64
    b = fetch(@async rand(UInt64))::UInt64
    c = rand(UInt64)
    println(Core.stdout, "rng ", a, " ", b, " ", c, " ", a != b)
end

# a task inherits the scope it was created in (the field `ScopedValue`s read; `with` itself
# is not trim-safe: Base's HAMT insert is a dynamic call)
function scoped()
    ct = current_task()
    old = getfield(ct, :scope)
    setfield!(ct, :scope, :marker)
    t = @async getfield(current_task(), :scope)
    setfield!(ct, :scope, old)
    println(Core.stdout, "scope in a task ", fetch(t)::Symbol, ", restored ", getfield(ct, :scope) === old)
end

function started()
    t = Task(() -> 1)
    a = istaskstarted(t)
    schedule(t)
    b = istaskstarted(t)
    wait(t)
    println(Core.stdout, "started ", a, " ", b, " ", istaskstarted(t), " ", istaskdone(t))
end

# two tasks end one after the other, the second creating a task that takes the first's id
function id_reuse()
    c = Channel{Nothing}(0)
    a = @async nothing
    b = @async begin
        @async put!(c, nothing)
    end
    take!(c)
    wait(a)
    wait(fetch(b)::Task)
    println(Core.stdout, "id reuse ok")
end

function main()::Int32
    root_state()
    producer_consumer()
    condition_notify()
    sleeps()
    exceptions()
    task_local()
    pool()
    rethrow_interleaved()
    yield_until_timer()
    timers()
    monitor()
    channels()
    sync_spawn()
    rng()
    scoped()
    started()
    id_reuse()
    println(Core.stdout, "done")
    return Int32(0)
end

# `n` round trips between two tasks over yield(): the elapsed ns
function pingpong(n::Int32)::Int64
    t0 = time_ns()
    t = @async for i in 1:n
        yield()
    end
    for i in 1:n
        yield()
    end
    wait(t)
    return Int64(time_ns() - t0)
end

# the same, while the host has outstanding work (a timer): switches hand over to the event loop
function pingpong_busy(n::Int32)::Int64
    t = Timer(60.0)
    try
        return pingpong(n)
    finally
        close(t)
    end
end

# `n` round trips over two unbuffered Channels: the elapsed ns
function pingpong_channel(n::Int32)::Int64
    a = Channel{Int}(0)
    b = Channel{Int}(0)
    t0 = time_ns()
    t = @async for i in 1:n
        put!(b, take!(a) + 1)
    end
    x = 0
    for i in 1:n
        put!(a, x)
        x = take!(b)
    end
    wait(t)
    return x == n ? Int64(time_ns() - t0) : Int64(-1)
end

## a download pool (a Channel of jobs, worker tasks) over the host's HTTP

# download `/blob/1` ... `/blob/n` from the server at `port` with `workers` tasks (1: serially)
# into files: the elapsed µs, or -1 if a file is not of the size the server sent
function downloads(port::Int32, n::Int32, workers::Int32)::Int64
    dir = ENV["HOME"]
    base = string("http://127.0.0.1:", port, "/blob/")
    jobs = Channel{Int}(Int(n))
    for i in 1:Int(n)
        put!(jobs, i)
    end
    close(jobs)
    t0 = time_ns()
    ts = Task[]
    for w in 1:Int(workers)
        t = @async for i in jobs
            head = H.http_download(base * string(i), joinpath(dir, string("blob", i)), Pair{String,String}[])
            head.status == 200 || error("HTTP ", head.status)
        end
        push!(ts, t)
    end
    foreach(wait, ts)
    us = Int64((time_ns() - t0) ÷ 1000)
    for i in 1:Int(n)
        filesize(joinpath(dir, string("blob", i))) == 65536 + i || return Int64(-1)
    end
    return us
end

# `main`, reporting an exception's text
function main_safe()::Int32
    try
        return main()
    catch e
        println(Core.stdout, "ERROR: ", H.error_text(e))
        return Int32(1)
    end
end

## Wasm only: the host's handles and the host's lifecycle

# several tasks wait for one host handle; an interrupted waiter's cleanup keeps
# the others' registrations
function shared_handle()::Int32
    h = IO_.timer_start(Int64(20_000_000))
    try
        ws = Task[@async((H.await_handle(h); i)) for i in 1:3]
        intr = @async try
            H.await_handle(h)
            "not interrupted"
        catch e
            (e::ErrorException).msg
        end
        yield()
        schedule(intr, ErrorException("interrupted"); error=true)
        r = fetch(intr)::String
        s = fetch(ws[1])::Int + fetch(ws[2])::Int + fetch(ws[3])::Int
        println(Core.stdout, "shared ", s, " ", r)
    finally
        IO_.close(h)
    end
    return Int32(0)
end

# a wait for a handle that nothing can make ready any more: EINVAL, as with one task; another
# task waiting for a timer meanwhile is not disturbed
function dead_handle(port::Int32)::Int32
    h = H.http_start("GET", string("http://127.0.0.1:", port, "/small"), Pair{String,String}[])
    try
        head = H.http_head(h)
        buf = Vector{UInt8}(undef, 64)
        while H.http_read!(h, head, buf) != 0 end
        t = @async (sleep(0.01); :slept)
        r = try
            H.await_handle(h)
            Int32(0)
        catch e
            e isa H.HostCallError ? e.errno : Int32(-1)
        end
        println(Core.stdout, "dead handle ", r, " ", fetch(t)::Symbol)
        return r
    finally
        IO_.close(h)
    end
end

# two tasks wait for one HTTP request; one reads it to its end (retiring its readiness):
# the other is woken, and is not left waiting forever
function http_shared(port::Int32)::Int32
    h = H.http_start("GET", string("http://127.0.0.1:", port, "/delayed"), Pair{String,String}[])
    try
        reader = @async begin
            head = H.http_head(h)
            buf = Vector{UInt8}(undef, 64)
            got = 0
            while (k = H.http_read!(h, head, buf)) != 0
                got += k
            end
            got
        end
        waiter = @async try
            H.await_handle(h)
            Int32(0)
        catch e
            e isa H.HostCallError ? e.errno : Int32(-1)
        end
        n = fetch(reader)::Int
        w = fetch(waiter)::Int32
        println(Core.stdout, "http shared ", n, " ", w == 0 || w == H.EINVAL)
        return Int32(n)
    finally
        IO_.close(h)
    end
end

# returns while a task waits forever: the host keeps it parked (the next root call may run)
function early_return()::Int32
    c = Condition()
    @async wait(c)
    yield()
    return Int32(0)
end

# a deadlock in a task: thrown there (natively: a hang)
function deadlock_child()::Int32
    c = Condition()
    t = @async wait(c)
    try
        wait(t)
        return Int32(0)
    catch e
        ok = e isa TaskFailedException && e.task.result isa ConcurrencyViolationError
        return ok ? Int32(1) : Int32(2)
    end
end

# a deadlock of the root task: thrown there
function deadlock_root()::Int32
    try
        wait(Condition())
        return Int32(0)
    catch e
        return e isa ConcurrencyViolationError ? Int32(1) : Int32(2)
    end
end

# traps (a stack overflow) in a task and in the root: the root call fails
@noinline deep(n::Int) = n == 0 ? 0 : 1 + deep(n - 1)
child_trap(n::Int32)::Int32 = Int32(fetch(@async deep(Int(n)))::Int)
root_trap(n::Int32)::Int32 = Int32(deep(Int(n)))

# `k` rounds of `n` tasks alive at once (each yields once): the sum of their results; the
# ids are reused
function stress(k::Int32, n::Int32)::Int64
    total = 0
    for _ in 1:k
        ts = Task[@async((yield(); i)) for i in 1:Int(n)]
        for t in ts
            total += fetch(t)::Int
        end
    end
    return Int64(total)
end

# the only task yields while its HTTP request is in flight, waiting for no handle: the host's
# event loop still runs (the request completes); the status
function lone_yield(port::Int32)::Int32
    h = H.http_start("GET", string("http://127.0.0.1:", port, "/delayed"), Pair{String,String}[])
    try
        while true
            n, r = H.try_head(h, H.HEAD_CAP)
            r isa H.Head && return Int32(r.status)
            n == -H.EAGAIN || return Int32(-1)
            yield()
        end
    finally
        IO_.close(h)
    end
end

# `n` Tasks created and never run hold no task id: then a task runs; its result * 2^32 + the
# live task ids
function discarded(n::Int32)::Int64
    for i in 1:Int(n)
        Task(() -> i)
    end
    v = fetch(@async 7)::Int
    _, _, live = WasmCodegen.Runtime.Tasks.stats()
    return Int64(v) << 32 | Int64(live)
end

"(switches, polls, live task ids) of the module, as one number: switches * 2^32 + live"
function task_stats()::Int64
    sw, _, live = WasmCodegen.Runtime.Tasks.stats()
    return Int64(sw) << 32 | Int64(live)
end

end # TasksProgram
