# C function pointers. A closed world knows every `cfunction` it can make, so the module has a
# table of them, as a C program compiled to Wasm has: a `cfunction` pointer's address is the
# function's slot in the table (from 1, `C_NULL` is no function) and it has no owner, and a
# `ccall` through a pointer reads the slot, casts it to the Wasm type of the call's signature
# (another signature traps, as `call_indirect` does) and calls it.
#
# The two sides of a call declare their types separately: a `cfunction` says `Ref{T}` where the
# `ccall` says `Ptr{Cvoid}` or `Any`, all of them C pointers. So every C pointer has one Wasm
# form in a signature, an address and an object: a `Ptr`'s address and owner, or for `Any`
# the object and no address. Other types are passed as themselves.

"Whether values of type `T` in a C signature are C pointers."
c_pointer_slot(@nospecialize(T)) = T === Any || (T isa Type && T <: Ref)

"The Julia type carried by a C function's result declared as `rt` (`Ref{T}`: an object)."
c_result_type(@nospecialize(rt)) = rt isa Type && rt <: Ref && !is_ptr_type(rt) ? Any : rt

"The Wasm parameters and results of the C signature `(argts) -> rt`."
function c_signature(cgm::CGModule, @nospecialize(rt), argts::Vector{Any})
    params = ValType[]
    for T in argts
        if is_ptr_type(T) || c_pointer_slot(T)
            push!(params, I64, jlvalue_ref(cgm.types))
        else
            append!(params, valtypes(cgm, T))
        end
    end
    R = c_result_type(rt)
    lr = layout(cgm, R)
    return params, lr.kind === Ghost || lr.kind === Bottom ? ValType[] : valtypes(cgm, R)
end

"The type a Julia function receives for an argument of type `T` of a C signature."
c_julia_type(@nospecialize(T)) = T isa Type && T <: Ref && !is_ptr_type(T) ? T.parameters[1] : T

"""
    c_argument(fc, T, a, o) -> CGVal

The argument of type `T` of a `cfunction`, from the locals of its C pointer, its address `a`
and object `o`. A `Ref{S}` is the object for an `S` stored by reference, else the object is
the `RefValue` holding the value.
"""
function c_argument(fc::FnCtx, @nospecialize(T), a::Int, o::Int)
    is_ptr_type(T) && return CGVal(T, Inline, LeafVal[a, o])
    x = CGVal(Any, Boxed, LeafVal[o])
    T === Any && return x
    S = c_julia_type(T)
    Base.issingletontype(S) && return const_value(fc, S.instance)
    Base.allocatedinline(S) && return call_runtime!(fc, Runtime.c_ref_value, CGVal[const_value(fc, S), x])
    return convert_repr(fc, x, S)
end

"""
    cfunction_thunk!(fc, f, rt, argts) -> Func

The Wasm function behind `@cfunction(f, rt, (argts...,))`: `f` on its arguments, of the
function type of the C signature.
"""
function cfunction_thunk!(fc::FnCtx, @nospecialize(f), @nospecialize(rt), argts::Vector{Any})
    cgm = fc.cgm
    key = (:cfunction, f, rt, Tuple(argts))
    t = get(cgm.helpers, key, nothing)
    t === nothing || return t
    info = runtime_function!(cgm, f, Tuple(Any[c_julia_type(T) for T in argts]))
    params, results = c_signature(cgm, rt, argts)
    t = add_func!(cgm.mod, helper_name(cgm, "cfunction_" * typename_str(typeof(f))), params, results)
    cgm.helpers[key] = t
    hfc = FnCtx(cgm, fc.info, nothing, Builder(cgm.mod, t))
    vals = CGVal[const_value(hfc, f)]
    k = 0
    for T in argts
        if is_ptr_type(T) || c_pointer_slot(T)
            push!(vals, c_argument(hfc, T, k, k + 1))
            k += 2
        else
            la = layout(cgm, T)
            n = la.kind === Ghost ? 0 : length(la.leaves)
            push!(vals, la.kind === Ghost ? ghost(T, something(ghost_value(T))) :
                        CGVal(T, la.kind, LeafVal[k + j for j in 0:n-1]))
            k += n
        end
    end
    r = emit_call_info!(hfc, info, vals)
    if !is_unreachable(hfc.b)
        R = c_result_type(rt)
        lr = layout(cgm, R)
        if lr.kind === Bottom || r.kind === Bottom
            unreachable!(hfc.b)
        elseif lr.kind !== Ghost
            push_val!(hfc, convert_repr(hfc, r, R))
        end
    end
    finish!(hfc.b)
    return t
end

"The table of the module's `cfunction`s: `(global, array type, functions)`."
function cfunction_table!(cgm::CGModule)
    get!(cgm.helpers, :cfunction_table) do
        arr = add_type!(cgm.mod, ArrayType(FieldType(RefType(:func, true), false)))
        g = add_global!(cgm.mod, "jl_cfunctions", RefType(arr, false), false, Inst[])
        (g, arr, Func[])
    end
end

"The table's initializer, once the module's `cfunction`s are known."
function finish_cfunctions!(cgm::CGModule)
    tbl = get(cgm.helpers, :cfunction_table, nothing)
    if tbl === nothing
        return
    end
    g, arr, funcs = tbl
    g.init = Inst[Inst[Inst(:ref_func, f) for f in funcs]..., Inst(:array_new_fixed, arr, length(funcs))]
    return
end

"`Expr(:cfunction, T, f, rt, argts, cc)` of a function known at compile time."
function emit_cfunction!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    f = ex.args[2]
    f isa QuoteNode && (f = f.value)
    if f isa Core.SSAValue || f isa Core.Argument || f isa GlobalRef
        c = operand(fc, f)
        (c isa CGVal && isconstant(c)) || unsupported("a cfunction of a function value not known at compile time")
        f = constant_value(c)
    end
    rt = ex.args[3]
    rt isa QuoteNode && (rt = rt.value)
    argts = collect(Any, ex.args[4]::Core.SimpleVector)
    all(T -> T isa Type, argts) && rt isa Type ||
        unsupported("a cfunction of types not known at compile time: ", argts, " -> ", rt)
    t = cfunction_thunk!(fc, f, rt, argts)
    _, _, funcs = cfunction_table!(fc.cgm)
    i = findfirst(==(t), funcs)
    if i === nothing
        push!(funcs, t)
        i = length(funcs)
    end
    o = new_local!(fc, jlvalue_ref(fc.cgm.types))
    emit!(fc.b, :i64_const, Int64(i))
    return new_ptr!(fc, typ === Ptr{Cvoid} ? typ : Ptr{Cvoid}, o, nothing)
end

"A `ccall` whose target is the pointer `target`: the function in its slot of the table."
function emit_indirect_ccall!(fc::FnCtx, target::CGVal, ex::Expr, args::Vector{Any}, @nospecialize(typ))
    rt = ex.args[2]
    argts = collect(Any, ex.args[3]::Core.SimpleVector)
    params, results = c_signature(fc.cgm, rt, argts)
    sig = WasmBuilder.functype!(fc.cgm.mod, params, results)
    g, arr, _ = cfunction_table!(fc.cgm)
    for (v, T) in zip(args, argts)
        v = v::CGVal
        if !(is_ptr_type(T) || c_pointer_slot(T))
            push_val!(fc, convert_repr(fc, v, T))
        elseif is_ptr_type(v.typ)
            push_val!(fc, v)
        else
            emit!(fc.b, :i64_const, Int64(0))
            push_val!(fc, convert_repr(fc, v, Any))
        end
    end
    emit!(fc.b, :global_get, g)
    push_val!(fc, ptr_address(target))
    emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_const, Int32(1))
    emit!(fc.b, :i32_sub)
    emit!(fc.b, :array_get, arr)
    emit!(fc.b, :ref_cast, sig)
    emit!(fc.b, :call_ref, sig)
    R = c_result_type(rt)
    lr = layout(fc, R)
    if lr.kind === Bottom
        unreachable!(fc.b)
        return bottom()
    end
    lr.kind === Ghost && return ghost(rt, rt.instance)
    v = pop_val!(fc, R)
    return R === rt ? v : convert_repr(fc, v, typ)
end
