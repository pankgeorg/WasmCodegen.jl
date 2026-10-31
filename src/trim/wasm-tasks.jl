# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`): the C runtime's scheduler
# primitives on one thread (`Runtime.Tasks`). Base's own `schedule`, `yield`, `yieldto`,
# `Condition`, `Channel`, `Event`, `fetch` and `timedwait` run unchanged on top. Applied
# after juliac's trim patches, in place of the code generator's stubs for a program of one task.
#
# Each patch calls a twin (`Runtime.Tasks`): natively Base's original method, in Wasm the
# runtime's. The patches are defined in the latest world, which is also where libuv's
# callbacks run in the compiler's process (a process exit schedules its waiter): those must
# keep Base's scheduler.

let T = WasmCodegen.Runtime.Tasks
    # `jl_new_task`, specialized on the closure (its body is called without dispatch)
    @eval Core Task(f::F) where {F} = $(T.task)(f)
    @eval Core Task(f::F, reserved_stack::Int) where {F} = $(T.task)(f)
    @eval Base enq_work(t::Task) = $(T.enq_work)(t)
    @eval Base set_next_task(t::Task) = $(T.set_next_task)(t)
    @eval Base ensure_rescheduled(othertask::Task) = $(T.ensure_rescheduled)(othertask)
    @eval Base try_yieldto(undo) = $(T.try_yieldto)(undo)
    @eval Base wait() = $(T.wait)()
    @eval Base istaskstarted(t::Task) = $(T.istaskstarted)(t)
    # `Threads.@spawn`: a task on the one thread
    @eval Threads _spawn_set_thrpool(t::Task, tp::Symbol) = $(T.set_thrpool)(t, tp)
    # libuv's timers: `julia_io` timers polled by the scheduler
    @eval Base Timer(timeout::Real; interval::Real=0.0) = $(T.timer)(timeout, interval)
    @eval Base Timer(cb::F, timeout::Real; spawn::Union{Nothing,Bool}=nothing, interval::Real=0.0) where {F<:Function} =
        $(T.timer_cb)(cb, timeout, spawn, interval)
    @eval Base _trywait(t::Timer) = $(T.trywait)(t)
    @eval Base close(t::Timer) = $(T.close)(t)
    # (untyped: a dynamic `display_error`; a dynamic `wait` of what `@sync` collected)
    @eval Base errormonitor(t::Task) = $(T.errormonitor)(t)
    @eval Base sync_end(c::Channel{Any}) = $(T.sync_end)(c)
    # the runtime's host waits (`sleep`, HTTP heads and bodies) as tasks' waits
    @eval WasmCodegen.Runtime.Host await_handle(h::Int32) = $(T.await)(h)
end
