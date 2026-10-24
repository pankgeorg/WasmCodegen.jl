# The runtime: functions written in Julia that the code generator calls for what Wasm
# lacks (an exact fused multiply-add, ...). They are compiled into the module on demand,
# like the functions of libjulia native code calls.
#
# There are no overlays of Base's methods: inference is Julia's own (but for target facts
# like `have_fma`), so the code compiled is the code juliac compiles. What Base does with
# pointers and calls into the C runtime is compiled from the IR instead (`foreigncall.jl`,
# `pointers.jl`).

"""
    runtime_function!(cgm, f, argtypes) -> FuncInfo

The function compiled for the call `f(::argtypes...)`, which the code generator uses as
part of its runtime; it (and what it calls) is added to the closed world.
"""
function runtime_function!(cgm::CGModule, @nospecialize(f), @nospecialize(argtypes::Tuple))
    w = cgm.world
    mi = entry_instance(f, argtypes; world=w.world)
    haskey(w.sources, mi) || extend_world!(w, Core.MethodInstance[mi])
    return get_function!(cgm, mi)
end

"Call the runtime function `f(args...)`."
function call_runtime!(fc::FnCtx, @nospecialize(f), args::Vector{CGVal})
    info = runtime_function!(fc.cgm, f, Tuple(a.typ for a in args))
    return emit_call_info!(fc, info, CGVal[ghost(typeof(f), f), args...])
end

"""
    emit_intrinsic_call!(fc, mi, ex, typ) -> Union{Nothing,CGVal}

The code of an `:invoke` of a primitive of the runtime, which the code generator compiles
itself (a host call), or `nothing` for other calls.
"""
function emit_intrinsic_call!(fc::FnCtx, mi::Core.MethodInstance, ex::Expr, @nospecialize(typ))
    m = mi.def
    m isa Method || return nothing
    if m.module === Runtime.IO && m.name === :write_byte
        fd, b = CGVal[operand(fc, a) for a in ex.args[3:end]]
        push_val!(fc, convert_repr(fc, fd, Int32))
        push_val!(fc, convert_repr(fc, b, UInt8))
        call!(fc.b, host_import!(fc.cgm, "write_byte", ValType[I32, I32], ValType[]))
        return ghost(Nothing, nothing)
    elseif fc.cgm.config.funcref_wrappers && m.module === funcwrappers_module() && m.name === :reinit_wrapper
        # only reached when a wrapper's pointer is null, which the image and `emit_cfunction!` never produce
        unreachable!(fc.b)
        return bottom()
    elseif m.module === Runtime && m.name === :map_type
        f = mi.specTypes.parameters[2]
        return emit_map_type!(fc, f.instance, operand(fc, ex.args[4]))
    elseif m.module === Base && (m.name === :enq_work || (m.name === :wait && length(mi.specTypes.parameters) == 1))
        # one task: waiting can only wait forever, and there is no other task to schedule (in
        # place of the scheduler: task switches, the C runtime's queues and threads)
        msg = m.name === :wait ? "deadlock: waiting in a program of one task" : "scheduling a task in a program of one task"
        return throw_error!(fc, Runtime.throw_concurrency_error, () -> const_value(fc, msg))
    elseif m.module === Runtime.EqTables && m.name === :unset!
        # a null reference in the element
        a, i = CGVal[operand(fc, x) for x in ex.args[3:end]]
        ml = memory_layout(fc.cgm.types, Any)
        push_memory_array!(fc, a)
        push_val!(fc, convert_repr(fc, i, Int)); emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :i32_const, 1); emit!(fc.b, :i32_sub)
        push_default!(fc, ml.storage)
        emit!(fc.b, :array_set, ml.array)
        return ghost(Nothing, nothing)
    elseif m.module === Runtime && m.name === :reinterpret_bits
        Out = mi.specTypes.parameters[2].parameters[1]
        In = mi.specTypes.parameters[3]
        return emit_reinterpret_bits!(fc, Out, operand(fc, ex.args[4]), In)
    end
    return nothing
end

"""
    host_import!(cgm, name, params, results) -> Func

The function `name` the host provides (import module `julia`), the runtime's interface to
the world outside: see the loader for what each one does.
"""
host_import!(cgm::CGModule, name::AbstractString, params::Vector{ValType}, results::Vector{ValType}) =
    add_import!(cgm.mod, "julia", name, params, results)
