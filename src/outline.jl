# Outlined operations. An operation whose code grows with the value it moves (an element of
# a memory read or written leaf by leaf, a value boxed or unboxed field by field) is emitted
# once per type, as a helper function, and called where it is used; Binaryen inlines the
# helpers where that pays. A helper's body is the operation's inline emission, run in the
# helper's own context on its parameters, so there is one implementation of each.

"""
    call_outlined!(fc, key, name, args, T, body) -> CGVal

A call of the helper function for `key`, declared and emitted the first time (`name`, a string
or a function computing it, names it then: type names can be long to print): its
parameters are the leaves of the values `args` (in the representations of their types),
its result is a value of type `T`, and its body is `body(hfc, hargs)`, the emission of the
operation in the helper's context `hfc` on its parameters `hargs`. Constants the
operation depends on belong in `key`, not in `args`.
"""
function call_outlined!(fc::FnCtx, key, name, args::Vector{CGVal}, @nospecialize(T), body)
    cgm = fc.cgm
    lt = layout(fc, T)
    f = get(cgm.helpers, key, nothing)
    if f === nothing
        params = ValType[]
        for a in args
            append!(params, valtypes(cgm, a.typ))
        end
        results = lt.kind === Ghost || lt.kind === Bottom ? ValType[] : valtypes(cgm, T)
        f = add_func!(cgm.mod, helper_name(cgm, name isa AbstractString ? name : name()), params, results)
        cgm.helpers[key] = f
        hfc = FnCtx(cgm, fc.info, nothing, Builder(cgm.mod, f))
        hargs = CGVal[]
        k = 0
        for a in args
            la = layout(fc, a.typ)
            if la.kind === Ghost
                push!(hargs, ghost(a.typ, something(ghost_value(a.typ))))
            else
                n = length(la.leaves)
                push!(hargs, CGVal(a.typ, la.kind, LeafVal[k + j for j in 0:n-1]))
                k += n
            end
        end
        r = try
            body(hfc, hargs)
        catch
            # (a helper whose body cannot be compiled traps, should its caller trap instead)
            empty!(f.body)
            hb = Builder(cgm.mod, f)
            unreachable!(hb)
            finish!(hb)
            rethrow()
        end
        if !is_unreachable(hfc.b)
            if lt.kind === Bottom || r.kind === Bottom
                unreachable!(hfc.b)
            elseif lt.kind !== Ghost
                push_val!(hfc, convert_repr(hfc, r, T))
            end
        end
        finish!(hfc.b)
    end
    for a in args
        push_val!(fc, a)
    end
    call!(fc.b, f)
    lt.kind === Ghost && return ghost(T, something(ghost_value(T)))
    return pop_val!(fc, T)
end

# a readable name for a helper: the operation and its type, mangled
function helper_name(cgm::CGModule, name::AbstractString)
    return string("jl_", first(replace(name, r"[^A-Za-z0-9_]+" => "_"), 60), "_", length(cgm.mod.funcs) + 1)
end

# the constant value of a boundscheck argument (true where not known: checking is allowed)
boundscheck_value(bc) = bc isa CGVal && isconstant(bc) ? constant_value(bc)::Bool : true

typename_str(@nospecialize(T)) = sprint(show, T; context=:compact => true)

"`memoryrefget(r, order, boundscheck)`, by a helper per element type."
function outlined_memoryrefget!(fc::FnCtx, r::CGVal, bc, @nospecialize(typ))
    R = r.typ
    E = ref_eltype(R)
    b = boundscheck_value(bc)
    return call_outlined!(fc, (:memoryrefget, R, b), () -> "memoryrefget_" * typename_str(E), CGVal[r], E,
                          (h, a) -> emit_memoryrefget!(h, a[1], const_value(h, b), E))
end

"`memoryrefset!(r, v, order, boundscheck)`, by a helper per element type."
function outlined_memoryrefset!(fc::FnCtx, r::CGVal, v::CGVal, bc)
    R = r.typ
    E = ref_eltype(R)
    b = boundscheck_value(bc)
    v = convert_repr(fc, v, E)
    v.kind === Bottom && return v
    call_outlined!(fc, (:memoryrefset!, R, b), () -> "memoryrefset_" * typename_str(E), CGVal[r, v], Nothing,
                   (h, a) -> (emit_memoryrefset!(h, a[1], a[2], const_value(h, b)); ghost(Nothing, nothing)))
    return v
end

"`memoryrefnew(ref, i, boundscheck)` (from another reference), by a helper per type."
function outlined_memoryrefnew!(fc::FnCtx, args::Vector{Any})
    x = args[1]::CGVal
    (length(args) >= 2 && is_memoryref_type(x.typ)) || return emit_memoryrefnew!(fc, args)
    R = x.typ
    i = convert_repr(fc, args[2]::CGVal, Int)
    b = length(args) >= 3 ? boundscheck_value(args[3]) : true
    return call_outlined!(fc, (:memoryrefnew, R, b), () -> "memoryrefnew_" * typename_str(ref_eltype(R)),
                          CGVal[x, i], R, (h, a) -> emit_memoryrefnew!(h, Any[a[1], a[2], const_value(h, b)]))
end

"`memoryref_isassigned(r, order, boundscheck)`, by a helper per type."
function outlined_isassigned!(fc::FnCtx, r::CGVal, bc)
    R = r.typ
    b = boundscheck_value(bc)
    return call_outlined!(fc, (:isassigned, R, b), () -> "isassigned_" * typename_str(ref_eltype(R)), CGVal[r], Bool,
                          (h, a) -> emit_memoryref_isassigned!(h, a[1], const_value(h, b)))
end

"`memorynew(M, n)`, by a helper per memory type."
function outlined_memorynew!(fc::FnCtx, @nospecialize(M), n::CGVal)
    n = convert_repr(fc, n, Int)
    return call_outlined!(fc, (:memorynew, M), () -> "memorynew_" * typename_str(memory_eltype(M)), CGVal[n], M,
                          (h, a) -> emit_memorynew!(h, M, a[1]))
end
