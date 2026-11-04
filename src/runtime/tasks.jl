# Julia Tasks on JSPI stacks, for `Config(tasks = :jspi)` (the `julia_task` imports, which
# `js/julia_task.mjs` provides).
#
# Base's scheduler stays in charge: `schedule`, `yield`, `yieldto`, `Condition`, `Channel`,
# `ReentrantLock`, `Event`, `fetch`, `@sync` and `timedwait` run as Base wrote them. Only
# the C runtime under them is replaced (`trim/wasm-tasks.jl` patches `Task(f)`, `enq_work`,
# `wait()`, `try_yieldto`, libuv's timers): one thread, one run queue (`RUNQ`), and a task
# switch is a host call, `julia_task.switch(from, to)`, a `WebAssembly.Suspending` import
# that parks the current Wasm stack on a promise and resumes (or starts) the target's. Each
# task runs on its own JSPI stack, entered through the export `jl_task_entry(id)` (wrapped
# in `WebAssembly.promising` by the host). The host never decides what runs: it only moves
# stacks.
#
# A task's body is a closure of a type known where the task is created (`Task(f)` is
# specialized on `f` by the patch): `add_runner!(F)` has the module compile
# `run_body(::Task, ::Type{F})`, which `call_body` calls on the new stack by the type of the
# task's `code`, as the C runtime's `start_task` calls it: no dynamic dispatch. A task gets its
# id (for the host) at its first run and gives it back at its end: Tasks that never run hold
# none, and are not kept alive by the runtime.
#
# Task-local state of the C runtime that is not a field of `Task`: the current exception
# (what `rethrow()` throws, a global of the module) is kept by `switch` in its frame across
# the suspension and restored when the task resumes; a new task starts with none. The task's
# thread (`jl_get_task_tid`), set when it is scheduled or runs, is in its padding byte `pad00`.
#
# Waits on the host (`julia_io` handles) register the waiting task in `WAITERS` (any number of
# tasks per handle); active `Timer`s are in `TIMERS`, closed ones whose close is not complete in
# `CLOSING`. The scheduler's `process_events` is libuv's loop as native `wait()` runs it: the
# host's event loop turns, then one `julia_io.poll` over all of them runs the timers' callbacks,
# then the close callbacks. A poll suspends the stack of the task that calls it while every
# other task is parked; its records are allocated in a scope that ends before any task switch
# (the staging arenas are LIFO and shared by all tasks).

module Tasks

import ..Staging
import ..JuliaIO
import ..Host
import ..Runtime
using ..Runtime: @wasm_method, original

const EINVAL = Int32(28)

## host imports (`julia_task`)

host_switch(from::Int32, to::Int32) = ccall((:switch, "julia_task"), Cvoid, (Int32, Int32), from, to)
host_exit(from::Int32, to::Int32) = ccall((:exit, "julia_task"), Cvoid, (Int32, Int32), from, to)
"The task of `host_switch` and `host_exit` when no task can run: the program waits forever."
const NO_TASK_ID = Int32(-1)

## primitives the code generator compiles (`overlays.jl`); natively, placeholders

const NO_TASK = Ref{Task}()
const NO_EXCEPTION = Ref{Any}(nothing)
"A new `Task` object, every field zero or null (`struct.new`)."
@noinline alloc_task() = NO_TASK[]
"Make `t` the task `current_task()` returns (`global.set`)."
@noinline set_current!(t::Task) = (NO_TASK[] = t; nothing)
"Have the module compile `run_body(::Task, F)`, for `call_body` of a task body of type `F`."
@noinline add_runner!(::Type{F}) where {F} = (NO_TASK[] = NO_TASK[]; nothing)
"Call the `run_body` of the type of `code` (the task's body, `t.code`) on `t`."
@noinline call_body(@nospecialize(code), t::Task) = (NO_TASK[] = t; nothing)
"The current exception (the global `rethrow()` reads; null outside handlers)."
@noinline get_exception() = NO_EXCEPTION[]
"Make `x` (from `get_exception`) the current exception again."
@noinline set_exception!(@nospecialize(x)) = (NO_EXCEPTION[] = x; nothing)
"No current exception (as on a new task's stack)."
@noinline clear_exception!() = (NO_EXCEPTION[] = nothing; nothing)

"""
    run_body(t, F)

Run the body of the task `t` (a closure of type `F`), as the C runtime's `start_task`:
its result, or the exception it throws, becomes the task's result.
"""
function run_body(t::Task, ::Type{F}) where {F}
    try
        t.result = (t.code::F)()
    catch e
        t.result = e
        t._isexception = true
    end
    return nothing
end

## task ids: the host knows tasks by id, from a task's first run to its end; the root task
## (the exported entry the host called) is 0

const MAX_ID = Int32(typemax(UInt16))
const TASKS = Union{Nothing,Task}[]   # TASKS[id]: the task of id ≥ 1, until it ends
const IDS = IdDict{Task,Int32}()       # the ids of the tasks that have one
const FREE = Int32[]
"The root task: the one of the root calls, the first that made a task."
const ROOT = Ref{Task}()

@noinline too_many_tasks() = throw(ErrorException(string("more than ", MAX_ID, " live tasks")))

is_root(t::Task) = isassigned(ROOT) ? t === ROOT[] : t === current_task()

"The id of `t` (the running task, or one that ran), 0 for the root."
task_id(t::Task) = is_root(t) ? Int32(0) : IDS[t]

"The id of `t`, given at its first run (the next to run, which may not have run yet)."
function task_id!(t::Task)
    is_root(t) && return Int32(0)
    id = get(IDS, t, Int32(0))
    id == 0 || return id
    if isempty(FREE)
        length(TASKS) < MAX_ID || too_many_tasks()
        push!(TASKS, t)
        id = Int32(length(TASKS))
    else
        id = pop!(FREE)
        TASKS[id] = t
    end
    IDS[t] = id
    return id
end

const task_state_runnable = UInt8(0)
const task_state_done = UInt8(1)
const task_state_failed = UInt8(2)

"`jl_is_task_started`: it ran (the root task, one with an id, one that ended)."
is_started(t::Task) = is_root(t) || t._state !== task_state_runnable || haskey(IDS, t)

"`jl_get_task_tid`: the one thread's (0) once it was set (the task scheduled, or run), else -1."
task_tid(t::Task) = is_root(t) || t.pad00 != 0x00 ? Int16(0) : Int16(-1)

"`jl_set_task_tid`: the task's thread, once (the one thread's: 0); 0 if it is another's."
function set_task_tid(t::Task, tid::Cint)
    was = task_tid(t)
    was == tid && return Cint(1)
    (was == -1 && tid == 0) || return Cint(0)
    t.pad00 = 0x01
    return Cint(1)
end

# `jl_rng_split` (src/task.c): the child's xoshiro256 state from the parent's, advancing the
# parent's LCG word (`rngState4`): siblings get different streams, as natively
function rng_split_word(c::UInt64, x::UInt64, a::UInt64, m::UInt64)
    w = x ⊻ a
    c += w * (2c + 0x1)
    c ⊻= c >> ((c >> 59) + 0x5)
    c *= m
    c ⊻= c >> 43
    return c
end

function rng_split!(t::Task, ct::Task)
    x = ct.rngState4
    x4 = x * 0xd1342543de82ef95 + 0x1
    ct.rngState4 = x4
    t.rngState4 = x4
    t.rngState0 = rng_split_word(ct.rngState0, x, 0x214c146c88e47cb7, 0xaef17502108ef2d9)
    t.rngState1 = rng_split_word(ct.rngState1, x, 0xa66d8cc21285aafa, 0xf34026eeb86766af)
    t.rngState2 = rng_split_word(ct.rngState2, x, 0x68c7ef2d7b1a54d4, 0x38fd70ad58dd9fbb)
    t.rngState3 = rng_split_word(ct.rngState3, x, 0xb053a7d7aa238c61, 0x6677f9b93ab0c04d)
    return nothing
end

"""
    new_task(f) -> Task

`jl_new_task`: a runnable task that will run `f()`, in the current task's dynamic scope,
with a random state split from the current task's.
"""
function new_task(f::F) where {F}
    ct = current_task()
    # (the first task is made by the root task: no other runs before)
    isassigned(ROOT) || (ROOT[] = ct)
    t = alloc_task()
    t.next = nothing
    t.queue = nothing
    t.storage = nothing
    t.donenotify = Base.ThreadSynchronizer()
    t.result = nothing
    setfield!(t, :scope, getfield(ct, :scope))
    t.code = f
    @atomic t._state = task_state_runnable
    t.sticky = true
    t._isexception = false
    rng_split!(t, ct)
    add_runner!(F)
    return t
end

## the run queue and the switch

const RUNQ = Base.IntrusiveLinkedList{Task}()
const NEXT = Ref{Task}()

"""
`enq_work` on one thread, as Base's: a sticky task not stuck to the thread yet is, and so is
the current task (so that they are scheduled together, #41324); the task joins the run queue.
"""
function enqueue!(t::Task)
    (t._state === task_state_runnable && t.queue === nothing) || error("schedule: Task not runnable")
    if t.sticky
        if task_tid(t) == -1
            current_task().sticky = true
            set_task_tid(t, Cint(0))
        end
    else
        set_task_tid(t, Cint(0))
    end
    push!(RUNQ, t)
    return t
end

function next_runnable()
    while !isempty(RUNQ)
        t = popfirst!(RUNQ)
        t._state === task_state_runnable && return t
    end
    return nothing
end

"""
    switch()

`jl_switch`: run `NEXT[]`; return when the current task is switched to again, with its
current exception as it was. A switch to the current task does nothing.
"""
function switch()
    t = NEXT[]
    ct = current_task()
    t === ct && return nothing
    # (as `jl_switch`: a task that ended does not run again)
    is_started(t) && t._state !== task_state_runnable && error("attempt to switch to exited task")
    exc = get_exception()
    SWITCHES[] += 1
    # (the thread is the task's while it runs, as `jl_switch` sets it)
    set_task_tid(t, Cint(0))
    PREVIOUS[] = ct
    host_switch(task_id(ct), task_id!(t))
    # resumed (a stack only runs as the current task)
    set_current!(ct)
    set_exception!(exc)
    unpin_previous!()
    return nothing
end
const SWITCHES = Ref(0)

"The task that ran before the current one: the one a switch or an end was from."
const PREVIOUS = Ref{Task}()

"""
    unpin_previous!()

After a switch, as `jl_switch` and `start_task` (`MIGRATE_TASKS`): the task switched from is
no longer the thread's unless it is sticky (its thread id is -1 again while it waits).
"""
function unpin_previous!()
    isassigned(PREVIOUS) || return nothing
    p = PREVIOUS[]
    p.sticky || is_root(p) || (p.pad00 = 0x00)
    return nothing
end

"""
    wait_forever()

No task can run and nothing can wake one (a deadlock): the current task waits forever, as the
program natively does. The host leaves the root call unfinished (`js/julia_task.mjs`).
"""
function wait_forever()
    host_switch(task_id(current_task()), NO_TASK_ID)
    error("julia_task: a task resumed after a deadlock")
end

"""
    task_entry(id) -> Int32

The export `jl_task_entry`: the first run of task `id`, on a new stack. Runs its body,
finishes it (`jl_finish_task`, Base's `task_done_hook`) and passes the thread to the next
task without parking (the stack ends).
"""
function task_entry(id::Int32)::Int32
    t = TASKS[id]::Task
    set_current!(t)
    clear_exception!()
    unpin_previous!()
    if t._isexception
        # thrown into before it ran (`throwto`, `schedule(t, e; error=true)`)
        t.result = t.result
    else
        call_body(t.code, t)
    end
    finish!(t)
    TASKS[id] = nothing
    delete!(IDS, t)
    nxt = idle_next()
    # (the next task's id first: it must differ from this one, which is free once its stack
    # can no longer run: no task runs before `host_exit`)
    nxt === nothing || set_task_tid(nxt, Cint(0))
    PREVIOUS[] = t
    to = nxt === nothing ? NO_TASK_ID : task_id!(nxt)
    push!(FREE, id)
    nxt === nothing || set_current!(nxt)
    host_exit(id, to)
    return Int32(0)
end

function finish!(t::Task)
    @atomic t._state = t._isexception ? task_state_failed : task_state_done
    donenotify = t.donenotify
    if donenotify isa Base.ThreadSynchronizer
        lock(donenotify)
        try
            isempty(donenotify.waitq) || notify(donenotify)
        finally
            unlock(donenotify)
        end
    end
    return nothing
end

"""
The next runnable task, waiting for the host's events while there is none
(`jl_task_get_next`); `nothing` if nothing can make one runnable (a deadlock).
"""
function idle_next()
    t = next_runnable()
    while t === nothing
        has_handles() || return nothing
        process_events(Int64(-1))
        t = next_runnable()
    end
    return t
end

## waits on host handles

const WAITERS = Dict{Int32,Vector{Task}}()
const TIMERS = Dict{Int32,Timer}()
const CLOSING = Timer[]
const READY = Int32[]
const INTEREST = Int32[]

has_handles() = !isempty(WAITERS) || !isempty(TIMERS) || !isempty(CLOSING)

function add_waiter!(h::Int32, t::Task)
    push!(get!(Vector{Task}, WAITERS, h), t)
    return nothing
end

# (only `t`'s registration: another task's wait for `h` stays)
function remove_waiter!(h::Int32, t::Task)
    ws = get(WAITERS, h, nothing)
    ws === nothing && return nothing
    i = findfirst(w -> w === t, ws)
    i === nothing || deleteat!(ws, i)
    isempty(ws) && delete!(WAITERS, h)
    return nothing
end

wake!(t::Task) = (t._state === task_state_runnable && t.queue === nothing && schedule(t); nothing)

"""
    process_events(timeout_ns) -> n

`jl_process_events` (`timeout_ns = 0`), an iteration of libuv's loop, and the idle sleep of
`jl_task_get_next` (`timeout_ns = -1`), for the program's handles (host waits, timers, timers
closing). The host's event loop turns first (a switch of the task to itself; an idle sleep
waits in `poll` instead), then one `julia_io.poll` over the handles: the timers due run their
callbacks (`uv_timercb`) in the order they are due, and a ready handle schedules every task
waiting for it (each checks its handle again: readiness is level-triggered and retired by the
operation it waits for); then the closed timers' close callbacks run (`_uv_hook_close`). When
none of the handles can become ready any more (`EINVAL` from an indefinite poll), the waiting
tasks get that error, as a single task's wait does.
"""
function process_events(timeout_ns::Int64)
    has_handles() || return 0
    if timeout_ns == 0
        ct = current_task()
        host_switch(task_id(ct), task_id(ct))
    end
    empty!(INTEREST)
    append!(INTEREST, keys(WAITERS))
    for h in keys(TIMERS)
        haskey(WAITERS, h) || push!(INTEREST, h)
    end
    sort!(INTEREST)
    n = length(INTEREST)
    empty!(READY)
    r = 0
    if n > 0
        POLLS[] += 1
        # (closes to complete: no waiting)
        wait_ns = isempty(CLOSING) ? timeout_ns : Int64(0)
        if n <= POLL_MAX
            got = poll!(1, n, wait_ns)
            if got == -EINVAL && wait_ns == -1
                fail_waiters!(Host.HostCallError(EINVAL, Host.errmsg(Int32(-1))))
                got = Int32(0)
            end
            got < 0 && Host.throw_host(-got, Int32(-1))
        else
            # (more handles than a poll takes: polls of each part of them, which do not wait;
            # for a wait, while none is ready, a wait of a millisecond on the first part)
            while true
                for i in 1:POLL_MAX:n
                    got = poll!(i, min(i + POLL_MAX - 1, n), Int64(0))
                    got < 0 && Host.throw_host(-got, Int32(-1))
                end
                (isempty(READY) && wait_ns != 0) || break
                got = poll!(1, POLL_MAX, Int64(1_000_000))
                got < 0 && Host.throw_host(-got, Int32(-1))
                isempty(READY) || break
            end
        end
        r = length(READY)
    end
    for h in READY
        tm = get(TIMERS, h, nothing)
        tm === nothing || timer_fire!(tm, h)
        ws = pop!(WAITERS, h, nothing)
        ws === nothing && continue
        foreach(wake!, ws)
    end
    while !isempty(CLOSING)
        timer_closed!(popfirst!(CLOSING))
    end
    return r
end
const POLLS = Ref(0)

"The handles one `julia_io.poll` takes at most."
const POLL_MAX = 1024

# one `julia_io.poll` of `INTEREST[i:j]`, waiting `wait_ns`: the handles ready appended to
# `READY` (all of them first: a timer's callback calls the host); their count, or the negated
# errno
function poll!(i::Int, j::Int, wait_ns::Int64)
    n = j - i + 1
    return Staging.with_scope() do
        interest = Staging.alloc_record(4n)
        out = Staging.alloc_record(4n)
        for k in 0:n-1
            Staging.store32(interest + UInt32(4k), INTEREST[i + k] % UInt32)
        end
        got = JuliaIO.poll(interest, Int32(n), wait_ns, out, Int32(n))
        for k in 0:Int(got)-1
            push!(READY, Staging.load32(out + UInt32(4k)) % Int32)
        end
        got
    end
end

function fail_waiters!(e::Host.HostCallError)
    for ws in values(WAITERS), t in ws
        t._state === task_state_runnable && t.queue === nothing && schedule(t, e; error=true)
    end
    empty!(WAITERS)
    return nothing
end

"""
    await_handle(h)

Wait, as a task, until the host handle `h` is ready; other tasks run meanwhile. Any number
of tasks may wait for one handle. Throws a `HostCallError` (`EINVAL`) when nothing the
program waits for (handles, timers) can become ready any more, as in a program of one task.
"""
function await_handle(h::Int32)
    ct = current_task()
    while true
        r = Staging.with_scope() do
            interest = Staging.alloc_record(4)
            out = Staging.alloc_record(4)
            Staging.store32(interest, h % UInt32)
            JuliaIO.poll(interest, Int32(1), Int64(0), out, Int32(1))
        end
        r < 0 && Host.throw_host(-r, Int32(-1))
        r == 1 && return nothing
        add_waiter!(h, ct)
        try
            wait_wasm()
        finally
            remove_waiter!(h, ct)
        end
    end
end

## Timers: libuv's timer handles as `julia_io` timers. An active timer's handle is in
## `TIMERS` (its `handle` field holds the host's handle). `process_events` runs the timer's
## callback (`uv_timercb`) when it is due; a repeating timer is started again for its interval
## first, from the time it is processed, as libuv restarts it from the loop's time. A closed
## timer (`jl_close_uv`) keeps its handle until its close callback (`_uv_hook_close`), at the
## end of the next `process_events`, as libuv closes handles

timer_handle(t::Timer) = Int32(UInt(t.handle))

start_timer(ns::Int64) = (h = JuliaIO.timer_start(ns); h < 0 && Host.throw_host(-h, Int32(-1)); h)

function ms_ns(ms::UInt64)
    ms > UInt64(typemax(Int64) ÷ 1_000_000) && return typemax(Int64)
    return Int64(ms) * 1_000_000
end

"`Timer(timeout; interval)`"
function timer_new(timeout::Real, interval::Real)
    timeout ≥ 0 || throw(ArgumentError("timer cannot have negative timeout of $timeout seconds"))
    interval ≥ 0 || throw(ArgumentError("timer cannot have negative repeat interval of $interval seconds"))
    # (as natively: whole ms, +1 ms but for zero, which the host does not need)
    return timer_ms(ceil(UInt64, timeout * 1000) + !iszero(timeout), ceil(UInt64, interval * 1000))
end

"A `Timer` of `timeoutms` and `intervalms` milliseconds, as `Timer(timeout; interval)` makes it."
function timer_ms(timeoutms::UInt64, intervalms::UInt64)
    h = start_timer(ms_ns(timeoutms))
    t = new_timer(Ptr{Cvoid}(UInt(h)), timeoutms, intervalms)
    TIMERS[h] = t
    return t
end
@eval new_timer(h::Ptr{Cvoid}, tms::UInt64, ims::UInt64) =
    $(Expr(:new, Timer, :h, :(Base.ThreadSynchronizer()), true, false, :tms, :ims))

# `jl_close_uv` of a timer: its host timer stopped, its close callback at the end of the next
# `process_events`
function close_handle!(t::Timer)
    h = timer_handle(t)
    if haskey(TIMERS, h)
        delete!(TIMERS, h)
        JuliaIO.close(h)
    end
    push!(CLOSING, t)
    return nothing
end

"`uv_timercb`: the timer `t` (of the host's timer `h`) is due."
function timer_fire!(t::Timer, h::Int32)
    delete!(TIMERS, h)
    JuliaIO.close(h)
    if t.interval_ms != 0
        h2 = start_timer(ms_ns(t.interval_ms))
        TIMERS[h2] = t
        @atomic :monotonic t.handle = Ptr{Cvoid}(UInt(h2))
    end
    lock(t.cond)
    try
        @atomic :monotonic t.set = true
        if t.interval_ms == 0
            # (stopped: closed now, as natively)
            if t.isopen
                @atomic :release t.isopen = false
                push!(CLOSING, t)
            end
        end
        notify(t.cond, true)
    finally
        unlock(t.cond)
    end
    return nothing
end

"`_uv_hook_close`: the close of `t` is complete."
function timer_closed!(t::Timer)
    lock(t.cond)
    try
        @atomic :release t.isopen = false
        @atomic :monotonic t.handle = C_NULL
        notify(t.cond, false)
    finally
        unlock(t.cond)
    end
    return nothing
end

"`close(::Timer)`, as Base's: it waits for the close to complete (a scheduling point)."
function timer_close!(t::Timer)
    t.handle == C_NULL && !t.isopen && return nothing
    if t.handle != C_NULL
        if t.isopen
            @atomic :release t.isopen = false
            close_handle!(t)
        end
        lock(t.cond)
        try
            while t.handle != C_NULL
                Base.wait(t.cond)
            end
        finally
            unlock(t.cond)
        end
    elseif t.isopen
        @atomic :release t.isopen = false
    end
    return nothing
end

"`Base._trywait(::Timer)`, as Base's: `true` once it fired (reset), `false` once it is closed."
function timer_trywait(t::Timer)
    set = t.set
    if !set
        if !isopen(t)
            set = t.set
            if !set
                Base.close(t) # wait for the close to complete
                return false
            end
        end
        set = t.set
        if !set
            lock(t.cond)
            try
                set = t.set
                if !set && t.handle != C_NULL # wait for set or handle, but not the isopen flag
                    set = Base.wait(t.cond)::Bool
                end
            finally
                unlock(t.cond)
            end
        end
    end
    @atomic :monotonic t.set = false
    return set
end

"`Timer(cb, timeout; interval)`: `cb(timer)` on a task each time it fires."
function timer_callback(cb::F, timeout::Real, spawn::Union{Nothing,Bool}, interval::Real) where {F}
    sticky = spawn === nothing ? current_task().sticky : !spawn
    timer = Timer(timeout; interval=interval)
    t = Task() do
        while Base._trywait(timer)
            try
                cb(timer)
            catch err
                # (natively `showerror` with the backtrace, which the module has not)
                print(Core.stderr, "Error in Timer:\n", Host.error_text(err))
                return
            end
            isopen(timer) || return
        end
    end
    t.sticky = sticky
    lock(timer.cond)
    try
        timer.set ? schedule(t) : Base._wait2(timer.cond, t)
    finally
        unlock(timer.cond)
    end
    return timer
end

"`sleep` on tasks: on a `Timer` of the milliseconds `Host.sleep_ms` waits for, as Base's."
sleep_timer(ms::UInt64) = (Base.wait(timer_ms(ms, UInt64(0))); nothing)

## Base's task utilities that need the C runtime or untyped code

"""
`errormonitor(t)`: the failure of `t`, if it fails, on stderr, as natively without color, but
for the backtrace, which the module has not (and for nested exceptions: its last only).
"""
function errormonitor_wasm(t::Task)
    t2 = Task() do
        if istaskfailed(t)
            print(Core.stderr, "UNHANDLED TASK ERROR: ", Host.error_text(t.result), "\n")
        end
        nothing
    end
    t2.sticky = false
    Base._wait2(t, t2)
    return t
end

"""
`wait(r)` of an object `@sync` collected, by its type (`wait(r)` of a value of no known type is
a dynamic call): `Base.wait` of each type of the module Base has a `wait` for (`by_type`), and
for another, a `MethodError`, as natively.
"""
function wait_synced(@nospecialize(r))
    if r isa Base.UnwrapTaskFailedException
        # (Base's `unwrap_task_failed`, but for the failed task's exception: its result, which
        # `getproperty(::Task, :exception)` is, a call not trim-safe on Julia 1.12)
        try
            Base.wait(r.task)
        catch ex
            ex isa TaskFailedException || rethrow()
            throw((ex::TaskFailedException).task.result)
        end
    else
        Runtime.by_type(wait_as, r, nothing) || Core.throw_methoderror(Base.wait, r)
    end
    return nothing
end

"`Base.wait(r)` of a value `r` of type `T` (a case of `by_type`)."
@noinline wait_as(@nospecialize(r), @nospecialize(_), ::Type{T}) where {T} = (Base.wait(r::T); true)

"""
`Base.sync_end` (`@sync`), as Base's: the tasks `@async`/`@spawn` put in its channel, and the
other objects (`wait_synced`); failures collected in a `CompositeException`, objects scheduled
after the end first.
"""
function sync_end_wasm(c::Channel{Any})
    local c_ex
    while isready(c)
        r = take!(c)
        if isa(r, Task)
            Base._wait(r)
            if istaskfailed(r)
                if !@isdefined(c_ex)
                    c_ex = CompositeException()
                end
                push!(c_ex, TaskFailedException(r))
            end
        else
            try
                wait_synced(r)
            catch e
                if !@isdefined(c_ex)
                    c_ex = CompositeException()
                end
                push!(c_ex, e)
            end
        end
    end
    Base.close(c)
    if isready(c)
        # (drained with `take!`: iterating a `Channel{Any}` makes tuples of abstract type)
        racy = []
        while isready(c)
            push!(racy, take!(c))
        end
        if !@isdefined(c_ex)
            c_ex = CompositeException()
        end
        pushfirst!(c_ex, Base.ScheduledAfterSyncException(racy))
    end
    if @isdefined(c_ex)
        throw(c_ex)
    end
    return nothing
end

## Base's scheduler primitives: runtime functions that are natively, in the compiler's process,
## Base's own (the patches are in the latest world, where libuv's callbacks also run), and in
## the module methods of `WASM_METHODS` (the above)

@static if VERSION >= v"1.13-"
    """
    `Base.wait()` on one thread, as Julia 1.13's: the host's events (but for a task that is
    done), then the run queue, then an idle wait on the host.
    """
    function wait_wasm()
        istaskdone(current_task()) || process_events(Int64(0))
        t = idle_next()
        t === nothing && wait_forever()
        NEXT[] = t
        return try_yieldto_wasm(Base.ensure_rescheduled)
    end
else
    """
    `Base.wait()` on one thread, as Julia 1.12's: the run queue, or an idle wait on the host;
    once resumed, the host's events.
    """
    function wait_wasm()
        t = idle_next()
        t === nothing && wait_forever()
        NEXT[] = t
        result = try_yieldto_wasm(Base.ensure_rescheduled)
        process_events(Int64(0))
        return result
    end
end

"`Base.ensure_rescheduled`, as Base's on the run queue."
function ensure_rescheduled_wasm(othertask::Task)
    ct = current_task()
    if ct !== othertask && othertask._state === task_state_runnable && othertask.queue === nothing
        pushfirst!(RUNQ, othertask)
    end
    Base.list_deletefirst!(RUNQ, ct)
    return nothing
end

"`Base.try_yieldto`: `jl_switch`, then the value or exception passed to the resumed task."
function try_yieldto_wasm(undo::F) where {F}
    try
        switch()
    catch
        undo(NEXT[])
        rethrow()
    end
    ct = current_task()
    if ct._isexception
        exc = ct.result
        ct.result = nothing
        ct._isexception = false
        throw(exc)
    end
    result = ct.result
    ct.result = nothing
    return result
end

"`jl_set_next_task`"
set_next_task_wasm(t::Task) = (NEXT[] = t; nothing)

@noinline enq_work(t::Task) = original(Base.enq_work, t)::Task
@noinline wait() = original(Base.wait)
@noinline ensure_rescheduled(t::Task) = (original(Base.ensure_rescheduled, t); nothing)
@noinline try_yieldto(undo::F) where {F} = original(Base.try_yieldto, undo)
@noinline task(f::F) where {F} = original(Core.Task, f)::Task
@noinline await(h::Int32) = (original(Host.await_handle, h); nothing)
@noinline sleep_ms(ms::UInt64) = (original(Host.sleep_ms, ms); nothing)
@noinline istaskstarted(t::Task) = original(Base.istaskstarted, t)::Bool
@noinline timer(timeout::Real, interval::Real) = original(Timer, timeout; interval=interval)::Timer
@noinline timer_cb(cb::F, timeout::Real, spawn::Union{Nothing,Bool}, interval::Real) where {F} =
    original(Timer, cb, timeout; spawn=spawn, interval=interval)::Timer
@noinline trywait(t::Timer) = original(Base._trywait, t)::Bool
@noinline close(t::Timer) = (original(Base.close, t); nothing)
@noinline errormonitor(t::Task) = original(Base.errormonitor, t)::Task
@noinline sync_end(c::Channel{Any}) = (original(Base.sync_end, c); nothing)

@wasm_method enq_work(t::Task) = enqueue!(t)
@wasm_method wait() = wait_wasm()
@wasm_method ensure_rescheduled(t::Task) = ensure_rescheduled_wasm(t)
@wasm_method try_yieldto(undo::F) where {F} = try_yieldto_wasm(undo)
@wasm_method task(f::F) where {F} = new_task(f)
@wasm_method await(h::Int32) = await_handle(h)
@wasm_method sleep_ms(ms::UInt64) = sleep_timer(ms)
@wasm_method istaskstarted(t::Task) = is_started(t)
@wasm_method timer(timeout::Real, interval::Real) = timer_new(timeout, interval)
@wasm_method timer_cb(cb::F, timeout::Real, spawn::Union{Nothing,Bool}, interval::Real) where {F} =
    timer_callback(cb, timeout, spawn, interval)
@wasm_method trywait(t::Timer) = timer_trywait(t)
@wasm_method close(t::Timer) = timer_close!(t)
@wasm_method errormonitor(t::Task) = errormonitor_wasm(t)
@wasm_method sync_end(c::Channel{Any}) = sync_end_wasm(c)

"Counters for the overhead measurements: (switches, polls, live task ids)."
stats() = (SWITCHES[], POLLS[], length(TASKS) - length(FREE))

end # Tasks
