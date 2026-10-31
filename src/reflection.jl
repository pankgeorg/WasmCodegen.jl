# Reflection on types at run time. Types are not made at run time: the types a program can
# hold are those whose objects are in its image, all known when the module is finished. So
# what code asks of a type at run time is computed natively for each of them, then, and
# looked up in a table: subtyping (`<:`), and functions of types (`Runtime.map_type`).

"The types whose objects are in the module, by type id."
type_objects(cgm::CGModule) =
    sort!(Any[T for T in keys(cgm.image.globals) if T isa Type], by=T -> typeid!(cgm.types, T))

"The index of each type of `types` (0-based, -1 for others), by type id (1-based)."
function type_index(cgm::CGModule, types::Vector{Any})
    index = fill(Int32(-1), length(cgm.types.typelist) + 1)
    for (k, T) in enumerate(types)
        index[typeid!(cgm.types, T) + 1] = k - 1
    end
    return index
end

"A global of an `index` array (made from a data segment on first use, see `push_type_index!`)."
function index_global!(cgm::CGModule, name::String, index::Vector{Int32})
    i32s = array_type!(cgm.types, I32)
    g = add_global!(cgm.mod, name, RefType(i32s, true), true, Inst[Inst(:ref_null, i32s)])
    return (g, add_data!(cgm.mod, collect(reinterpret(UInt8, index))), length(index))
end

# in a helper: the index of the type object in parameter `p` into local `k` (a trap if it
# is not a type the table has)
function push_type_index!(cgm::CGModule, b::Builder, (g, seg, n), p::Int, k::Int)
    i32s = array_type!(cgm.types, I32)
    st = type_object_type!(cgm.types)
    emit!(b, :global_get, g); emit!(b, :ref_is_null)
    if!(b)
    emit!(b, :i32_const, 0); emit!(b, :i32_const, n); emit!(b, :array_new_data, i32s, seg)
    emit!(b, :global_set, g)
    end!(b)
    emit!(b, :global_get, g)
    # (a type object's type id is its third field)
    emit!(b, :local_get, p); emit!(b, :ref_cast, st); emit!(b, :struct_get, st, 2)
    emit!(b, :array_get, i32s)
    emit!(b, :local_tee, k); emit!(b, :i32_const, 0); emit!(b, :i32_lt_s)
    if!(b); unreachable!(b); end!(b)
end

"""
    emit_subtype!(fc, a, b) -> CGVal

`a <: b` of two types. Types are not made at run time: the type objects of the module are
those of its image, and the subtyping of each pair of them is a table computed when the
module is finished (`finish_subtype!`), which a helper looks up.
"""
function emit_subtype!(fc::FnCtx, a::CGVal, b::CGVal)
    isconstant(a) && isconstant(b) && return const_value(fc, constant_value(a) <: constant_value(b))
    f = get!(fc.cgm.helpers, :subtype) do
        jl = jlvalue_ref(fc.cgm.types)
        add_func!(fc.cgm.mod, "jl_subtype", ValType[jl, jl], ValType[I32])
    end
    push_val!(fc, convert_repr(fc, a, Any))
    push_val!(fc, convert_repr(fc, b, Any))
    call!(fc.b, f)
    return pop_val!(fc, Bool)
end

function finish_subtype!(cgm::CGModule)
    f = get(cgm.helpers, :subtype, nothing)
    f === nothing && return
    ts = cgm.types
    types = type_objects(cgm)
    n = length(types)
    index = type_index(cgm, types)
    bits = zeros(UInt8, cld(n * n, 8))
    for (i, A) in enumerate(types), (j, B) in enumerate(types)
        if A <: B
            k = (i - 1) * n + (j - 1)
            bits[k >> 3 + 1] |= UInt8(1) << (k & 7)
        end
    end
    i8s = array_type!(ts, I8)
    gidx = index_global!(cgm, "jl_subtype_index", index)
    bits_seg = add_data!(cgm.mod, bits)
    gbits = add_global!(cgm.mod, "jl_subtype_table", RefType(i8s, true), true, Inst[Inst(:ref_null, i8s)])
    b = Builder(cgm.mod, f)
    ka, kb = add_local!(f, I32), add_local!(f, I32)
    # the table of bits, from data on first use
    emit!(b, :global_get, gbits); emit!(b, :ref_is_null)
    if!(b)
    emit!(b, :i32_const, 0); emit!(b, :i32_const, length(bits)); emit!(b, :array_new_data, i8s, bits_seg)
    emit!(b, :global_set, gbits)
    end!(b)
    push_type_index!(cgm, b, gidx, 0, ka)
    push_type_index!(cgm, b, gidx, 1, kb)
    # the bit (ka × n + kb)
    emit!(b, :global_get, gbits)
    emit!(b, :local_get, ka); emit!(b, :i32_const, n); emit!(b, :i32_mul)
    emit!(b, :local_get, kb); emit!(b, :i32_add)
    emit!(b, :local_tee, ka); emit!(b, :i32_const, 3); emit!(b, :i32_shr_u)
    emit!(b, :array_get_u, i8s)
    emit!(b, :local_get, ka); emit!(b, :i32_const, 7); emit!(b, :i32_and)
    emit!(b, :i32_shr_u); emit!(b, :i32_const, 1); emit!(b, :i32_and)
    finish!(b)
end

"""
    typeof_any!(fc, x, typ) -> CGVal

`typeof(x)` of a value of an abstract type: the type object of its type id, from a table of
the type objects of the module's concrete types (`finish_typeof!`), which a helper looks up.
"""
function typeof_any!(fc::FnCtx, x::CGVal, @nospecialize(typ))
    h = get!(fc.cgm.helpers, :typeof) do
        jl = jlvalue_ref(fc.cgm.types)
        add_func!(fc.cgm.mod, "jl_typeof", ValType[jl], ValType[jl])
    end
    # (the error of a value whose type is not one of the module's: see finish_typeof!)
    get!(() -> runtime_function!(fc.cgm, Runtime.throw_typeof_unknown, ()), fc.cgm.helpers, :typeof_unknown)
    push_val!(fc, convert_repr(fc, x, Any))
    call!(fc.b, h)
    return convert_repr(fc, pop_val!(fc, Any), typ)
end

# the table of `typeof`: by type id, the type object of each concrete type of the module (the
# type objects themselves added by `add_reflection_types!`, before any table over types). A
# value's type id is one of them, but for a tuple of a concrete type the module does not have
# (an object of `Tuple`, see `tuple_canon_func!`): its `typeof` is an error.
function finish_typeof!(cgm::CGModule)
    h = get(cgm.helpers, :typeof, nothing)
    h === nothing && return
    ts, img = cgm.types, cgm.image
    concrete(T) = T isa DataType && isconcretetype(T)
    add_reflection_types!(cgm) == 0 || error("WasmCodegen: typeof's type objects added after the tables over types")
    jl = jlvalue_ref(ts)
    refs = array_type!(ts, jl)
    n = length(ts.typelist)
    n <= 10_000 || unsupported("typeof of a value of abstract type in a module of more than 10000 types")
    elems = Inst[concrete(T) ? Inst(:global_get, object_global!(img, T)) : Inst(:ref_null, ts.jlvalue)
                 for T in ts.typelist]
    table = add_global!(cgm.mod, "jl_typeof_table", RefType(refs, false), false,
                        Inst[elems..., Inst(:array_new_fixed, refs, n)])
    b = Builder(cgm.mod, h)
    r = add_local!(h, jl)
    # (type ids are from 1; not of a concrete type: the error; a type id the table does not
    # have cannot be a value's, as all the module's types are made before)
    emit!(b, :global_get, table)
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0)
    emit!(b, :i32_const, 1); emit!(b, :i32_sub)
    emit!(b, :array_get, refs)
    emit!(b, :local_tee, r); emit!(b, :ref_is_null)
    if!(b)
    call!(b, (cgm.helpers[:typeof_unknown]::FuncInfo).func)
    unreachable!(b)
    end!(b)
    emit!(b, :local_get, r)
    finish!(b)
end

"""
    emit_map_type!(fc, f, T) -> CGVal

`Runtime.map_type(f, T)`: the type `f(T)`, from a table of `f` over the module's types.
"""
function emit_map_type!(fc::FnCtx, @nospecialize(f), t::CGVal)
    isconstant(t) && return const_value(fc, f(constant_value(t)))
    h = get!(fc.cgm.helpers, (:map_type, f)) do
        jl = jlvalue_ref(fc.cgm.types)
        add_func!(fc.cgm.mod, string("jl_map_type_", nameof(f)), ValType[jl], ValType[jl])
    end
    push_val!(fc, convert_repr(fc, t, Any))
    call!(fc.b, h)
    return pop_val!(fc, Any)
end

"""
    finish_type_maps!(cgm)

The tables of the functions of types the module uses: each one's values on all types of the
module, whose objects are added to it (until every type of the module has its value).
"""
function finish_type_maps!(cgm::CGModule)
    maps = [(k[2], f) for (k, f) in cgm.helpers if k isa Tuple && k[1] === :map_type]
    isempty(maps) && return
    img = cgm.image
    add_reflection_types!(cgm)
    types = type_objects(cgm)
    ts = cgm.types
    jl = jlvalue_ref(ts)
    refs = array_type!(ts, jl)
    for (f, h) in maps
        gidx = index_global!(cgm, string("jl_map_type_index_", nameof(f)), type_index(cgm, types))
        elems = Inst[Inst(:global_get, object_global!(img, f(T))) for T in types]
        values = add_global!(cgm.mod, string("jl_map_type_", nameof(f)), RefType(refs, false), false,
                             Inst[elems..., Inst(:array_new_fixed, refs, length(types))])
        b = Builder(cgm.mod, h)
        k = add_local!(h, I32)
        push_type_index!(cgm, b, gidx, 0, k)
        emit!(b, :global_get, values)
        emit!(b, :local_get, k)
        emit!(b, :array_get, refs)
        finish!(b)
    end
end

# the type objects reflection on types at run time needs, before any table over types is made:
# of the values of the module's functions of types (`add_type_map_types!`), and with `typeof`,
# of every concrete type of the module (a value's type); each can add types for the other,
# until neither adds any (the number of types added)
function add_reflection_types!(cgm::CGModule)
    ts, img = cgm.types, cgm.image
    added = 0
    while true
        n0, m0 = length(ts.typelist), length(img.globals)
        if haskey(cgm.helpers, :typeof)
            for T in copy(ts.typelist)
                T isa DataType && isconcretetype(T) && object_global!(img, T)
            end
        end
        add_type_map_types!(cgm)
        n1, m1 = length(ts.typelist), length(img.globals)
        (n1 == n0 && m1 == m0) && return added
        added += (n1 - n0) + (m1 - m0)
    end
end

# the type objects of the values of the module's functions of types on its types, until they
# add none (the number of types added)
function add_type_map_types!(cgm::CGModule)
    maps = [k[2] for k in keys(cgm.helpers) if k isa Tuple && k[1] === :map_type]
    isempty(maps) && return 0
    types = type_objects(cgm)
    n = length(types)
    while true
        for f in maps, T in types
            object_global!(cgm.image, f(T))
        end
        all = type_objects(cgm)
        length(all) == length(types) && break
        types = all
    end
    return length(types) - n
end

## isa of type objects

"""
    type_isa_func!(cgm, T) -> Func

`(x::\$JlValue) -> i32`: `x isa T` where `T` holds some types: of a type object, from a table
over the module's types of whether each is a `T`; of another object, by its type id.
"""
type_isa_func!(cgm::CGModule, @nospecialize(T)) = get!(cgm.helpers, (:type_isa, T)) do
    jl = jlvalue_ref(cgm.types)
    add_func!(cgm.mod, string("jl_type_isa_", replace(string(T), r"[^A-Za-z0-9_]" => "_")), ValType[jl], ValType[I32])
end

function finish_type_isa!(cgm::CGModule)
    helpers = [(k[2], f) for (k, f) in cgm.helpers if k isa Tuple && k[1] === :type_isa]
    isempty(helpers) && return
    ts = cgm.types
    types = type_objects(cgm)
    st = type_object_type!(ts)
    i8s = array_type!(ts, I8)
    for (T, f) in helpers
        gidx = index_global!(cgm, string("jl_type_isa_index"), type_index(cgm, types))
        bits = UInt8[types[k] isa T for k in eachindex(types)]
        seg = add_data!(cgm.mod, isempty(bits) ? UInt8[0] : bits)
        gbits = add_global!(cgm.mod, "jl_type_isa_table", RefType(i8s, true), true, Inst[Inst(:ref_null, i8s)])
        b = Builder(cgm.mod, f)
        k = add_local!(f, I32)
        emit!(b, :local_get, 0); emit!(b, :ref_test, st)
        if!(b, I32)
        emit!(b, :global_get, gbits); emit!(b, :ref_is_null)
        if!(b)
        emit!(b, :i32_const, 0); emit!(b, :i32_const, max(1, length(bits))); emit!(b, :array_new_data, i8s, seg)
        emit!(b, :global_set, gbits)
        end!(b)
        push_type_index!(cgm, b, gidx, 0, k)
        emit!(b, :global_get, gbits); emit!(b, :local_get, k); emit!(b, :array_get_u, i8s)
        else!(b)
        emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0)
        call!(b, isa_predicate!(cgm, T))
        end!(b)
        finish!(b)
    end
end

## === of values whose types are known only at run time

"""
    egal_any_func!(cgm) -> Func

`jl_egal(a::\$JlValue, b::\$JlValue) -> i32`: `a === b`. The same object, or objects of one
type compared as Julia does: mutable ones by identity; strings and symbols by their bytes;
immutable values (boxed inline values, immutable objects, tuples, SimpleVectors) by their
fields, numbers by their bits and references with `jl_egal`. Generated when the module's
types are known (`finish_egal!`); a type it cannot compare traps.
"""
egal_any_func!(cgm::CGModule) = get!(cgm.helpers, :egal_any) do
    jl = jlvalue_ref(cgm.types)
    add_func!(cgm.mod, "jl_egal", ValType[jl, jl], ValType[I32])
end

function finish_egal!(cgm::CGModule)
    f = get(cgm.helpers, :egal_any, nothing)
    f === nothing && return
    ts = cgm.types
    b = Builder(cgm.mod, f)
    jl = jlvalue_ref(ts)
    tid = add_local!(f, I32)
    # the same object, one null, or different types
    emit!(b, :local_get, 0); emit!(b, :local_get, 1); emit!(b, :ref_eq)
    if!(b); emit!(b, :i32_const, 1); return!(b); end!(b)
    emit!(b, :local_get, 0); emit!(b, :ref_is_null); emit!(b, :local_get, 1); emit!(b, :ref_is_null); emit!(b, :i32_or)
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_tee, tid)
    emit!(b, :local_get, 1); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :i32_ne)
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    casts = Dict{TypeRef,Tuple{Int,Int}}()
    cast_locals(st) = get!(casts, st) do
        (add_local!(f, RefType(st, true)), add_local!(f, RefType(st, true)))
    end
    for (id, T) in enumerate(copy(ts.typelist))
        # (and tuples of a type of unknown length, their concrete one not in the module)
        (T isa DataType && (isconcretetype(T) || is_array_tuple(T))) || continue
        l = layout(ts, T)
        # the Wasm struct type of T's objects, and what to compare in it
        st, how = if T === String || T === Symbol
            bytes_object_type!(ts, T), :bytes
        elseif T === Core.SimpleVector || (l.kind === Boxed && l.elements !== nothing && !ismutabletype(T))
            l.wtype, :elements
        elseif ismutabletype(T) || is_memory_type(T) || any(R -> T === R, RUNTIME_TYPES) || l.kind === Ghost
            nothing, :identity
        elseif l.kind === Boxed && !isempty(l.fields)
            l.wtype, :fields
        elseif l.kind === Inline && haskey(ts.boxes, (:box, T))
            ts.boxes[(:box, T)], :fields
        else
            nothing, :none
        end
        how === :none && continue
        emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
        if!(b)
        if how === :identity
            emit!(b, :i32_const, 0); return!(b)
        else
            ca, cb = cast_locals(st)
            emit!(b, :local_get, 0); emit!(b, :ref_cast, st); emit!(b, :local_set, ca)
            emit!(b, :local_get, 1); emit!(b, :ref_cast, st); emit!(b, :local_set, cb)
            if how === :bytes
                emit!(b, :local_get, ca); emit!(b, :struct_get, st, DATA_FIELD)
                emit!(b, :local_get, cb); emit!(b, :struct_get, st, DATA_FIELD)
                call!(b, bytes_egal_func!(cgm))
                return!(b)
            elseif how === :elements
                egal_array_elements!(cgm, b, f, st, l.elements::MemoryLayout, ca, cb)
            else
                # (fields from the header's end, as `egal_leaves`)
                emit_fields_egal!(cgm, b, f, st, ca, cb, egal_leaves(ts, T))
                emit!(b, :i32_const, 1); return!(b)
            end
        end
        end!(b)
    end
    # a type it cannot compare
    unreachable!(b)
    finish!(b)
end

## objectid of values whose types are known only at run time

"""
    objectid_any_func!(cgm) -> Func

`jl_object_id(x::\$JlValue) -> i64`: `objectid(x)`, by the type of `x`: of each type whose
values are objects, the code of `objectid` of a value of that type (`Runtime.objectid_as`,
compiled with the module's code, see `compile_runtime_cases!`). Generated when the module's
types are known (`finish_objectid_any!`); a type it has no case for traps.
"""
objectid_any_func!(cgm::CGModule) = get!(cgm.helpers, :objectid_any) do
    add_func!(cgm.mod, "jl_object_id", ValType[jlvalue_ref(cgm.types)], ValType[I64])
end

# the types whose values may be objects of their own (boxed, or inline with a box): those
# `jl_object_id` has cases for (types and other objects of the runtime: by identity)
function objectid_case_type(ts::Types, @nospecialize(T))
    (T isa DataType && isconcretetype(T)) || return false
    any(R -> T === R, RUNTIME_TYPES) && return false
    l = layout(ts, T)
    return l.kind === Boxed || l.kind === Ghost || (l.kind === Inline && haskey(ts.boxes, (:box, T)))
end

"""
    compile_runtime_cases!(cgm)

Compiles the cases of the helpers that dispatch on the module's types (`jl_object_id`, the
conversions of tuples of unknown length), once the module's code is compiled: until they, and
the values of its functions of types (`add_type_map_types!`), add no types. (Compiled for every type they may meet, whether or not a value of it ever reaches
them: a case that cannot be compiled traps there, and is not an error of the program.)
"""
function compile_runtime_cases!(cgm::CGModule)
    config, ndiag = cgm.config, length(cgm.diagnostics)
    cgm.config = Config(; on_unsupported=:trap, trim=:unsafe, verify=config.verify,
                        trim_patches=config.trim_patches, optimize=config.optimize)
    try
        while true
            n = add_reflection_types!(cgm) + add_objectid_cases!(cgm) + add_tuple_cases!(cgm)
            n == 0 && break
            process_worklist!(cgm)
        end
    finally
        cgm.config = config
        resize!(cgm.diagnostics, ndiag)
    end
end

# the cases of `jl_object_id`: `objectid` of each type whose values may be objects (the
# number of cases added)
function add_objectid_cases!(cgm::CGModule)
    haskey(cgm.helpers, :objectid_any) || return 0
    cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, :objectid_cases)
    ts = cgm.types
    n = length(cases)
    for (id, T) in enumerate(copy(ts.typelist))
        haskey(cases, id) && continue
        if objectid_case_type(ts, T)
            cases[id] = runtime_function!(cgm, Runtime.objectid_as, (Any, Type{T}))
        elseif T === Tuple
            # (a tuple whose concrete type the module does not have: see `tuple_canon_func!`)
            cases[id] = runtime_function!(cgm, Runtime.tuple_objectid, (Any, Val{T}))
        end
    end
    return length(cases) - n
end

function finish_objectid_any!(cgm::CGModule)
    f = get(cgm.helpers, :objectid_any, nothing)
    f === nothing && return
    cases = get(cgm.helpers, :objectid_cases, Dict{Int,FuncInfo}())
    ts = cgm.types
    b = Builder(cgm.mod, f)
    tid = add_local!(f, I32)
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
    for (id, T) in enumerate(ts.typelist)
        info = get(cases, id, nothing)
        if info === nothing
            # mutable objects and type objects: by identity
            ((T isa DataType && ismutabletype(T)) || is_type_object_type(T)) || continue
        end
        emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
        if!(b)
        emit!(b, :local_get, 0)
        call!(b, info === nothing ? objectid_mutable_func!(cgm) : info.func)
        return!(b)
        end!(b)
    end
    unreachable!(b)
    finish!(b)
end

# how `jl_egal` compares each leaf of the immutable type `T` (of its box or its object, after
# the header): as it is stored (`nothing`); not (`:owner`, of a pointer: a pointer is ===
# another of the same address); a tuple of unknown length `S`, by its elements (the type id
# of its array object is not its value's: see `tuple_canon_func!`)
function egal_leaves(ts::Types, @nospecialize(T))
    is_ptr_type(T) && return Any[nothing, :owner]
    l = layout(ts, T)
    off = l.kind === Boxed ? HEADER_FIELDS : 0
    n = l.kind === Boxed ? maximum(last, l.fields; init=off) - off : length(l.leaves)
    how = Any[nothing for _ in 1:n]
    for (i, r) in enumerate(l.fields)
        isempty(r) && continue
        FT = fieldtype(T, i)
        lf = layout(ts, FT)
        if lf.kind === Inline
            how[r .- off] = egal_leaves(ts, FT)
        elseif is_array_tuple(FT) && lf.elements !== nothing
            how[first(r) - off] = FT
        end
    end
    return how
end

"""
`jl_tuple_egal(a::S, b::S) -> i32`: `a === b` of tuples of the type of unknown length `S`, by
their elements (`jl_egal` the function comparing others).
"""
tuple_egal_func!(cgm::CGModule, @nospecialize(S), egal::Func) = get!(cgm.helpers, (:tuple_egal, S)) do
    l = layout(cgm.types, S)
    r = RefType(l.wtype, true)
    h = add_func!(cgm.mod, "jl_tuple_egal_" * typename_str(S), ValType[r, r], ValType[I32])
    b = Builder(cgm.mod, h)
    emit!(b, :local_get, 0); emit!(b, :local_get, 1); emit!(b, :ref_eq)
    if!(b); emit!(b, :i32_const, 1); return!(b); end!(b)
    emit!(b, :local_get, 0); emit!(b, :ref_is_null); emit!(b, :local_get, 1); emit!(b, :ref_is_null); emit!(b, :i32_or)
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    egal_array_elements!(cgm, b, h, l.wtype, l.elements::MemoryLayout, 0, 1; egal)
    finish!(b)
    h
end

## tuples of unknown length as objects

# A value of a tuple type of unknown length `S` (`Tuple`, `Tuple{Vararg{Int}}`, ...) is an
# array object (`tuple_array_layout`), while a tuple held as an object (an `Any`) is one of its
# concrete type, `C`: a box (or its own object). From an `S` to an object, it is of the
# concrete type its elements make it, where the module has that type (one it tests for,
# boxes, ...); else, a type no code of the module names, an array object of `Tuple` (of its
# elements as objects, of `Tuple`'s type id: the one such object of its elements, whatever
# `S` it came from, compared and hashed by its elements, and tested by them for tuple types).
# From an object to an `S`, an array object of its elements. By helpers per `S`, generated
# with the module's types (`finish_tuples!`), of cases per `C` compiled with its code
# (`Runtime.tuple_as`, `Runtime.tuple_from`, `Runtime.tuple_any`).

"`jl_tuple_canon(x::S) -> \$JlValue`: the tuple `x` of the tuple type of unknown length `S` as an object."
tuple_canon_func!(cgm::CGModule, @nospecialize(S)) = get!(cgm.helpers, (:tuple_canon, S)) do
    l = layout(cgm.types, S)
    add_func!(cgm.mod, "jl_tuple_canon_" * typename_str(S), ValType[l.leaves[1].type],
              ValType[jlvalue_ref(cgm.types)])
end

"`jl_tuple_from(x::\$JlValue) -> S`: the tuple object `x` as a value of the tuple type of unknown length `S`."
tuple_from_func!(cgm::CGModule, @nospecialize(S)) = get!(cgm.helpers, (:tuple_from, S)) do
    l = layout(cgm.types, S)
    add_func!(cgm.mod, "jl_tuple_from_" * typename_str(S), ValType[jlvalue_ref(cgm.types)],
              ValType[l.leaves[1].type])
end

# the concrete tuple types of the module of the tuple type of unknown length `S`
function tuple_case_types(ts::Types, @nospecialize(S))
    return [(id, C) for (id, C) in enumerate(ts.typelist)
            if C isa DataType && C <: Tuple && isconcretetype(C) && C <: S && C !== S]
end

# the cases of the tuple helpers (the number added)
function add_tuple_cases!(cgm::CGModule)
    ts = cgm.types
    added = 0
    for key in collect(keys(cgm.helpers))
        (key isa Tuple && length(key) == 2 && (key[1] === :tuple_canon || key[1] === :tuple_from)) || continue
        kind, S = key
        cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, (:tuple_cases, kind, S))
        typeid!(ts, Nothing); typeid!(ts, Tuple)
        # (of a type the module does not have, an object of `Tuple`: from an `S` whose
        # elements are stored otherwise, as one)
        other = layout(ts, S).wtype != layout(ts, Tuple).wtype
        if other && kind === :tuple_canon && !haskey(cgm.helpers, (:tuple_any, S))
            cgm.helpers[(:tuple_any, S)] = runtime_function!(cgm, Runtime.tuple_any, (S,))
            added += 1
        end
        cs = tuple_case_types(ts, S)
        other && kind === :tuple_from && push!(cs, (typeid!(ts, Tuple), Tuple))
        for (id, C) in cs
            haskey(cases, id) && continue
            # (from an object: only of types whose values may be objects)
            kind === :tuple_from && C !== Tuple && !objectid_case_type(ts, C) && continue
            cases[id] = kind === :tuple_canon ?
                runtime_function!(cgm, Runtime.tuple_as, (S, Type{C})) :
                runtime_function!(cgm, Runtime.tuple_from, (Any, Val{C}, Val{S}))
            added += 1
        end
    end
    return added
end

function finish_tuples!(cgm::CGModule)
    ts = cgm.types
    for (key, f) in collect(cgm.helpers)
        (key isa Tuple && length(key) == 2 && (key[1] === :tuple_canon || key[1] === :tuple_from)) || continue
        kind, S = key
        f = f::Func
        cases = sort!(collect(get(cgm.helpers, (:tuple_cases, kind, S), Dict{Int,FuncInfo}())); by=first)
        l = layout(ts, S)
        ml = l.elements::MemoryLayout
        b = Builder(cgm.mod, f)
        if kind === :tuple_canon
            # of the concrete type of its length whose element types its elements are of
            n = add_local!(f, I32)
            r = add_local!(f, jlvalue_ref(ts))
            emit!(b, :local_get, 0); emit!(b, :struct_get, l.wtype, DATA_FIELD); emit!(b, :array_len)
            ml.stride != 1 && (emit!(b, :i32_const, ml.stride); emit!(b, :i32_div_u))
            emit!(b, :local_set, n)
            for (id, info) in cases
                emit!(b, :local_get, n); emit!(b, :i32_const, fieldcount(ts.typelist[id])); emit!(b, :i32_eq)
                if!(b)
                emit!(b, :local_get, 0); call!(b, info.func); emit!(b, :local_tee, r)
                emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :i32_const, typeid!(ts, Nothing)); emit!(b, :i32_ne)
                if!(b); emit!(b, :local_get, r); return!(b); end!(b)
                end!(b)
            end
            # (else an object of `Tuple`, a new one)
            lT = layout(ts, Tuple)
            emit!(b, :i32_const, typeid!(ts, Tuple)); emit!(b, :i32_const, 0)
            emit!(b, :local_get, 0)
            g = get(cgm.helpers, (:tuple_any, S), nothing)
            g === nothing || call!(b, (g::FuncInfo).func)
            emit!(b, :struct_get, g === nothing ? l.wtype : lT.wtype, DATA_FIELD)
            emit!(b, :struct_new, lT.wtype)
        else
            # an array object of the same elements' storage, or by the concrete type it is
            emit!(b, :local_get, 0); emit!(b, :ref_test, l.wtype)
            if!(b); emit!(b, :local_get, 0); emit!(b, :ref_cast, l.wtype); return!(b); end!(b)
            tid = add_local!(f, I32)
            emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
            for (id, info) in cases
                emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
                if!(b); emit!(b, :local_get, 0); call!(b, info.func); return!(b); end!(b)
            end
            unreachable!(b)
        end
        finish!(b)
    end
end

function emit_fields_egal!(cgm::CGModule, b::Builder, f::Func, st::TypeRef, ca::Int, cb::Int,
                           how::Vector{Any})
    fields = (typedef(cgm.mod, st).comp::StructType).fields
    for w in HEADER_FIELDS+1:length(fields)
        k = w - HEADER_FIELDS
        h = k <= length(how) ? how[k] : nothing
        h === :owner && continue
        stg = fields[w].storage
        get = stg isa PackedType ? :struct_get_u : :struct_get
        emit!(b, :local_get, ca); emit!(b, get, st, w - 1)
        stg === F64 && emit!(b, :i64_reinterpret_f64)
        stg === F32 && emit!(b, :i32_reinterpret_f32)
        emit!(b, :local_get, cb); emit!(b, get, st, w - 1)
        if stg === F64
            emit!(b, :i64_reinterpret_f64); emit!(b, :i64_ne)
        elseif stg === F32
            emit!(b, :i32_reinterpret_f32); emit!(b, :i32_ne)
        elseif stg === I64
            emit!(b, :i64_ne)
        elseif stg isa RefType && stg.heap isa TypeRef && typedef(cgm.mod, stg.heap).comp isa ArrayType
            # (the array of a memory, in a reference to its element: the same memory)
            emit!(b, :ref_eq); emit!(b, :i32_eqz)
        elseif stg isa RefType && h !== nothing
            call!(b, tuple_egal_func!(cgm, h, f)); emit!(b, :i32_eqz)
        elseif stg isa RefType
            # (a reference to some object: compared with jl_egal)
            call!(b, f); emit!(b, :i32_eqz)
        else
            emit!(b, :i32_ne)
        end
        if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    end
end

# the elements of two array objects (tuples, SimpleVectors) of struct type `st`, returning
# from the function `f` (`egal` the function comparing objects)
function egal_array_elements!(cgm::CGModule, b::Builder, f::Func, st::TypeRef, ml::MemoryLayout,
                              ca::Int, cb::Int; egal::Func=f)
    arr = ml.array
    n, i = add_local!(f, I32), add_local!(f, I32)
    aa, ab = add_local!(f, RefType(arr, true)), add_local!(f, RefType(arr, true))
    emit!(b, :local_get, ca); emit!(b, :struct_get, st, DATA_FIELD); emit!(b, :local_set, aa)
    emit!(b, :local_get, cb); emit!(b, :struct_get, st, DATA_FIELD); emit!(b, :local_set, ab)
    emit!(b, :local_get, aa); emit!(b, :array_len); emit!(b, :local_tee, n)
    emit!(b, :local_get, ab); emit!(b, :array_len); emit!(b, :i32_ne)
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    emit!(b, :i32_const, 0); emit!(b, :local_set, i)
    block!(b); loop!(b)
    emit!(b, :local_get, i); emit!(b, :local_get, n); emit!(b, :i32_ge_u); br_if!(b, 1)
    stg = ml.storage
    get = stg isa PackedType ? :array_get_u : :array_get
    emit!(b, :local_get, aa); emit!(b, :local_get, i); emit!(b, get, arr)
    stg === F64 && emit!(b, :i64_reinterpret_f64)
    stg === F32 && emit!(b, :i32_reinterpret_f32)
    emit!(b, :local_get, ab); emit!(b, :local_get, i); emit!(b, get, arr)
    if stg === F64
        emit!(b, :i64_reinterpret_f64); emit!(b, :i64_ne)
    elseif stg === F32
        emit!(b, :i32_reinterpret_f32); emit!(b, :i32_ne)
    elseif stg === I64
        emit!(b, :i64_ne)
    elseif stg isa RefType && is_array_tuple(ml.elem.T) && ml.elem.elements !== nothing
        call!(b, tuple_egal_func!(cgm, ml.elem.T, egal)); emit!(b, :i32_eqz)
    elseif stg isa RefType
        # (references to objects, or to boxes of the elements: compared with jl_egal)
        call!(b, egal); emit!(b, :i32_eqz)
    else
        emit!(b, :i32_ne)
    end
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    emit!(b, :local_get, i); emit!(b, :i32_const, 1); emit!(b, :i32_add); emit!(b, :local_set, i)
    br!(b, 0)
    end!(b); end!(b)
    emit!(b, :i32_const, 1); return!(b)
end
