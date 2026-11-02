# C function pointers. A closed world knows every `cfunction` it can make, so the module has a
# table of them, as a C program compiled to Wasm has: a `cfunction` pointer has no owner, its
# address is `CFUNCTION_BASE` plus the function's slot (from 1), and a `ccall` through a pointer
# finds the slot, checks the function's Wasm type against the call's signature and calls it. A
# signature no `cfunction` of the module has is reported when the module is compiled; a pointer
# that is not a function of its call's signature is an error of the program when it is called.
#
# The two sides of a call declare their types separately: a `cfunction` says `Ref{T}` where the
# `ccall` says `Ptr{Cvoid}` or `Any`, all of them C pointers. So every C pointer has one Wasm
# form in a signature, an address and an object: a `Ptr`'s address and owner, or for an object
# no address and the object. Other types are passed as themselves. The table is the module's
# own: its pointers mean nothing to a host or to another module.

"The address before the first slot: below every owner's range, outside the addresses `Ptr(1)`-like constants use."
const CFUNCTION_BASE = Int64(0x4a4c_0000)

is_ref_type(@nospecialize(T)) = T isa DataType && T.name === Ref.body.name

"Whether values of type `T` in a C signature are C pointers."
c_pointer_slot(@nospecialize(T)) = T === Any || is_ptr_type(T) || is_ref_type(T) || !Base.allocatedinline(T)

"The type a Julia function receives for an argument of type `T` of a C signature."
c_julia_type(@nospecialize(T)) = is_ref_type(T) ? T.parameters[1] : T

function check_c_type(@nospecialize(T))
    T === Any && return
    T isa Type || unsupported("a C signature with ", T, ", which is not a type known at compile time")
    isconcretetype(c_julia_type(T)) ||
        unsupported("a C signature with the type ", T, ", which is not concrete")
end

function check_c_signature(@nospecialize(rt), argts::Vector{Any})
    rt === Union{} && unsupported("a C signature that does not return")
    check_c_type(rt)
    foreach(check_c_type, argts)
end

"The Wasm values of a C value of type `T`."
function c_valtypes(cgm::CGModule, @nospecialize(T))
    c_pointer_slot(T) && return ValType[I64, jlvalue_ref(cgm.types)]
    return layout(cgm, T).kind === Ghost ? ValType[] : valtypes(cgm, T)
end

"The Wasm parameters and results of the C signature `(argts) -> rt`."
function c_signature(cgm::CGModule, @nospecialize(rt), argts::Vector{Any})
    params = ValType[]
    for T in argts
        append!(params, c_valtypes(cgm, T))
    end
    return params, c_valtypes(cgm, rt)
end

"Pushes the value `v` as a C value of the declared type `T`; a value declared `Any` is an object, whatever its type."
function push_c_value!(fc::FnCtx, v::CGVal, @nospecialize(T))
    if !c_pointer_slot(T)
        layout(fc, T).kind === Ghost || push_val!(fc, convert_repr(fc, v, T))
    elseif T !== Any && is_ptr_type(v.typ)
        push_val!(fc, v)
    else
        emit!(fc.b, :i64_const, Int64(0))
        push_val!(fc, convert_repr(fc, v, Any))
    end
    return
end

"""
    c_argument(fc, T, a, o) -> CGVal

The Julia value of a C pointer of declared type `T`, an argument of a `cfunction` or the result
of a `ccall`, from the locals of its address `a` and object `o`. A `Ref{S}` is the object for an
`S` stored by reference, else the value of type `S` at the pointer.
"""
function c_argument(fc::FnCtx, @nospecialize(T), a, o)
    x = CGVal(Any, Boxed, LeafVal[o])
    if is_ptr_type(T)
        # an object the caller passed as such: its address
        emit!(fc.b, :local_get, a); emit!(fc.b, :i64_eqz)
        emit!(fc.b, :local_get, o); emit!(fc.b, :ref_is_null); emit!(fc.b, :i32_eqz)
        emit!(fc.b, :i32_and)
        if!(fc.b)
        push_memory_base!(fc, x)
        emit!(fc.b, :local_set, a)
        end!(fc.b)
        return CGVal(T, Inline, LeafVal[a, o])
    end
    T === Any && return x
    S = c_julia_type(T)
    Base.issingletontype(S) && return const_value(fc, S.instance)
    Base.allocatedinline(S) || return convert_repr(fc, x, S)
    return call_runtime!(fc, Runtime.c_ref_value, CGVal[const_value(fc, S), CGVal(Ptr{Cvoid}, Inline, LeafVal[a, o]), x])
end

"""
    cfunction_thunk!(fc, f, rt, argts) -> Func

The Wasm function behind `@cfunction(f, rt, (argts...,))`: `f`, in the module's world, on its
arguments, of the function type of the C signature.
"""
function cfunction_thunk!(fc::FnCtx, @nospecialize(f), @nospecialize(rt), argts::Vector{Any})
    cgm = fc.cgm
    info = runtime_function!(cgm, f, Tuple(Any[c_julia_type(T) for T in argts]))
    want = c_julia_type(rt)
    want === Any || info.rettype <: want ||
        unsupported("a cfunction whose function returns ", info.rettype, ", not ", rt)
    params, results = c_signature(cgm, rt, argts)
    t = add_func!(cgm.mod, helper_name(cgm, "cfunction"), params, results)
    hfc = FnCtx(cgm, fc.info, nothing, Builder(cgm.mod, t))
    vals = CGVal[const_value(hfc, f)]
    k = 0
    for T in argts
        if c_pointer_slot(T)
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
        r.kind === Bottom ? unreachable!(hfc.b) : push_c_value!(hfc, r, rt)
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
    tbl === nothing && return
    g, arr, funcs = tbl
    g.init = Inst[Inst[Inst(:ref_func, f) for f in funcs]..., Inst(:array_new_fixed, arr, length(funcs))]
    return
end

"Report the calls through pointers whose signature no `cfunction` of the module has."
function check_cfunction_calls!(cgm::CGModule)
    calls = get(cgm.helpers, :cfunction_calls, nothing)
    calls === nothing && return
    _, _, funcs = cfunction_table!(cgm)
    for (sig, (mi, rt, argts)) in calls
        any(f -> f.type == sig, funcs) && continue
        err = Unsupported("a ccall through a pointer with the signature ", argts, " -> ", rt,
                          ", which no cfunction of the module has")
        push!(err.context, mi)
        push!(cgm.diagnostics, mi => err)
    end
end

"`Expr(:cfunction, Ptr{Cvoid}, f, rt, argts, cc)`: the pointer to `f` for a function known at compile time."
function emit_cfunction!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    typ === Ptr{Cvoid} || unsupported("a cfunction of a closure value (a ", typ, ")")
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
    check_c_signature(rt, argts)
    cgm = fc.cgm
    slot = get!(cgm.helpers, (:cfunction, f, rt, Tuple(argts))) do
        t = cfunction_thunk!(fc, f, rt, argts)
        _, _, funcs = cfunction_table!(cgm)
        push!(funcs, t)
        length(funcs)
    end
    o = new_local!(fc, jlvalue_ref(cgm.types))
    emit!(fc.b, :i64_const, CFUNCTION_BASE + slot)
    return new_ptr!(fc, Ptr{Cvoid}, o, nothing)
end

"The helper taking the address of a pointer to the reference to its function, of type `sig`."
function cfunction_target!(fc::FnCtx, sig::TypeRef)
    cgm = fc.cgm
    get!(cgm.helpers, (:cfunction_target, sig)) do
        g, arr, _ = cfunction_table!(cgm)
        f = add_func!(cgm.mod, helper_name(cgm, "cfunction_target"), ValType[I64], ValType[RefType(sig, false)])
        h = FnCtx(cgm, fc.info, nothing, Builder(cgm.mod, f))
        i = new_local!(h, I64)
        fr = new_local!(h, RefType(:func, true))
        emit!(h.b, :local_get, 0)
        emit!(h.b, :i64_const, CFUNCTION_BASE + 1)
        emit!(h.b, :i64_sub)
        emit!(h.b, :local_tee, i)
        emit!(h.b, :global_get, g)
        emit!(h.b, :array_len)
        emit!(h.b, :i64_extend_i32_u)
        emit!(h.b, :i64_ge_u)
        if!(h.b); throw_error!(h, Runtime.throw_not_cfunction); end!(h.b)
        emit!(h.b, :global_get, g)
        emit!(h.b, :local_get, i)
        emit!(h.b, :i32_wrap_i64)
        emit!(h.b, :array_get, arr)
        emit!(h.b, :local_tee, fr)
        emit!(h.b, :ref_test, sig)
        emit!(h.b, :i32_eqz)
        if!(h.b); throw_error!(h, Runtime.throw_not_cfunction); end!(h.b)
        emit!(h.b, :local_get, fr)
        emit!(h.b, :ref_cast, sig)
        finish!(h.b)
        f
    end
end

"A `ccall` whose target is the pointer `target`: the function in its slot of the table."
function emit_indirect_ccall!(fc::FnCtx, target::CGVal, ex::Expr, args::Vector{Any}, @nospecialize(typ))
    ex.args[4] == 0 || unsupported("a variadic ccall through a pointer")
    isconstant(target) && unsupported("a ccall through the constant pointer ", constant_value(target))
    rt = ex.args[2]
    argts = collect(Any, ex.args[3]::Core.SimpleVector)
    check_c_signature(rt, argts)
    cgm = fc.cgm
    params, results = c_signature(cgm, rt, argts)
    sig = WasmBuilder.functype!(cgm.mod, params, results)
    calls = get!(() -> Dict{TypeRef,Any}(), cgm.helpers, :cfunction_calls)
    haskey(calls, sig) || (calls[sig] = (fc.info.mi, rt, argts))
    for (v, T) in zip(args, argts)
        push_c_value!(fc, v::CGVal, T)
    end
    push_val!(fc, ptr_address(target))
    call!(fc.b, cfunction_target!(fc, sig))
    emit!(fc.b, :call_ref, sig)
    if c_pointer_slot(rt)
        o = new_local!(fc, jlvalue_ref(cgm.types))
        a = new_local!(fc, I64)
        emit!(fc.b, :local_set, o)
        emit!(fc.b, :local_set, a)
        return convert_repr(fc, c_argument(fc, rt, a, o), typ)
    end
    layout(fc, rt).kind === Ghost && return ghost(rt, something(ghost_value(rt)))
    return pop_val!(fc, rt)
end
