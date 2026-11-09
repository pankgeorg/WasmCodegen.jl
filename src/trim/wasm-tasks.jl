# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`): the C runtime's scheduler
# primitives on one thread (`Runtime.Tasks`). Base's own `schedule`, `yield`, `yieldto`,
# `Condition`, `Channel`, `Event`, `fetch` and `timedwait` run unchanged on top. Applied
# after juliac's trim patches, in place of the code generator's stubs for a program of one task.
#
# `Threads.@threads` runs its loop as Base does, in `threadpoolsize()` (one) tasks of this scheduler;
# its `threading_run` is specialized on the loop's body (below), which Base calls through a
# value of type `Any`.
#
# Each patch calls a runtime function (`Runtime.Tasks`): natively Base's original method, in
# Wasm a method of `WASM_METHODS`, the runtime's. The patches are defined in the latest world,
# which is also where libuv's callbacks run in the compiler's process (a process exit schedules
# its waiter): those must keep Base's scheduler.

let T = WasmCodegen.Runtime.Tasks
    # `jl_new_task`, specialized on the closure (its body is called without dispatch)
    @eval Core Task(f::F) where {F} = $(T.task)(f)
    @eval Core Task(f::F, reserved_stack::Int) where {F} = $(T.task)(f)
    @eval Base enq_work(t::Task) = $(T.enq_work)(t)
    @eval Base ensure_rescheduled(othertask::Task) = $(T.ensure_rescheduled)(othertask)
    @eval Base try_yieldto(undo) = $(T.try_yieldto)(undo)
    @eval Base wait() = $(T.wait)()
    @eval Base istaskstarted(t::Task) = $(T.istaskstarted)(t)
    # libuv's timers: `julia_io` timers polled by the scheduler
    @eval Base Timer(timeout::Real; interval::Real=0.0) = $(T.timer)(timeout, interval)
    @eval Base Timer(cb::F, timeout::Real; spawn::Union{Nothing,Bool}=nothing, interval::Real=0.0) where {F<:Function} =
        $(T.timer_cb)(cb, timeout, spawn, interval)
    @eval Base _trywait(t::Timer) = $(T.trywait)(t)
    @eval Base close(t::Timer) = $(T.close)(t)
    # (untyped: a dynamic `display_error`; a dynamic `wait` of what `@sync` collected)
    @eval Base errormonitor(t::Task) = $(T.errormonitor)(t)
    @eval Base sync_end(c::Channel{Any}) = $(T.sync_end)(c)
    # the runtime's host waits as tasks' waits; `sleep` on a `Timer`, as Base's
    @eval WasmCodegen.Runtime.Host await_handle(h::Int32) = $(T.await)(h)
    @eval WasmCodegen.Runtime.Host sleep_ms(ms::UInt64) = $(T.sleep_ms)(ms)
end

# `Threads.@threads`: Base's `threading_run`, specialized on the loop's body (`threadsfor_fun`), so
# that its tasks call it without dispatch (Base's is `@nospecialize` on Julia 1.13, and calls the
# body through a field of type `Any`). On Julia 1.13 this method replaces Base's; on 1.12, whose
# `threading_run(fun, static)` takes any `static`, it is the more specific one `@threads` calls.
@eval Base.Threads @noinline function threading_run(fun::F, static::Bool) where {F}
    ccall(:jl_enter_threaded_region, Cvoid, ())
    n = threadpoolsize()
    tid_offset = threadpoolsize(:interactive)
    tasks = Vector{Task}(undef, n)
    try
        for i = 1:n
            t = Task(() -> fun(i)) # pass in tid
            t.sticky = static
            if static
                ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid_offset + i-1)
            else
                _result = ccall(:jl_set_task_threadpoolid, Cint, (Any, Int8), t, _sym_to_tpid(:default))
                @assert _result == 1 "_result != 1"
            end
            tasks[i] = t
            schedule(t)
        end
        for i = 1:n
            Base._wait(tasks[i])
        end
    finally
        ccall(:jl_exit_threaded_region, Cvoid, ())
    end
    failed_tasks = filter!(istaskfailed, tasks)
    if !isempty(failed_tasks)
        throw(CompositeException(map(TaskFailedException, failed_tasks)))
    end
end
