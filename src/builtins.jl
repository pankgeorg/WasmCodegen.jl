# Builtin functions (`Core.Builtin`s): object construction and access, identity, type
# tests, memory.

## construction

"""
    emit_new!(fc, T, args) -> CGVal

A new object of type `T` with the fields `args` (fewer than the fields of `T` leaves
the rest undefined).
"""
function emit_new!(fc::FnCtx, @nospecialize(T), args::Vector{CGVal})
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    if l.kind === Inline
        leaves = LeafVal[]
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            if i <= length(args)
                v = convert_repr(fc, args[i], FT)
                v.kind === Bottom && return v
                append!(leaves, v.leaves)
            else
                append!(leaves, undef_val(fc, FT).leaves)
            end
        end
        return CGVal(T, Inline, leaves)
    end
    is_memory_type(T) && unsupported("`new` of ", T)
    l.elements !== nothing && return new_tuple_array!(fc, T, args)
    # an object: the header, then the fields
    ts = fc.cgm.types
    emit!(fc.b, :i32_const, typeid!(ts, T))
    emit!(fc.b, :i32_const, 0)
    for i in 1:fieldcount(T)
        FT = fieldtype(T, i)
        if i <= length(args)
            v = convert_repr(fc, args[i], FT)
            v.kind === Bottom && return v
            push_val!(fc, v)
        else
            for leaf in field_leaves(ts, FT)
                push_default!(fc, leaf.type)
            end
        end
    end
    emit!(fc.b, :struct_new, l.wtype)
    return pop_val!(fc, T)
end

"""
    make_tuple(fc, T, vals) -> CGVal

The tuple of type `T` (concrete or not) of the values `vals`.
"""
function make_tuple(fc::FnCtx, @nospecialize(T), vals::Vector{CGVal})
    # a pair of constant strings (an `llvmcall`'s module IR and entry name) stays a constant: the
    # `llvmcall` lowering reads the IR from it
    (length(vals) == 2 && all(v -> isconstant(v) && constant_value(v) isa String, vals)) &&
        return const_value(fc, (constant_value(vals[1]), constant_value(vals[2])))
    l = layout(fc, T)
    l.kind === Boxed && l.elements !== nothing && return new_tuple_array!(fc, T, vals)
    if !isconcretetype(T) && !is_inline_tuple(T)
        # the concrete tuple type of the values
        T = Tuple{(v.typ for v in vals)...}
        isconcretetype(T) || unsupported("a tuple of abstract type ", T)
    end
    return emit_new!(fc, T, vals)
end

"The elements of the tuple value `t`."
function tuple_elements(fc::FnCtx, t::CGVal)
    T = t.typ
    (T isa DataType && T <: Tuple && isconcretetype(T)) ||
        unsupported("the elements of a tuple of type ", T)
    return CGVal[get_field(fc, t, i) for i in 1:fieldcount(T)]
end

## fields

function field_index(@nospecialize(T), f)
    if f isa Symbol
        i = Base.fieldindex(T, f, false)
        i == 0 && unsupported("the field ", f, " of ", T)
        return i
    end
    f isa Integer || unsupported("a field index ", f)
    return Int(f)
end

"""
The atomic operations on a field (`swapfield!`, `modifyfield!`, `replacefield!`,
`setfieldonce!`): with one thread, the reads and writes they are, in order (orderings do not
matter).
"""
function emit_atomic_field!(fc::FnCtx, @nospecialize(f), args::Vector{Any}, @nospecialize(typ))
    x, idx = args[1]::CGVal, args[2]::CGVal
    isconstant(idx) || unsupported(f, " of a field not known at compile time")
    i = field_index(x.typ, constant_value(idx))
    if f === Core.swapfield!
        old = get_field(fc, x, i)
        set_field!(fc, x, i, args[3])
        return old
    elseif f === Core.modifyfield!
        op, v = args[3]::CGVal, args[4]::CGVal
        isconstant(op) || unsupported("modifyfield! of a function not known at compile time")
        old = get_field(fc, x, i)
        new = call_runtime!(fc, constant_value(op), CGVal[old, v])
        set_field!(fc, x, i, new)
        return emit_new!(fc, typ, CGVal[old, new])
    elseif f === Core.replacefield!
        old = get_field(fc, x, i)
        success = emit_egal!(fc, old, args[3])
        push_val!(fc, success)
        if!(fc.b); set_field!(fc, x, i, args[4]); end!(fc.b)
        return emit_new!(fc, typ, CGVal[old, success])
    else
        # setfieldonce!: set if undefined
        undef = emit_isdefined!(fc, x, i)
        push_val!(fc, undef); emit!(fc.b, :i32_eqz)
        r = new_local!(fc, I32)
        emit!(fc.b, :local_tee, r)
        if!(fc.b); set_field!(fc, x, i, args[3]); end!(fc.b)
        emit!(fc.b, :local_get, r)
        return pop_val!(fc, Bool)
    end
end

"Whether `f` names no field of the concrete type `T` (in code inference has not proven dead)."
is_no_field(@nospecialize(T), @nospecialize(f)) =
    f isa Symbol && T isa DataType && isconcretetype(T) && Base.fieldindex(T, f, false) == 0

"A `FieldError`: the type `T` has no field `name`."
no_field!(fc::FnCtx, @nospecialize(T), name::Symbol) =
    throw_error!(fc, Runtime.throw_field_error, () -> convert_repr(fc, const_value(fc, T), Any), const_value(fc, name))

"""
    get_field(fc, x, i) -> CGVal

The field `i` (constant) of the value `x`.
"""
function get_field(fc::FnCtx, x::CGVal, i::Int)
    T = x.typ
    l = layout(fc, T)
    if isconstant(x) && (!ismutable(constant_value(x)) || constant_value(x) isa Type)
        # (a type's fields are fixed once it is made)
        return const_value(fc, getfield(constant_value(x), i))
    end
    FT = fieldtype(T, i)
    if l.kind === Inline
        if is_memoryref_type(T)
            i == 2 && return CGVal(FT, Boxed, LeafVal[x.leaves[1]])
            return memoryref_ptr!(fc, x)
        end
        fl = layout(fc, FT)
        fl.kind === Ghost && return ghost(FT, something(ghost_value(FT)))
        return CGVal(FT, fl.kind, x.leaves[l.fields[i]])
    elseif l.kind === Boxed && l.elements !== nothing
        return tuple_array_get!(fc, x, const_value(fc, i))
    elseif l.kind === Boxed && !isempty(l.fields)
        fl = layout(fc, FT)
        fl.kind === Ghost && return ghost(FT, something(ghost_value(FT)))
        fields = (typedef(fc.cgm.mod, l.wtype).comp::StructType).fields
        tmp = materialize!(fc, x)
        for w in l.fields[i]
            push_leaf!(fc, tmp)
            emit!(fc.b, fields[w].storage isa PackedType ? :struct_get_u : :struct_get, l.wtype, w - 1)
        end
        v = pop_val!(fc, FT)
        if fl.kind === Boxed && i > fieldcount(T) - T.name.n_uninitialized
            # a field constructors may leave undefined: reading it undefined is an error
            push_val!(fc, v); emit!(fc.b, :ref_is_null)
            if!(fc.b); throw_error!(fc, Runtime.throw_undefref_error); end!(fc.b)
        end
        return v
    elseif T === Core.TypeName && fieldname(T, i) === :name
        push_val!(fc, x)
        emit!(fc.b, :struct_get, l.wtype, HEADER_FIELDS)
        return pop_val!(fc, Symbol)
    elseif is_memory_type(T)
        name = fieldname(T, i)
        name === :ptr && return memory_ptr!(fc, x, FT)
        name === :length || unsupported("the field ", name, " of ", T)
        ml = memory_layout(fc.cgm.types, memory_eltype(T))
        push_memory_array!(fc, x)
        emit!(fc.b, :array_len)
        if ml.stride != 1
            emit!(fc.b, :i32_const, ml.stride)
            emit!(fc.b, :i32_div_u)
        end
        emit!(fc.b, :i64_extend_i32_u)
        return pop_val!(fc, Int)
    else
        unsupported("a field of a value of type ", T)
    end
end

# a leaf holding `x`'s reference (its local, or a new local for a constant)
function materialize!(fc::FnCtx, x::CGVal)
    leaf = only(x.leaves)
    leaf isa Int && return leaf
    push_leaf!(fc, leaf)
    tmp = new_local!(fc, layout(fc, x.typ).leaves[1].type)
    emit!(fc.b, :local_set, tmp)
    return tmp
end

function set_field!(fc::FnCtx, x::CGVal, i::Int, v::CGVal)
    T = x.typ
    l = layout(fc, T)
    (l.kind === Boxed && !isempty(l.fields) && ismutabletype(T)) ||
        unsupported("setfield! of a value of type ", T)
    FT = fieldtype(T, i)
    v = convert_repr(fc, v, FT)
    v.kind === Bottom && return v
    tmp = materialize!(fc, x)
    for (w, leaf) in zip(l.fields[i], v.leaves)
        push_leaf!(fc, tmp)
        push_leaf!(fc, leaf)
        emit!(fc.b, :struct_set, l.wtype, w - 1)
    end
    return v
end

## builtins

"""
    emit_builtin!(fc, f, args, typ) -> Union{Nothing,CGVal,MultiVal}

Emit a call of the builtin function `f`.
"""
function emit_builtin!(fc::FnCtx, f::Core.Builtin, args::Vector{Any}, @nospecialize(typ))
    if f === Core.getfield
        x = args[1]
        idx = args[2]
        if x isa MultiVal
            (idx isa CGVal && isconstant(idx)) || unsupported("a dynamic index into results")
            return x.vals[constant_value(idx)]
        end
        x = x::CGVal
        if isconstant(x) && isconstant(idx) && constant_value(x) isa Type
            # a field of a type (fixed once the type is made; a value of type Type{X})
            return const_value(fc, getfield(constant_value(x), constant_value(idx)))
        end
        if isconstant(idx)
            is_no_field(x.typ, constant_value(idx)) && return no_field!(fc, x.typ, constant_value(idx))
            return get_field(fc, x, field_index(x.typ, constant_value(idx)))
        end
        return get_field_dynamic(fc, x, idx, typ)
    elseif f === Core.setfield!
        x, idx, v = args[1], args[2], args[3]
        isconstant(idx) || unsupported("setfield! with a field not known at compile time")
        is_no_field(x.typ, constant_value(idx)) && return no_field!(fc, x.typ, constant_value(idx))
        return set_field!(fc, x, field_index(x.typ, constant_value(idx)), v)
    elseif f === Core.swapfield! || f === Core.modifyfield! || f === Core.replacefield! ||
           (isdefined(Core, :setfieldonce!) && f === Core.setfieldonce!)
        return emit_atomic_field!(fc, f, args, typ)
    elseif f === Core.isdefined
        x, idx = args[1], args[2]
        isconstant(idx) || return isdefined_dynamic!(fc, x, idx)
        is_no_field(x.typ, constant_value(idx)) && return const_value(fc, false)
        return emit_isdefined!(fc, x, field_index(x.typ, constant_value(idx)))
    elseif f === Core.:(===)
        return emit_egal!(fc, args[1], args[2])
    elseif f === Core.:(<:)
        return emit_subtype!(fc, args[1]::CGVal, args[2]::CGVal)
    elseif f === Core._svec_len
        x = args[1]::CGVal
        isconstant(x) && return const_value(fc, length(constant_value(x)))
        l = layout(fc, Core.SimpleVector)
        push_val!(fc, x)
        emit!(fc.b, :struct_get, l.wtype, DATA_FIELD)
        emit!(fc.b, :array_len)
        emit!(fc.b, :i64_extend_i32_u)
        return pop_val!(fc, Int)
    elseif f === Core._svec_ref
        x, i = args[1]::CGVal, args[2]::CGVal
        isconstant(x) && isconstant(i) && return const_value(fc, constant_value(x)[constant_value(i)])
        return tuple_array_get!(fc, x, i)
    elseif f === Core.svec
        return new_tuple_array!(fc, Core.SimpleVector, CGVal[a for a in args])
    elseif f === Core.isa
        T = args[2]
        isconstant(T) || return isa_types!(fc, args[1], T)
        return emit_isa!(fc, args[1], constant_value(T))
    elseif f === Core.typeassert
        T = args[2]
        t = isconstant(T) ? emit_isa!(fc, args[1], constant_value(T)) : isa_types!(fc, args[1], T)
        if !(isconstant(t) && constant_value(t))
            push_val!(fc, t)
            emit!(fc.b, :i32_eqz)
            if!(fc.b)
            throw_error!(fc, Runtime.throw_type_error, () -> convert_repr(fc, T, Any),
                         () -> convert_repr(fc, args[1], Any))
            end!(fc.b)
        end
        return convert_repr(fc, args[1], typ)
    elseif f === Core.typeof
        x = args[1]::CGVal
        isconcretetype(x.typ) && return const_value(fc, x.typ)
        return typeof_union!(fc, x, typ)
    elseif f === Core.tuple
        return make_tuple(fc, typ, CGVal[a for a in args])
    elseif f === Core.ifelse
        return emit_ifelse!(fc, args[1], args[2], args[3], typ)
    elseif f === Core.throw
        return emit_throw!(fc, args[1])
    elseif f === Core.throw_methoderror
        vals = CGVal[a for a in args[2:end]]
        # (the arguments' tuple; of values of types not known at compile time, a tuple of them
        # as `Any`s, as its type cannot be known either)
        argtuple() = all(v -> isconcretetype(v.typ), vals) ?
            make_tuple(fc, Tuple{Any[v.typ for v in vals]...}, vals) :
            new_tuple_array!(fc, Tuple{Vararg{Any}}, CGVal[convert_repr(fc, v, Any) for v in vals])
        return throw_error!(fc, Runtime.throw_method_error, () -> convert_repr(fc, args[1], Any),
                            () -> convert_repr(fc, argtuple(), Any))
    elseif f === Core.nfields
        x = args[1]::CGVal
        isconcretetype(x.typ) && return const_value(fc, fieldcount(x.typ))
        lx = layout(fc, x.typ)
        if lx.kind === Boxed && lx.elements !== nothing
            push_val!(fc, x)
            emit!(fc.b, :struct_get, lx.wtype, DATA_FIELD)
            emit_memory_length!(fc, lx.elements)
            emit!(fc.b, :i64_extend_i32_u)
            return pop_val!(fc, Int)
        end
        unsupported("nfields of a value of abstract type ", x.typ)
    elseif f === Core.sizeof
        x = args[1]::CGVal
        isconstant(x) && return const_value(fc, Core.sizeof(constant_value(x)))
        if x.typ === String || x.typ === Symbol
            push_val!(fc, x)
            emit!(fc.b, :struct_get, layout(fc, x.typ).wtype, DATA_FIELD)
            emit!(fc.b, :array_len)
            emit!(fc.b, :i64_extend_i32_u)
            return pop_val!(fc, Int)
        elseif is_memory_type(x.typ)
            n = get_field(fc, x, 1)
            push_val!(fc, n)
            emit!(fc.b, :i64_const, Base.aligned_sizeof(memory_eltype(x.typ)))
            emit!(fc.b, :i64_mul)
            return pop_val!(fc, Int)
        end
        isconcretetype(x.typ) && !is_memory_type(x.typ) && x.typ !== String &&
            return const_value(fc, Core.sizeof(x.typ))
        unsupported("sizeof of a value of type ", x.typ)
    elseif f === Core.compilerbarrier
        return args[2]
    elseif f === Core.donotdelete || f === Core.finalizer
        return ghost(Nothing, nothing)
    elseif f === Core.getglobal
        m, s = args[1], args[2]
        (isconstant(m) && isconstant(s)) || unsupported("getglobal of a binding not known at compile time")
        return operand(fc, GlobalRef(constant_value(m), constant_value(s)))
    elseif isdefined(Core, :isdefinedglobal) && f === getfield(Core, :isdefinedglobal)
        m, s = args[1], args[2]
        (isconstant(m) && isconstant(s)) || unsupported("isdefinedglobal of a binding not known at compile time")
        return isdefined_global!(fc, GlobalRef(constant_value(m), constant_value(s)))
    elseif f === Core.setglobal!
        m, s = args[1], args[2]
        (isconstant(m) && isconstant(s)) || unsupported("setglobal! of a binding not known at compile time")
        return set_global_var!(fc, GlobalRef(constant_value(m), constant_value(s)), args[3])
    elseif f === Core.memoryrefnew
        return outlined_memoryrefnew!(fc, args)
    elseif f === Core.memoryrefget
        return outlined_memoryrefget!(fc, args[1], args[3], typ)
    elseif f === Core.memoryrefset!
        return outlined_memoryrefset!(fc, args[1], args[2], args[4])
    elseif f === Core.memoryref_isassigned
        return outlined_isassigned!(fc, args[1], args[3])
    elseif f === Core.memoryrefoffset
        r = args[1]::CGVal
        push_leaf!(fc, r.leaves[3])
        emit!(fc.b, :i32_const, 1)
        emit!(fc.b, :i32_add)
        emit!(fc.b, :i64_extend_i32_u)
        return pop_val!(fc, Int)
    elseif isdefined(Core, :memorynew) && f === getfield(Core, :memorynew)
        return outlined_memorynew!(fc, constant_value(args[1]), args[2])
    elseif f === Core._apply_iterate
        return emit_apply_iterate!(fc, args, typ)
    elseif f === Core._call_in_world || f === Core._call_latest
        return emit_world_call!(fc, f, args, typ)
    elseif f === Core.apply_type
        all(a -> a isa CGVal && isconstant(a), args) &&
            return const_value(fc, Core.apply_type(map(constant_value, args)...))
        unsupported("apply_type of types not known at compile time")
    end
    unsupported("the builtin ", f)
end

function emit_isdefined!(fc::FnCtx, x::CGVal, i::Int)
    T = x.typ
    l = layout(fc, T)
    if l.kind === Boxed && !isempty(l.fields)
        FT = fieldtype(T, i)
        fls = field_leaves(fc.cgm.types, FT)
        if !isempty(fls) && fls[1].type isa RefType
            tmp = materialize!(fc, x)
            push_leaf!(fc, tmp)
            emit!(fc.b, :struct_get, l.wtype, first(l.fields[i]) - 1)
            emit!(fc.b, :ref_is_null)
            emit!(fc.b, :i32_eqz)
            return pop_val!(fc, Bool)
        end
    end
    return const_value(fc, true)
end

"""
`x isa t` of a type `t` not known at compile time, but one of a few (of static type
`Union{Type{A}, Type{B}, ...}`, as `typeof` of a value of a union is): of the one it is.
"""
function isa_types!(fc::FnCtx, x::CGVal, t::CGVal)
    Ts = t.typ isa Union ? Base.uniontypes(t.typ) : Any[]
    all(S -> S isa DataType && S.name === Type.body.name && !(S.parameters[1] isa TypeVar), Ts) && !isempty(Ts) ||
        unsupported("isa with a type not known at compile time (of type ", t.typ, ")")
    r = new_local!(fc, I32)
    emit!(fc.b, :i32_const, 0); emit!(fc.b, :local_set, r)
    for S in Ts
        C = S.parameters[1]
        push_val!(fc, emit_egal!(fc, t, const_value(fc, C)))
        if!(fc.b)
        push_val!(fc, emit_isa!(fc, x, C)); emit!(fc.b, :local_set, r)
        end!(fc.b)
    end
    emit!(fc.b, :local_get, r)
    return pop_val!(fc, Bool)
end

"`typeof(x)` of a value of a union of concrete types: the one it is (a chain of tests)."
function typeof_union!(fc::FnCtx, x::CGVal, @nospecialize(typ))
    Ts = Base.uniontypes(x.typ)
    (x.typ isa Union && all(isconcretetype, Ts)) ||
        unsupported("typeof of a value of abstract type ", x.typ)
    r = new_local!(fc, jlvalue_ref(fc.cgm.types))
    push_val!(fc, convert_repr(fc, const_value(fc, Ts[end]), Any)); emit!(fc.b, :local_set, r)
    for C in Ts[1:end-1]
        push_val!(fc, emit_isa!(fc, x, C))
        if!(fc.b)
        push_val!(fc, convert_repr(fc, const_value(fc, C), Any)); emit!(fc.b, :local_set, r)
        end!(fc.b)
    end
    emit!(fc.b, :local_get, r)
    return convert_repr(fc, pop_val!(fc, Any), typ)
end

"""
`isdefined(x, i)` of a field index `i` not known at compile time: whether the field it is is
defined (a chain of tests of the index); out of range, false.
"""
function isdefined_dynamic!(fc::FnCtx, x::CGVal, i::CGVal)
    T = x.typ
    (T isa DataType && isconcretetype(T) && i.typ <: Integer) ||
        unsupported("isdefined with a field not known at compile time")
    idx = convert_repr(fc, i, Int)
    r = new_local!(fc, I32)
    emit!(fc.b, :i32_const, 0); emit!(fc.b, :local_set, r)
    for k in 1:fieldcount(T)
        push_val!(fc, idx); emit!(fc.b, :i64_const, k); emit!(fc.b, :i64_eq)
        if!(fc.b)
        push_val!(fc, emit_isdefined!(fc, x, k)); emit!(fc.b, :local_set, r)
        end!(fc.b)
    end
    emit!(fc.b, :local_get, r)
    return pop_val!(fc, Bool)
end

"""
    get_field_dynamic(fc, x, i, typ) -> CGVal

The field of `x` at the run-time index or name `i` (1-based; out of bounds traps, as a
BoundsError or FieldError would): an element of the array of a large tuple; for an inline
tuple of one element type, an element of a temporary array of its elements; otherwise a
chain of tests of the index.
"""
function get_field_dynamic(fc::FnCtx, x::CGVal, i::CGVal, @nospecialize(typ))
    T = x.typ
    l = layout(fc, T)
    l.kind === Boxed && l.elements !== nothing && i.typ !== Symbol &&
        return tuple_array_get!(fc, x, i)
    (T isa DataType && (isconcretetype(T) || (l.kind === Inline && is_inline_tuple(T))) && l.elements === nothing) ||
        unsupported("a field of ", T, " at an index not known at compile time")
    n = fieldcount(T)
    if i.typ === Symbol
        # a name that is not a field's: a FieldError
        name = i
        i = field_index_of!(fc, T, i)
        push_val!(fc, i); emit!(fc.b, :i64_eqz)
        if!(fc.b); throw_error!(fc, Runtime.throw_field_error, () -> convert_repr(fc, const_value(fc, T), Any), name); end!(fc.b)
    end
    idx = convert_repr(fc, i, Int)
    # out of bounds: a BoundsError
    push_val!(fc, idx); emit!(fc.b, :i64_const, 1); emit!(fc.b, :i64_sub)
    emit!(fc.b, :i64_const, n); emit!(fc.b, :i64_ge_u)
    if!(fc.b); throw_error!(fc, Runtime.throw_bounds_error, () -> convert_repr(fc, x, Any), idx); end!(fc.b)
    if T <: Tuple && l.kind === Inline && is_homogeneous_tuple(T) && n > 4
        E = fieldtype(T, 1)
        ml = memory_layout(fc.cgm.types, E)
        if !ml.boxed && !ml.widened && layout(fc, E).kind !== Ghost
            push_val!(fc, x)
            emit!(fc.b, :array_new_fixed, ml.array, length(x.leaves))
            arr = new_local!(fc, RefType(ml.array, true))
            emit!(fc.b, :local_set, arr)
            return array_element_get!(fc, arr, ml, idx)
        end
    end
    res = new_val!(fc, typ)
    # a chain of ifs on the index, the last field otherwise
    for k in 1:n
        if k < n
            push_val!(fc, idx)
            emit!(fc.b, :i64_const, k)
            emit!(fc.b, :i64_eq)
            if!(fc.b); open_label!(fc)
        end
        assign!(fc, res, get_field(fc, x, k))
        k < n && else!(fc.b)
    end
    for k in 1:n-1
        end!(fc.b); close_label!(fc)
    end
    return res
end

# the index of the field of `T` named by the symbol `s` (an Int), 0 if there is none
function field_index_of!(fc::FnCtx, @nospecialize(T), s::CGVal)
    res = new_local!(fc, I64)
    emit!(fc.b, :i64_const, 0); emit!(fc.b, :local_set, res)
    for k in 1:fieldcount(T)
        e = emit_egal!(fc, s, const_value(fc, fieldname(T, k)))
        push_val!(fc, e)
        if!(fc.b); emit!(fc.b, :i64_const, k); emit!(fc.b, :local_set, res); end!(fc.b)
    end
    return CGVal(Int, Inline, LeafVal[res])
end

# the element at the (1-based, Int) index `idx` of the array in local `arr`, stored as `ml`
function array_element_get!(fc::FnCtx, arr::Int, ml::MemoryLayout, idx::CGVal)
    E = ml.elem.T
    pos = new_local!(fc, I32)
    push_val!(fc, idx)
    emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_const, 1)
    emit!(fc.b, :i32_sub)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride)
        emit!(fc.b, :i32_mul)
    end
    emit!(fc.b, :local_set, pos)
    for k in 0:ml.stride-1
        emit!(fc.b, :local_get, arr)
        emit!(fc.b, :local_get, pos)
        if k != 0
            emit!(fc.b, :i32_const, k)
            emit!(fc.b, :i32_add)
        end
        emit!(fc.b, array_get_op(ml.storage), ml.array)
        ml.widened && narrow_leaf!(fc, ml.elem.leaves[k+1].type)
    end
    if ml.boxed
        box = pop_val!(fc, Any)
        return unbox!(fc, box, E)
    end
    return pop_val!(fc, E)
end

"The element `i` (a value of type Int) of the large tuple `x`."
function tuple_array_get!(fc::FnCtx, x::CGVal, i::CGVal)
    l = layout(fc, x.typ)
    ml = l.elements::MemoryLayout
    push_val!(fc, x)
    emit!(fc.b, :struct_get, l.wtype, DATA_FIELD)
    arr = new_local!(fc, RefType(ml.array, true))
    emit!(fc.b, :local_set, arr)
    i = convert_repr(fc, i, Int)
    n = x.typ isa DataType && x.typ <: Tuple && !Base.isvatuple(x.typ) ? fieldcount(x.typ) : nothing
    if !(isconstant(i) && n !== nothing && 1 <= constant_value(i) <= n)
        # out of bounds (checked on the 64-bit index): a BoundsError
        push_val!(fc, i); emit!(fc.b, :i64_const, 1); emit!(fc.b, :i64_sub)
        emit!(fc.b, :local_get, arr); emit_memory_length!(fc, ml); emit!(fc.b, :i64_extend_i32_u)
        emit!(fc.b, :i64_ge_u)
        if!(fc.b); throw_error!(fc, Runtime.throw_bounds_error, () -> convert_repr(fc, x, Any), i); end!(fc.b)
    end
    return array_element_get!(fc, arr, ml, i)
end

"A large tuple of type `T` of the elements `args`."
function new_tuple_array!(fc::FnCtx, @nospecialize(T), args::Vector{CGVal})
    l = layout(fc, T)
    ml = l.elements::MemoryLayout
    E = ml.elem.T
    ts = fc.cgm.types
    emit!(fc.b, :i32_const, typeid!(ts, T))
    emit!(fc.b, :i32_const, 0)
    for a in args
        v = convert_repr(fc, a, E)
        if ml.boxed
            push_val!(fc, box!(fc, v, Any))
            is_union_tuple(E) || emit!(fc.b, :ref_cast_null, box_type!(ts, E))
        else
            for (k, leaf) in enumerate(v.leaves)
                push_leaf!(fc, leaf)
                ml.widened && widen_leaf!(fc, ml.elem.leaves[k].type)
            end
        end
    end
    emit!(fc.b, :array_new_fixed, ml.array, length(args) * ml.stride)
    emit!(fc.b, :struct_new, l.wtype)
    return pop_val!(fc, T)
end

## identity

"""
    emit_egal!(fc, a, b) -> CGVal

`a === b`: identity for mutable objects, equality of the bits for inline values.
"""
function emit_egal!(fc::FnCtx, a::CGVal, b::CGVal)
    if isconstant(a) && isconstant(b)
        return const_value(fc, constant_value(a) === constant_value(b))
    end
    Ta, Tb = a.typ, b.typ
    typeintersect(Ta, Tb) === Union{} && return const_value(fc, false)
    la, lb = layout(fc, Ta), layout(fc, Tb)
    if la.kind === Ghost && lb.kind === Ghost
        return const_value(fc, constant_value(a) === constant_value(b))
    end
    if la.kind === Ghost || lb.kind === Ghost
        # a singleton against a boxed value: its object
        g, o = la.kind === Ghost ? (a, b) : (b, a)
        lo = layout(fc, o.typ)
        lo.kind === Boxed && lo.wtype == fc.cgm.types.jlvalue ||
            unsupported("=== of ", Ta, " and ", Tb)
        push_val!(fc, o)
        emit!(fc.b, :global_get, singleton_global!(fc.cgm.image, g.typ))
        emit!(fc.b, :ref_eq)
        return pop_val!(fc, Bool)
    end
    if Ta === Tb && la.kind === Inline
        return egal_inline!(fc, a, b)
    end
    for S in (String, Symbol)
        if Ta === S || Tb === S
            # compared by content
            return egal_bytes!(fc, a, b, S)
        end
    end
    if Ta === Core.SimpleVector || Tb === Core.SimpleVector
        # (a SimpleVector is === another of the same elements)
        return egal_any!(fc, a, b)
    end
    if la.kind === Boxed && lb.kind === Boxed
        if (Ta === Tb && ismutabletype(Ta)) || (is_memory_type(Ta) && Ta === Tb)
            push_val!(fc, a); push_val!(fc, b)
            emit!(fc.b, :ref_eq)
            return pop_val!(fc, Bool)
        end
        if !may_be_immutable(Ta) || !may_be_immutable(Tb)
            # one side is always a mutable object: identity
            push_val!(fc, convert_repr(fc, a, Any)); push_val!(fc, convert_repr(fc, b, Any))
            emit!(fc.b, :ref_eq)
            return pop_val!(fc, Bool)
        end
    end
    # values whose types are known only at run time: compared by the module's own `jl_egal`
    return egal_any!(fc, a, b)
end

function egal_any!(fc::FnCtx, a::CGVal, b::CGVal)
    push_val!(fc, convert_repr(fc, a, Any)); push_val!(fc, convert_repr(fc, b, Any))
    call!(fc.b, egal_any_func!(fc.cgm))
    return pop_val!(fc, Bool)
end

# `a === b` where one of them is a `S` (a String or Symbol): of two of them, the same bytes
function egal_bytes!(fc::FnCtx, a::CGVal, b::CGVal, @nospecialize(S))
    st = layout(fc, S).wtype
    a.typ === S || ((a, b) = (b, a))
    if b.typ === S
        push_val!(fc, a); emit!(fc.b, :struct_get, st, DATA_FIELD)
        push_val!(fc, b); emit!(fc.b, :struct_get, st, DATA_FIELD)
        call!(fc.b, bytes_egal_func!(fc.cgm))
        return pop_val!(fc, Bool)
    end
    # the other one may be a `S`
    o = new_local!(fc, jlvalue_ref(fc.cgm.types))
    push_val!(fc, convert_repr(fc, b, Any)); emit!(fc.b, :local_set, o)
    emit!(fc.b, :local_get, o); emit!(fc.b, :ref_test, st)
    if!(fc.b, I32)
    push_val!(fc, a); emit!(fc.b, :struct_get, st, DATA_FIELD)
    emit!(fc.b, :local_get, o); emit!(fc.b, :ref_cast, st); emit!(fc.b, :struct_get, st, DATA_FIELD)
    call!(fc.b, bytes_egal_func!(fc.cgm))
    else!(fc.b)
    emit!(fc.b, :i32_const, 0)
    end!(fc.b)
    return pop_val!(fc, Bool)
end

# whether a value of type T may be an immutable non-ghost value (compared by content)
function may_be_immutable(@nospecialize(T))
    T === Union{} && return false
    if T isa Union
        return may_be_immutable(T.a) || may_be_immutable(T.b)
    end
    (T === String || T === Symbol) && return true
    T isa DataType && isconcretetype(T) && return !ismutabletype(T) && ghost_value(T) === nothing
    return true
end

function egal_inline!(fc::FnCtx, a::CGVal, b::CGVal)
    T = a.typ
    if isprimitivetype(T) || is_memoryref_type(T)
        leaves = layout(fc, T).leaves
        # pointers are the same if their addresses are
        is_ptr_type(T) && (leaves = leaves[1:1])
        first_leaf = true
        for (la, lb, leaf) in zip(a.leaves, b.leaves, leaves)
            t = leaf.type
            push_leaf!(fc, la)
            t === F64 && emit!(fc.b, :i64_reinterpret_f64)
            t === F32 && emit!(fc.b, :i32_reinterpret_f32)
            push_leaf!(fc, lb)
            t === F64 && emit!(fc.b, :i64_reinterpret_f64)
            t === F32 && emit!(fc.b, :i32_reinterpret_f32)
            if t isa RefType
                emit!(fc.b, :ref_eq)
            else
                emit!(fc.b, (t === I64 || t === F64) ? :i64_eq : :i32_eq)
            end
            first_leaf || emit!(fc.b, :i32_and)
            first_leaf = false
        end
        return pop_val!(fc, Bool)
    end
    res = const_value(fc, true)
    for i in 1:fieldcount(T)
        e = emit_egal!(fc, get_field(fc, a, i), get_field(fc, b, i))
        if isconstant(res)
            res = e
        else
            push_val!(fc, res); push_val!(fc, e)
            emit!(fc.b, :i32_and)
            res = pop_val!(fc, Bool)
        end
    end
    return res
end

## type tests

"""
    emit_isa!(fc, x, T) -> CGVal

`isa(x, T)`: known at compile time from the type of `x`, or a test of its type id.
"""
function emit_isa!(fc::FnCtx, x::CGVal, @nospecialize(T))
    S = x.typ
    S <: T && return const_value(fc, true)
    typeintersect(S, T) === Union{} && return const_value(fc, false)
    lx = layout(fc, S)
    ts = fc.cgm.types
    if lx.kind === Boxed && lx.elements !== nothing && T isa DataType && T <: Tuple &&
       !Base.isvatuple(T) && all(i -> eltype_intersects(lx.elements.elem.T, fieldtype(T, i)) && lx.elements.elem.T <: fieldtype(T, i), 1:fieldcount(T))
        # a tuple of unknown length: its length
        push_val!(fc, x)
        emit!(fc.b, :struct_get, lx.wtype, DATA_FIELD)
        emit_memory_length!(fc, lx.elements)
        emit!(fc.b, :i32_const, fieldcount(T))
        emit!(fc.b, :i32_eq)
        return pop_val!(fc, Bool)
    end
    if is_union_tuple(S)
        # of the concrete types of its union elements
        res = const_value(fc, false)
        for C in tuple_combinations(S)
            C <: T || continue
            t = union_tuple_isa!(fc, x, C)
            isconstant(res) ? (res = t) : (push_val!(fc, res); push_val!(fc, t); emit!(fc.b, :i32_or); res = pop_val!(fc, Bool))
        end
        return res
    end
    (lx.kind === Boxed && lx.wtype == fc.cgm.types.jlvalue) ||
        unsupported("isa(::", S, ", ", T, ")")
    if (X = type_singleton(T)) !== nothing
        # `Type{X}`: the type object of X itself
        push_val!(fc, x)
        emit!(fc.b, :global_get, object_global!(fc.cgm.image, something(X)))
        emit!(fc.b, :ref_eq)
        return pop_val!(fc, Bool)
    elseif T isa Union && any(U -> type_singleton(U) !== nothing, Base.uniontypes(T))
        # a union with some: of each member
        res = nothing
        for U in Base.uniontypes(T)
            r = emit_isa!(fc, x, U)
            if res === nothing
                res = r
            else
                push_val!(fc, res); push_val!(fc, r); emit!(fc.b, :i32_or)
                res = pop_val!(fc, Bool)
            end
        end
        return res
    end
    if T isa DataType && isconcretetype(T)
        push_val!(fc, x)
        emit!(fc.b, :struct_get, ts.jlvalue, 0)
        emit!(fc.b, :i32_const, typeid!(ts, T))
        emit!(fc.b, :i32_eq)
        return pop_val!(fc, Bool)
    end
    if tests_type_objects(T)
        # some types but not all of their kind (`Type{<:Real}`): a type object by the type it
        # is (see `reflection.jl`)
        push_val!(fc, x)
        call!(fc.b, type_isa_func!(fc.cgm, T))
        return pop_val!(fc, Bool)
    end
    # an abstract type or a union: the concrete types of the closed world that are its
    # subtypes (known when the module is complete)
    push_val!(fc, x)
    emit!(fc.b, :struct_get, ts.jlvalue, 0)
    call!(fc.b, isa_predicate!(fc.cgm, T))
    return pop_val!(fc, Bool)
end

# whether `x isa T` of a type `x` depends on more than the kind of type it is
tests_type_objects(@nospecialize(T)) =
    any(K -> typeintersect(K, T) !== Union{} && !(K <: T), (DataType, UnionAll, Union, Core.TypeofBottom))

## ifelse

function emit_ifelse!(fc::FnCtx, c::CGVal, a::CGVal, b::CGVal, @nospecialize(typ))
    c = convert_repr(fc, c, Bool)
    if isconstant(c)
        return convert_repr(fc, constant_value(c) ? a : b, typ)
    end
    a = convert_repr(fc, a, typ)
    b = convert_repr(fc, b, typ)
    l = layout(fc, typ)
    l.kind === Ghost && return a
    for (i, leaf) in enumerate(l.leaves)
        push_leaf!(fc, a.leaves[i])
        push_leaf!(fc, b.leaves[i])
        push_val!(fc, c)
        if leaf.type isa RefType
            emit!(fc.b, :select_t, ValType[leaf.type])
        else
            emit!(fc.b, :select)
        end
    end
    return pop_val!(fc, typ)
end

memory_type(@nospecialize(R)) = GenericMemory{R.parameters[1],R.parameters[2],R.parameters[3]}

eltype_intersects(@nospecialize(A), @nospecialize(B)) = typeintersect(A, B) !== Union{}

"""
    emit_world_call!(fc, f, args, typ) -> CGVal

`Core._call_in_world(world, f, args...)` and `Core._call_latest(f, args...)`, what
`Base.invoke_in_world` and `Base.invokelatest` lower to. A closed-world module has one
world, so with `Config(direct_world_calls = true)` a call whose callee is a constant and
whose arguments have known types is the direct call of the method the program world
dispatches to (added to the closed world as a runtime function is). Keyword calls arrive
as `Core.kwcall` with the named tuple first and resolve the same way.
"""
function emit_world_call!(fc::FnCtx, @nospecialize(f), args::Vector{Any}, @nospecialize(typ))
    fc.cgm.config.direct_world_calls || unsupported("the builtin ", f)
    rest = f === Core._call_in_world ? args[2:end] : args
    isempty(rest) && unsupported("a world call without a callee")
    callee = rest[1]
    (callee isa CGVal && isconstant(callee)) ||
        unsupported("a world call of a function value of type ", callee isa CGVal ? callee.typ : callee)
    cargs = CGVal[]
    for a in rest[2:end]
        a isa CGVal || unsupported("a world call with a multi-value argument")
        (isconstant(a) || isconcretetype(a.typ)) ||
            unsupported("a world call with an argument of abstract type ", a.typ)
        push!(cargs, a)
    end
    argtypes = Tuple(isconstant(a) ? Core.Typeof(constant_value(a)) : a.typ for a in cargs)
    info = runtime_function!(fc.cgm, constant_value(callee), argtypes)
    return emit_call_info!(fc, info, CGVal[callee, cargs...])
end

"""
    emit_apply_iterate!(fc, args, typ) -> CGVal

`Core._apply_iterate(iterate, f, xs...)`, the call of `f` with the elements of the `xs`
(splatting). Supported for `f = Core.tuple` (building a tuple) with tuples and vectors.
"""
function emit_apply_iterate!(fc::FnCtx, args::Vector{Any}, @nospecialize(typ))
    f = args[2]::CGVal
    (isconstant(f) && constant_value(f) === Core.tuple) ||
        unsupported("splatting into a call of ", isconstant(f) ? constant_value(f) : f.typ)
    xs = CGVal[a for a in args[3:end]]
    # elements known at compile time
    if all(x -> x.typ isa DataType && x.typ <: Tuple && !Base.isvatuple(x.typ), xs)
        elems = CGVal[]
        for x in xs
            append!(elems, tuple_elements(fc, x))
        end
        return make_tuple(fc, typ, elems)
    end
    # a tuple of unknown length, from one vector
    l = layout(fc, typ)
    (length(xs) == 1 && l.kind === Boxed && l.elements !== nothing) ||
        unsupported("splatting ", join([x.typ for x in xs], ", "), " into a tuple")
    v = xs[1]
    V = v.typ
    (V isa DataType && V <: Array && ndims(V) == 1 && eltype(V) <: l.elements.elem.T &&
     memory_layout(fc.cgm.types, eltype(V)).array == l.elements.array) ||
        unsupported("splatting a ", V, " into a tuple")
    ml = l.elements::MemoryLayout
    # copy the elements: a new array of the vector's length, from its first element
    ref = get_field(fc, v, 1)
    n = get_field(fc, get_field(fc, v, 2), 1)
    arr = new_local!(fc, RefType(ml.array, true))
    push_val!(fc, n)
    emit!(fc.b, :i32_wrap_i64)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul)
    end
    emit!(fc.b, :array_new_default, ml.array)
    emit!(fc.b, :local_set, arr)
    emit!(fc.b, :local_get, arr)
    emit!(fc.b, :i32_const, 0)
    push_element_address!(fc, ref, ml)
    push_val!(fc, n)
    emit!(fc.b, :i32_wrap_i64)
    if ml.stride != 1
        emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul)
    end
    emit!(fc.b, :array_copy, ml.array, ml.array)
    ts = fc.cgm.types
    emit!(fc.b, :i32_const, typeid!(ts, typ))
    emit!(fc.b, :i32_const, 0)
    emit!(fc.b, :local_get, arr)
    emit!(fc.b, :struct_new, l.wtype)
    return pop_val!(fc, typ)
end
