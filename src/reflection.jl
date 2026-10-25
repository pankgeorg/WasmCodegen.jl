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
    types = type_objects(cgm)
    while true
        for (f, _) in maps, T in types
            object_global!(img, f(T))
        end
        all = type_objects(cgm)
        length(all) == length(types) && break
        types = all
    end
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
        (T isa DataType && isconcretetype(T)) || continue
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
                # (fields from the header's end)
                emit_fields_egal!(cgm, b, f, st, ca, cb)
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
compiled with the module's code, see `compile_objectid_cases!`). Generated when the module's
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
    compile_objectid_cases!(cgm)

Compiles `objectid` of each type whose values may be objects, for `jl_object_id`, once the
module's code is compiled: until it adds no types.
"""
function compile_objectid_cases!(cgm::CGModule)
    haskey(cgm.helpers, :objectid_any) || return
    cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, :objectid_cases)
    ts = cgm.types
    # (compiled for every such type, whether or not its values are ever hashed: one whose
    # `objectid` cannot be compiled traps there, and is not an error of the program)
    with_optional_config(cgm) do
        while true
            n = length(cases)
            for (id, T) in enumerate(copy(ts.typelist))
                (haskey(cases, id) || !objectid_case_type(ts, T)) && continue
                cases[id] = runtime_function!(cgm, Runtime.objectid_as, (Any, Type{T}))
            end
            length(cases) == n && break
            process_worklist!(cgm)
        end
    end
end

"""
    with_optional_config(f, cgm)

`f()` emitting optional functions: with the caller's options (serialization included), but an
unsupported construct traps and is not an error of the program (its diagnostics are dropped).
"""
function with_optional_config(f, cgm::CGModule)
    config, ndiag, mode = cgm.config, length(cgm.diagnostics), cgm.image.optional_mode
    kw = Dict{Symbol,Any}(n => getfield(config, n) for n in fieldnames(Config))
    kw[:on_unsupported] = :trap
    kw[:trim] = :unsafe
    cgm.config = Config(; kw...)
    cgm.image.optional_mode = true
    try
        return f()
    finally
        cgm.image.optional_mode = mode
        cgm.config = config
        resize!(cgm.diagnostics, ndiag)
    end
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
            # objects of the runtime (types, ...) and mutable ones: by identity
            (T isa DataType && ismutabletype(T)) || continue
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

function emit_fields_egal!(cgm::CGModule, b::Builder, f::Func, st::TypeRef, ca::Int, cb::Int)
    fields = (typedef(cgm.mod, st).comp::StructType).fields
    for w in HEADER_FIELDS+1:length(fields)
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
# from the function
function egal_array_elements!(cgm::CGModule, b::Builder, f::Func, st::TypeRef, ml::MemoryLayout,
                              ca::Int, cb::Int)
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
    elseif stg isa RefType
        # (references to objects, or to boxes of the elements: compared with jl_egal)
        call!(b, f); emit!(b, :i32_eqz)
    else
        emit!(b, :i32_ne)
    end
    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
    emit!(b, :local_get, i); emit!(b, :i32_const, 1); emit!(b, :i32_add); emit!(b, :local_set, i)
    br!(b, 0)
    end!(b); end!(b)
    emit!(b, :i32_const, 1); return!(b)
end
