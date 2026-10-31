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
# specialized on `f` by the patch): `entry_slot!(F)` stores a reference to the compiled
# `run_body(::Task, ::Type{F})` in a table of the module, at a slot of its own for `F`, which
# `call_entry` calls on the new stack: no dynamic dispatch. A task gets its id (for the host)
# at its first run and gives it back at its end: Tasks that never run hold none, and are not
# kept alive by the runtime.
#
# Task-local state of the C runtime that is not a field of `Task`: the current exception
# (what `rethrow()` throws, a global of the module) is kept by `switch` in its frame across
# the suspension and restored when the task resumes; a new task starts with none.
#
# Waits on the host (`julia_io` handles: sleeps, HTTP) register the waiting task in `WAITERS`
# (any number of tasks per handle); active `Timer`s are in `TIMERS`. The scheduler's
# `process_events` is one `julia_io.poll` over all of them, as native `wait()` runs libuv's
# events. A poll suspends the stack of the task that calls it while every other task is
# parked; its records are allocated in a scope that ends before any task switch (the staging
# arenas are LIFO and shared by all tasks).

module Tasks

import ..Staging
import ..JuliaIO
import ..Host
import ..WASM_IMPLS
import ..Twins: original

## host imports (`julia_task`)

host_switch(from::Int32, to::Int32) = ccall((:switch, "julia_task"), Cvoid, (Int32, Int32), from, to)
host_exit(from::Int32, to::Int32) = ccall((:exit, "julia_task"), Cvoid, (Int32, Int32), from, to)

## primitives the code generator compiles (`overlays.jl`); natively, placeholders

const NO_TASK = Ref{Task}()
const NO_EXCEPTION = Ref{Any}(nothing)
const NO_SLOT = Ref(Int32(1))
"A new `Task` object, every field zero or null (`struct.new`)."
@noinline alloc_task() = NO_TASK[]
"Make `t` the task `current_task()` returns (`global.set`)."
@noinline set_current!(t::Task) = (NO_TASK[] = t; nothing)
"The slot (≥ 1) of the body runner of tasks of closures of type `F`, stored there."
@noinline entry_slot!(::Type{F}) where {F} = (NO_SLOT[] = NO_SLOT[]; NO_SLOT[])
"Call the body runner in the slot `slot` on `t` (`call_ref`)."
@noinline call_entry(slot::Int32, t::Task) = (NO_TASK[] = t; nothing)
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
## (the exported entry the host called) is 0. `t.priority` (unused by the one-thread queue)
## holds a task's runner slot until it has an id, then its id

const MAX_ID = Int32(typemax(UInt16))
const TASKS = Union{Nothing,Task}[]   # TASKS[id]: the task of id ≥ 1, until it ends
const SLOTS = Int32[]                  # SLOTS[id]: its runner slot
const STARTED = Bool[]                 # STARTED[id]: its `jl_task_entry` ran
const FREE = Int32[]
const ROOT = Ref{Task}()

@noinline too_many_tasks() = throw(ErrorException(string("more than ", MAX_ID, " live tasks")))

has_id(t::Task) = (k = Int(t.priority); 1 <= k <= length(TASKS) && TASKS[k] === t)

"The id of `t` (the running task, or one that ran), 0 for the root."
task_id(t::Task) = Int32(t.priority)

"The id of `t`, given at its first run (the next to run, which may not have run yet)."
function task_id!(t::Task)
    (t.priority == 0 || has_id(t)) && return Int32(t.priority)
    slot = Int32(t.priority)
    if isempty(FREE)
        length(TASKS) < MAX_ID || too_many_tasks()
        push!(TASKS, t)
        push!(SLOTS, slot)
        push!(STARTED, false)
        id = Int32(length(TASKS))
    else
        id = pop!(FREE)
        TASKS[id] = t
        SLOTS[id] = slot
        STARTED[id] = false
    end
    t.priority = id % UInt16
    return id
end

const task_state_runnable = UInt8(0)
const task_state_done = UInt8(1)
const task_state_failed = UInt8(2)

"`jl_is_task_started`"
function is_started(t::Task)
    return t.priority == 0 || t._state !== task_state_runnable || (has_id(t) && STARTED[Int(t.priority)])
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
    task_id(ct) == 0 && !isassigned(ROOT) && (ROOT[] = ct)
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
    t.priority = entry_slot!(F) % UInt16
    return t
end

## the run queue and the switch

const RUNQ = Base.IntrusiveLinkedList{Task}()
const NEXT = Ref{Task}()

"`enq_work` on one thread: the task joins the run queue."
function enqueue!(t::Task)
    (t._state === task_state_runnable && t.queue === nothing) || error("schedule: Task not runnable")
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
current exception as it was. When the next task is the current one, it still goes through the
host (`switch(id, id)`), whose event loop runs when it has work outstanding (natively,
`jl_process_events` runs libuv's events in place).
"""
function switch()
    t = NEXT[]
    ct = current_task()
    exc = get_exception()
    SWITCHES[] += 1
    host_switch(task_id(ct), task_id!(t))
    # resumed (a stack only runs as the current task)
    set_current!(ct)
    set_exception!(exc)
    return nothing
end
const SWITCHES = Ref(0)

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
    STARTED[id] = true
    if t._isexception
        # thrown into before it ran (`throwto`, `schedule(t, e; error=true)`)
        t.result = t.result
    else
        call_entry(SLOTS[id], t)
    end
    finish!(t)
    TASKS[id] = nothing
    t.code = nothing
    nxt = next_after_exit()
    # (the next task's id first: it must differ from this one, which is free once its stack
    # can no longer run: no task runs before `host_exit`)
    to = task_id!(nxt)
    push!(FREE, id)
    set_current!(nxt)
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

@noinline deadlock_error() = ConcurrencyViolationError(
    "deadlock detected: no task can run and none waits for the host")

"The next runnable task, waiting for host events while there is none (`jl_task_get_next`)."
function idle_next()
    t = next_runnable()
    while t === nothing
        idle_wait() || throw(deadlock_error())
        t = next_runnable()
    end
    return t
end

# after a task's end: as `idle_next`, but a deadlock is thrown into the root task (the one
# the host called, waiting), not into the task that ended
function next_after_exit()
    t = next_runnable()
    while t === nothing
        if !idle_wait()
            schedule(ROOT[], deadlock_error(); error=true)
        end
        t = next_runnable()
    end
    return t
end

## waits on host handles

const WAITERS = Dict{Int32,Vector{Task}}()
const TIMERS = Dict{Int32,Timer}()
const READY = Int32[]

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

`jl_process_events` (`timeout_ns = 0`) and the idle sleep of `jl_task_get_next`
(`timeout_ns = -1`): one `julia_io.poll` over the handles tasks wait for and the active
timers. A ready handle schedules every task waiting for it (each checks its handle again:
readiness is level-triggered and retired by the operation it waits for) and fires its
timer. When none of them can become ready any more (`EINVAL` from an indefinite poll), the
waiting tasks get that error, as a single task's wait does. (A handle that can no longer
become ready while others still can is waited for, as natively a wait that nothing will end.)
"""
function process_events(timeout_ns::Int64)
    n = length(WAITERS) + length(TIMERS)
    n == 0 && return 0
    n > 1024 && error("more than 1024 host waits")
    POLLS[] += 1
    r = Staging.with_scope() do
        interest = Staging.alloc_record(4n)
        out = Staging.alloc_record(4n)
        i = 0
        for h in keys(WAITERS)
            Staging.store32(interest + UInt32(4i), h % UInt32)
            i += 1
        end
        for h in keys(TIMERS)
            haskey(WAITERS, h) && continue
            Staging.store32(interest + UInt32(4i), h % UInt32)
            i += 1
        end
        got = JuliaIO.poll(interest, Int32(i), timeout_ns, out, Int32(i))
        # (all ready handles first: a timer's callback calls the host)
        empty!(READY)
        for k in 0:Int(got)-1
            push!(READY, Staging.load32(out + UInt32(4k)) % Int32)
        end
        got
    end
    if r == -Host.EINVAL && timeout_ns == -1
        fail_waiters!(Host.HostCallError(Host.EINVAL, Host.errmsg(Int32(-1))))
        return 0
    end
    r < 0 && Host.throw_host(-r, Int32(-1))
    for h in READY
        tm = get(TIMERS, h, nothing)
        tm === nothing || timer_fire!(tm, h)
        ws = pop!(WAITERS, h, nothing)
        ws === nothing && continue
        foreach(wake!, ws)
    end
    return Int(r)
end
const POLLS = Ref(0)

function fail_waiters!(e::Host.HostCallError)
    for ws in values(WAITERS), t in ws
        t._state === task_state_runnable && t.queue === nothing && schedule(t, e; error=true)
    end
    empty!(WAITERS)
    return nothing
end

# wait for host events while no task can run: `false` if there is nothing to wait for
function idle_wait()
    isempty(WAITERS) && isempty(TIMERS) && return false
    process_events(Int64(-1))
    return true
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
## `TIMERS` (its `handle` field holds the host's handle); `process_events` runs the timer's
## callback (`uv_timercb`) when it fires: an interval timer is restarted for its interval

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
    timeoutms = ceil(UInt64, timeout * 1000) + !iszero(timeout)
    intervalms = ceil(UInt64, interval * 1000)
    h = start_timer(ms_ns(timeoutms))
    t = new_timer(Ptr{Cvoid}(UInt(h)), timeoutms, intervalms)
    TIMERS[h] = t
    return t
end
@eval new_timer(h::Ptr{Cvoid}, tms::UInt64, ims::UInt64) =
    $(Expr(:new, Timer, :h, :(Base.ThreadSynchronizer()), true, false, :tms, :ims))

"`uv_timercb`"
function timer_fire!(t::Timer, h::Int32)
    lock(t.cond)
    try
        @atomic :monotonic t.set = true
        delete!(TIMERS, h)
        JuliaIO.close(h)
        if t.interval_ms == 0
            @atomic :release t.isopen = false
            @atomic :monotonic t.handle = C_NULL
        else
            h2 = start_timer(ms_ns(t.interval_ms))
            TIMERS[h2] = t
            @atomic :monotonic t.handle = Ptr{Cvoid}(UInt(h2))
        end
        notify(t.cond, true)
    finally
        unlock(t.cond)
    end
    return nothing
end

"`close(::Timer)`: the host's timer released; its waiters see it closed."
function timer_close!(t::Timer)
    lock(t.cond)
    try
        @atomic :release t.isopen = false
        h = timer_handle(t)
        if h != 0
            delete!(TIMERS, h)
            JuliaIO.close(h)
            @atomic :monotonic t.handle = C_NULL
            notify(t.cond, false)
        end
    finally
        unlock(t.cond)
    end
    return nothing
end

"`Base._trywait(::Timer)`: `true` once it fired (reset), `false` once it is closed."
function timer_trywait(t::Timer)
    set = t.set
    if !set
        lock(t.cond)
        try
            set = t.set
            if !set && t.handle != C_NULL
                set = Base.wait(t.cond)::Bool
            end
        finally
            unlock(t.cond)
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
                # (natively `showerror` with the backtrace; here the error's text)
                print(Core.stderr, "Error in Timer:\n", Host.error_text(err), "\n")
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

## Base's task utilities that need the C runtime or untyped code

"`errormonitor(t)`: the failure of `t`, if it fails, on stderr (as natively without color, but
its message only: no backtrace)."
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
`Base.sync_end` (`@sync`) for the tasks `@async`/`@spawn` put in its channel: Base's, but
a waitable object other than a `Task` is an error (its `wait` would be a dynamic call).
Failures are collected in a `CompositeException` as natively, tasks scheduled after the
end first.
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
            if !@isdefined(c_ex)
                c_ex = CompositeException()
            end
            push!(c_ex, ArgumentError("@sync in Wasm: waiting for an object other than a Task is not supported"))
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

## Base's scheduler primitives: twins (natively, in the compiler's process, Base's own: the
## patches are in the latest world, where libuv's callbacks also run; in Wasm, the above)

"`Base.wait()` on one thread: host events, then the run queue, then an idle wait on the host."
function wait_wasm()
    process_events(Int64(0))
    NEXT[] = idle_next()
    return try_yieldto_wasm(Base.ensure_rescheduled)
end

function ensure_rescheduled_wasm(othertask::Task)
    ct = current_task()
    if ct !== othertask && othertask._state === task_state_runnable && othertask.queue === nothing
        pushfirst!(RUNQ, othertask)
    end
    q = ct.queue
    q === nothing || Base.list_deletefirst!(q::Base.IntrusiveLinkedList{Task}, ct)
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

set_next_task_wasm(t::Task) = (NEXT[] = t; nothing)

set_thrpool_wasm(t::Task, tp::Symbol) = nothing

@noinline enq_work(t::Task) = original(Base.enq_work, t)::Task
@noinline wait() = original(Base.wait)
@noinline ensure_rescheduled(t::Task) = (original(Base.ensure_rescheduled, t); nothing)
@noinline try_yieldto(undo::F) where {F} = original(Base.try_yieldto, undo)
@noinline set_next_task(t::Task) = (original(Base.set_next_task, t); nothing)
@noinline task(f::F) where {F} = original(Core.Task, f)::Task
@noinline await(h::Int32) = (original(Host.await_handle, h); nothing)
@noinline istaskstarted(t::Task) = original(Base.istaskstarted, t)::Bool
@noinline set_thrpool(t::Task, tp::Symbol) = (original(Threads._spawn_set_thrpool, t, tp); nothing)
@noinline timer(timeout::Real, interval::Real) = original(Timer, timeout; interval=interval)::Timer
@noinline timer_cb(cb::F, timeout::Real, spawn::Union{Nothing,Bool}, interval::Real) where {F} =
    original(Timer, cb, timeout; spawn=spawn, interval=interval)::Timer
@noinline trywait(t::Timer) = original(Base._trywait, t)::Bool
@noinline close(t::Timer) = (original(Base.close, t); nothing)
@noinline errormonitor(t::Task) = original(Base.errormonitor, t)::Task
@noinline sync_end(c::Channel{Any}) = (original(Base.sync_end, c); nothing)

WASM_IMPLS[enq_work] = enqueue!
WASM_IMPLS[wait] = wait_wasm
WASM_IMPLS[ensure_rescheduled] = ensure_rescheduled_wasm
WASM_IMPLS[try_yieldto] = try_yieldto_wasm
WASM_IMPLS[set_next_task] = set_next_task_wasm
WASM_IMPLS[task] = new_task
WASM_IMPLS[await] = await_handle
WASM_IMPLS[istaskstarted] = is_started
WASM_IMPLS[set_thrpool] = set_thrpool_wasm
WASM_IMPLS[timer] = timer_new
WASM_IMPLS[timer_cb] = timer_callback
WASM_IMPLS[trywait] = timer_trywait
WASM_IMPLS[close] = timer_close!
WASM_IMPLS[errormonitor] = errormonitor_wasm
WASM_IMPLS[sync_end] = sync_end_wasm

"Counters for the overhead measurements: (switches, polls, live task slots)."
stats() = (SWITCHES[], POLLS[], length(TASKS) - length(FREE))

end # Tasks
