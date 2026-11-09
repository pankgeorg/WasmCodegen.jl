# Exceptions: Julia's `throw` and try/catch on Wasm's exception handling (a tag carrying
# the exception object, `throw`, `try_table`).
#
# What a program needs is decided for its closed world (`exception_mode`):
#
# - `:none`: nothing catches an exception, so a throw traps (`unreachable`), the exception
#   it would throw is never built, and the handlers of try/finally are dropped;
# - `:control`: something catches, but nothing reads the exception: throws unwind to the
#   handlers, with no exception object (null);
# - `:values`: some handler reads the exception (`catch e` that uses `e`): throws carry
#   the exception objects, and the code generator's own checks throw the exceptions Julia's
#   C runtime throws (`BoundsError`, `DivideError`, ...).
#
# The current exception (what `catch e` binds and `rethrow()` throws) is a global: a
# handler sets it, `pop_exception` restores the one at the handler's `try`.

const EXCEPTION_MODES = Dict(:none => 0, :control => 1, :values => 2)

"""
    exception_mode(world) -> Symbol

How the program `world` uses exceptions: `:none`, `:control` or `:values` (see above).
"""
function exception_mode(w::ClosedWorld)
    mode = :none
    for (_, (_, src)) in w.sources
        for stmt in src.code
            if stmt isa Core.EnterNode && stmt.catch_dest != 0
                mode = :control
            elseif stmt isa Expr && (stmt.head === :the_exception ||
                                     (stmt.head === :foreigncall &&
                                      foreigncall_name(stmt.args[1]) === :jl_current_exception))
                return :values
            end
        end
    end
    return mode
end

"The tag of Julia exceptions: one parameter, the exception object (null where none is made)."
exception_tag!(cgm::CGModule) =
    get!(() -> add_tag!(cgm.mod, ValType[jlvalue_ref(cgm.types)]), cgm.helpers, :exception_tag)

"The global holding the current exception."
current_exception_global!(cgm::CGModule) = get!(cgm.helpers, :current_exception) do
    jl = jlvalue_ref(cgm.types)
    add_global!(cgm.mod, "jl_current_exception", jl, true, Inst[Inst(:ref_null, jl.heap)])
end

"""
    emit_throw!(fc, x) -> CGVal

`throw(x)`: a trap where nothing catches, else a Wasm exception carrying `x` (the
exception object, where handlers read it).
"""
function emit_throw!(fc::FnCtx, x)
    mode = fc.cgm.exceptions
    if mode === :none
        unreachable!(fc.b)
        return bottom()
    end
    if mode === :values && x isa CGVal && x.kind !== Bottom
        v = convert_repr(fc, x, Any)
        v.kind === Bottom && return v
        push_val!(fc, v)
    else
        emit!(fc.b, :ref_null, fc.cgm.types.jlvalue)
    end
    throw!(fc.b, exception_tag!(fc.cgm))
    return bottom()
end

"""
    throw_error!(fc, f, args...) -> CGVal

An error found by the code generator's own checks (bounds, division by zero, ...): a trap
where nothing catches, else the exception the runtime function `f(args...)` throws (the
one Julia's C runtime throws), or an exception without object where none is read. An
argument may be a function computing it, called only when the exception is built.
"""
function throw_error!(fc::FnCtx, @nospecialize(f), args...)
    mode = fc.cgm.exceptions
    if mode === :values
        # (arguments given as functions are computed only here)
        call_runtime!(fc, f, CGVal[a isa CGVal ? a : a() for a in args])
        is_unreachable(fc.b) || unreachable!(fc.b)
        return bottom()
    end
    return emit_throw!(fc, nothing)
end

"""
`rethrow()` (`e === nothing`): the current exception, thrown again; `rethrow(e)`: `e`
instead. Outside a handler (no current exception) an error, as natively.
"""
function emit_rethrow!(fc::FnCtx, e=nothing)
    fc.cgm.exceptions === :none && (unreachable!(fc.b); return bottom())
    exc = current_exception_global!(fc.cgm)
    emit!(fc.b, :global_get, exc); emit!(fc.b, :ref_is_null)
    if!(fc.b)
    throw_error!(fc, e === nothing ? Runtime.throw_rethrow_error : Runtime.throw_rethrow_other_error)
    end!(fc.b)
    e === nothing || return emit_throw!(fc, e)
    emit!(fc.b, :global_get, exc)
    throw!(fc.b, exception_tag!(fc.cgm))
    return bottom()
end

"`Expr(:the_exception)`: the current exception."
function emit_the_exception!(fc::FnCtx)
    fc.cgm.exceptions === :none && (unreachable!(fc.b); return bottom())
    emit!(fc.b, :global_get, current_exception_global!(fc.cgm))
    return pop_val!(fc, Any)
end

"`Expr(:pop_exception, %t)`: the current exception back to the one at the `try` `%t`."
function emit_pop_exception!(fc::FnCtx, t)
    saved = t isa Core.SSAValue ? get(fc.excsaved, t.id, nothing) : nothing
    saved === nothing && return nothing
    emit!(fc.b, :local_get, saved)
    emit!(fc.b, :global_set, current_exception_global!(fc.cgm))
    return nothing
end

"""
    bind_handler_args!(fc, block)

Give the arguments of the handlers of the `try`s in `block` their locals, and record the
upsilon statements that assign them (they may come before the `try`, so this is done for
the whole function first): an argument holds the value of the last of its upsilons that
ran when the handler runs.
"""
function bind_handler_args!(fc::FnCtx, block)
    for inst in IRStructurizer.instructions(block)
        st = inst[:stmt]
        st isa IRStructurizer.ControlFlowOp || continue
        if st isa IRStructurizer.TryOp && st.handler !== nothing
            for (k, a) in enumerate(st.handler.args)
                v = new_val!(fc, CC.widenconst(a.type))
                fc.blockargs[a.id] = v
                k <= length(st.upsilons) || continue
                for u in st.upsilons[k]
                    fc.upsilons[u] = v
                end
            end
        end
        foreach(b -> bind_handler_args!(fc, b), IRStructurizer.blocks(st))
    end
end

"""
An upsilon: its value assigned to the handler argument it feeds, if it is of the argument's
type. The argument's type is what the handler can see, and a value assigned after the try's
last statement that may throw is one it never sees, so it may be of another type (the value a
`return` passes through a `finally` feeds the catch's argument, of type `Union{}`). As natively
(`emit_upsilonnode`'s stores, which allow mismatches), such a value is not assigned: never
where it cannot be of the argument's type, else only where a test finds it is.
"""
function emit_upsilon!(fc::FnCtx, idx::Int, u::Core.UpsilonNode)
    dst = get(fc.upsilons, idx, nothing)
    (dst === nothing || dst.kind === Bottom || !isdefined(u, :val)) && return
    v = operand(fc, u.val)
    S, T = v.typ, dst.typ
    if !(S <: T)
        typeintersect(S, T) === Union{} && return
        if (v.kind === Boxed && layout(fc, S).wtype == fc.cgm.types.jlvalue) || is_union_tuple(S)
            t = emit_isa!(fc, v, T)
            if !isconstant(t)
                push_val!(fc, t)
                if!(fc.b)
                assign!(fc, dst, v)
                end!(fc.b)
                return
            end
            constant_value(t) || return
        end
    end
    assign!(fc, dst, v)
end

"""
    emit_cfop!(fc, op::TryOp, typ)

    block \$exit
      block \$handler (result exception)
        try_table (catch \$tag \$handler)
          body          ;; yield: results assigned, br \$exit
        end
        unreachable
      end
      current exception := the caught one
      handler           ;; yield: results assigned
    end

A body leaves through its yield, or a `LeaveOp` from a nested region (a branch to
`\$exit`). The current exception at the `try` is kept for `pop_exception`. A `try` without
handler (a scope) is a block; so is every `try` where nothing catches (its handler was
dropped).
"""
function emit_cfop!(fc::FnCtx, op::IRStructurizer.TryOp, @nospecialize(typ))
    rtypes = result_types(typ)
    results = CGVal[result_val!(fc, fc.opidx, i, rtypes[i]) for i in eachindex(rtypes)]
    catches = op.handler !== nothing && fc.cgm.exceptions !== :none
    cgm = fc.cgm
    if catches
        exc = current_exception_global!(cgm)
        saved = new_local!(fc, jlvalue_ref(cgm.types))
        emit!(fc.b, :global_get, exc)
        emit!(fc.b, :local_set, saved)
        fc.excsaved[fc.opidx] = saved
    end
    block!(fc.b); exit = open_label!(fc)
    if catches
        block!(fc.b, jlvalue_ref(cgm.types)); open_label!(fc)
        try_table!(fc.b, :empty, [(0, exception_tag!(cgm), 0)]); open_label!(fc)
    end
    push!(fc.tries, TryTarget(exit, results))
    push!(fc.yields, results); push!(fc.yields_if, false)
    emit_region!(fc, op.body)
    pop!(fc.yields); pop!(fc.yields_if)
    pop!(fc.tries)
    is_unreachable(fc.b) || br!(fc.b, br_depth(fc, exit))
    if catches
        end!(fc.b); close_label!(fc)
        unreachable!(fc.b)
        end!(fc.b); close_label!(fc)
        if cgm.exceptions === :control
            # (no exception objects: an object standing for the caught exception, so that a
            # handler is seen to be running)
            emit!(fc.b, :drop)
            push_val!(fc, convert_repr(fc, const_value(fc, nothing), Any))
        end
        emit!(fc.b, :global_set, exc)
        push!(fc.yields, results); push!(fc.yields_if, false)
        emit_region!(fc, op.handler)
        pop!(fc.yields); pop!(fc.yields_if)
    end
    end!(fc.b); close_label!(fc)
    return MultiVal(results)
end
