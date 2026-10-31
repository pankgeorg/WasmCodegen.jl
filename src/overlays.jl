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
    F = mi.specTypes.parameters[1]
    impl = Base.issingletontype(F) ? Runtime.wasm_impl(F.instance) : nothing
    if impl !== nothing
        # a runtime function with a native twin: its Wasm implementation
        args = CGVal[operand(fc, a) for a in ex.args[3:end]]
        argtypes = Tuple(mi.specTypes.parameters[2:end])
        args = CGVal[convert_repr(fc, a, T) for (a, T) in zip(args, argtypes)]
        return call_runtime!(fc, impl, args)
    end
    if m.module === Runtime.IO && m.name === :write_byte
        fd, b = CGVal[operand(fc, a) for a in ex.args[3:end]]
        push_val!(fc, convert_repr(fc, fd, Int32))
        push_val!(fc, convert_repr(fc, b, UInt8))
        call!(fc.b, host_func!(fc.cgm, :write_byte))
        return ghost(Nothing, nothing)
    elseif m.module === Runtime.IO && m.name === :flush_output
        return emit_flush_output!(fc)
    elseif m.module === Runtime && m.name === :map_type
        f = mi.specTypes.parameters[2]
        return emit_map_type!(fc, f.instance, operand(fc, ex.args[4]))
    elseif m.module === Runtime && m.name === :map_type_symbol
        f = mi.specTypes.parameters[2]
        return convert_repr(fc, emit_map_type!(fc, f.instance, operand(fc, ex.args[4])), Symbol)
    elseif m.module === Runtime && m.name === :map_type_value
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
    elseif m.module === Runtime && m.name === :unset_element!
        # the element's box (an element per array element) or each of its reference leaves,
        # null: undefined (`emit_memoryref_isassigned!`)
        r = operand(fc, ex.args[3])
        E = ref_eltype(r.typ)
        ml = memory_layout(fc.cgm.types, E)
        ml.storage isa RefType && (ml.boxed || all(l -> l.type isa RefType, ml.elem.leaves)) ||
            unsupported("unsetting an element of ", E)
        for k in 0:(ml.boxed ? 0 : ml.stride - 1)
            push_element_address!(fc, r, ml, k)
            emit!(fc.b, :ref_null, (ml.storage::RefType).heap)
            emit!(fc.b, :array_set, ml.array)
        end
        return ghost(Nothing, nothing)
    elseif m.module === Runtime && m.name === :reinterpret_bits
        Out = mi.specTypes.parameters[2].parameters[1]
        In = mi.specTypes.parameters[3]
        return emit_reinterpret_bits!(fc, Out, operand(fc, ex.args[4]), In)
    end
    return nothing
end
