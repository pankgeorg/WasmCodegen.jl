# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`): a program of @async tasks, Channels,
# Conditions, fetch, sleep, exceptions across waits, Timers, Events and @sync, with
# interleavings that check task-local runtime state, whose output (stdout) is compared with
# native Julia's (`main`). The other exports run in Wasm only (they wait on the host's
# handles, or check the host's lifecycle): `pingpong(n)` measures task switches.

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
    # (the sleeps start together, once each task runs: natively, compiling a task's code when it
    # first runs may take longer than the sleeps differ; and the wide gaps make the order less
    # sensitive to the program being paused between their starts)
    go = Base.Event()
    # (Task handles kept typed: `@sync`'s Vector{Any} is a dynamic `wait`, not trim-safe)
    ts = Task[@async((wait(go); sleep(0.2); push!(out, "slow"))),
              @async((wait(go); sleep(0.01); push!(out, "fast"))),
              @async((wait(go); sleep(0.1); push!(out, "mid")))]
    yield()
    notify(go)
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
# the build's root task, held weakly (as a per-task cache's key): the module's root task, the one
# `main` runs in; a spawned task is another
const ROOT_REF = WeakRef(Base.roottask)
function root_ref()
    t = @async current_task() !== Base.roottask && ROOT_REF.value === Base.roottask
    println(Core.stdout, "root ref ", ROOT_REF.value === current_task(), " ", ROOT_REF.value === Base.roottask,
            " ", fetch(t)::Bool)
end

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

## as natively: the scheduler's order, its waits and the task's fields

spin(ms) = (t0 = time_ns(); while time_ns() - t0 < ms * 1_000_000 end)

# `sleep(0)` lets a runnable task run (natively it waits for a `Timer` of 0)
function sleep_zero()
    flag = Ref(false)
    t = @async (flag[] = true; nothing)
    n = 0
    while !flag[] && n < 1000
        sleep(0)
        n += 1
    end
    wait(t)
    println(Core.stdout, "sleep(0) ", flag[], " ", n)
end

# the host's events before the next task (Julia 1.13: a timer due fires first) or after (1.12)
function events_order()
    tm0 = Timer(0)
    t0 = @async isopen(tm0)
    println(Core.stdout, "timer of 0 open in a task ", fetch(t0)::Bool)
    close(tm0)
    tm = Timer(0.005)
    spin(20)
    t = @async isopen(tm)
    println(Core.stdout, "timer due open in a task ", fetch(t)::Bool)
    close(tm)
end

# `close(::Timer)` waits for the close to complete: other tasks run meanwhile
function close_waits()
    tm = Timer(100)
    t = @async print(Core.stdout, "A")
    close(tm)
    print(Core.stdout, "B")
    wait(t)
    println(Core.stdout, " ", isopen(tm))
end

# a sticky task scheduled from a task not stuck to the thread sticks it; the thread of a task
# not scheduled yet
function sticky()
    t = Threads.@spawn begin
        c = Task(() -> nothing)
        schedule(c)
        wait(c)
        current_task().sticky
    end
    u = Task(() -> nothing)
    print(Core.stdout, "sticky ", fetch(t)::Bool, " ", t.sticky)
    println(Core.stdout, ", threads ", Threads.threadid(u), " ", Threads.threadid(t), " ", Threads.threadid(current_task()))
end

# what `@sync` waits for: tasks, and other objects (a Timer, an Event, a Channel), and what it
# cannot wait for (natively a `MethodError`)
function sync_objects()
    c = Channel{Any}(8)
    put!(c, Timer(0.001))
    ev = Base.Event()
    notify(ev)
    put!(c, ev)
    ch = Channel{Any}(1)
    put!(ch, 1)
    put!(c, ch)
    put!(c, 42)
    r = try
        Base.sync_end(c)
        "no error"
    catch e
        e isa CompositeException ? string(length(e.exceptions), " ", first(e.exceptions) isa MethodError) : "other"
    end
    println(Core.stdout, "sync objects ", r)
end

# the fields of tasks: priority, body, started
function task_fields()
    t = @async (yield(); 1)
    p0 = t.priority
    wait(t)
    u = Task(() -> 2)
    print(Core.stdout, "fields ", p0, " ", t.priority, " ", u.priority)
    println(Core.stdout, " ", t.code isa Function, " ", istaskstarted(u), " ", istaskstarted(t))
end

# a repeating timer late (the program busy): the next time is an interval after it fired
function interval_late()
    tm = Timer(0.05; interval=0.05)
    t0 = time_ns()
    spin(130)
    wait(tm)
    t1 = (time_ns() - t0) / 1e6
    wait(tm)
    t2 = (time_ns() - t0) / 1e6
    close(tm)
    println(Core.stdout, "interval late ", t1 >= 125, " ", t2 - t1 >= 40)
end

# timers fire in the order of their deadlines, then of their start
function timers_order()
    out = Int[]
    tms = [Timer(0.02), Timer(0.01), Timer(0.01)]
    ts = Task[@async((wait(tms[i]); push!(out, i))) for i in 1:3]
    foreach(wait, ts)
    println(Core.stdout, "timers order ", join(out, ","))
end

# an error in a Timer's callback: on stderr (compared with native's but its backtrace)
function timer_error()
    tm = Timer(_ -> error("in a callback"), 0.001)
    sleep(0.05)
    println(Core.stderr)
    println(Core.stdout, "timer error, open ", isopen(tm))
    close(tm)
end

# transfers to a task that ended: `throwto` (`jl_switch`'s error), `schedule`, `yieldto`
function exited_switch()
    t = @async nothing
    wait(t)
    r = try
        Base.throwto(t, ErrorException("x"))
        "no error"
    catch e
        e isa ErrorException ? (e::ErrorException).msg::String : "other"
    end
    s = try
        schedule(t)
        "no error"
    catch e
        e isa ErrorException ? (e::ErrorException).msg::String : "other"
    end
    println(Core.stdout, "exited: ", r, "; ", s, "; ", yieldto(t, 5)::Int)
end

# the thread of a task waiting: none for one not sticky (`Threads.@spawn`), the one for a
# sticky one
function waiting_threads()
    c = Condition()
    s = Threads.@spawn wait(c)
    yield()
    a = Threads.threadid(s)
    notify(c)
    wait(s)
    u = @async wait(c)
    yield()
    b = Threads.threadid(u)
    notify(c)
    wait(u)
    println(Core.stdout, "threads of waiting tasks ", a, " ", Threads.threadid(s), " ", b)
end

# more timers than a host poll takes
function many_timers()
    ts = [Timer(60) for _ in 1:1500]
    yield()
    yield()
    foreach(close, ts)
    println(Core.stdout, "many timers, open ", count(isopen, ts))
end

# `@sync` of a Channel of an element type other than `Any`
function sync_typed_channel()
    q = Channel{Any}(2)
    c = Channel{Int}(1)
    put!(c, 1)
    put!(q, c)
    Base.sync_end(q)
    println(Core.stdout, "sync of a Channel{Int}: ", isready(c))
end

# a type of the program's own with a `wait` of its own, which `@sync` waits for (its case is
# compiled with the program's options: the host's clock)
struct Turn end
function Base.wait(::Turn)
    time() > 0 || error("no clock")
    yield()
    return nothing
end
function sync_own_wait()
    q = Channel{Any}(1)
    put!(q, Turn())
    r = try
        Base.sync_end(q)
        "no error"
    catch e
        e isa CompositeException ? string(typeof(first(e.exceptions))) : "other"
    end
    println(Core.stdout, "sync of a type's own wait: ", r)
end

# an exception of the program's, with its `showerror`: on stderr as natively (`errormonitor`)
struct MyError <: Exception
    code::Int
end
Base.showerror(io::IO, e::MyError) = print(io, "MyError with code ", e.code)
function monitor_own()
    t = errormonitor(@async throw(MyError(7)))
    try
        wait(t)
    catch
    end
    yield()
    println(Core.stdout, "own error monitored ", istaskfailed(t))
end

function main()::Int32
    root_state()
    root_ref()
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
    monitor_own()
    channels()
    sync_spawn()
    rng()
    scoped()
    started()
    id_reuse()
    sleep_zero()
    events_order()
    close_waits()
    sticky()
    sync_objects()
    task_fields()
    interval_late()
    timers_order()
    timer_error()
    exited_switch()
    waiting_threads()
    many_timers()
    sync_typed_channel()
    sync_own_wait()
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

# returns while a task waits forever: the host keeps it parked (the next root call may run)
function early_return()::Int32
    c = Condition()
    @async wait(c)
    yield()
    return Int32(0)
end

# deadlocks: the program waits forever, as natively (the root call does not return): in a
# task, in the root task, and after the end of the last task that could run
function deadlock_child()::Int32
    c = Condition()
    t = @async wait(c)
    wait(t)
    return Int32(0)
end
deadlock_root()::Int32 = (wait(Condition()); Int32(0))
function deadlock_exit()::Int32
    @async nothing
    wait(Condition())
    return Int32(0)
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

# sleeps (in the host's poll) while the host shuts down: it does not run any more
sleep_then_print()::Int32 = (sleep(0.1); println(Core.stdout, "after the shutdown"); Int32(0))

"(switches, polls, live task ids) of the module, as one number: switches * 2^32 + live"
function task_stats()::Int64
    sw, _, live = WasmCodegen.Runtime.Tasks.stats()
    return Int64(sw) << 32 | Int64(live)
end

end # TasksProgram
