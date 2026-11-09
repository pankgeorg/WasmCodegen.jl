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
    map_value!(cgm, f, T)

`f(T)` of a function of types (`Runtime.map_type`), once per compilation: the tables are built
to a fixpoint of the image's objects, so a type's value is one object, though `f` may make a
new one on each call (`Runtime.type_hash`: natively, in a session of patches, any task's
`hash(::Type)` calls it, so it keeps no cache of its own).
"""
map_value!(cgm::CGModule, @nospecialize(f), @nospecialize(T)) =
    get!(() -> f(T), get!(() -> IdDict{Any,Any}(), cgm.helpers, (:map_values, f))::IdDict{Any,Any}, T)

"""
    emit_map_type!(fc, f, T) -> CGVal

`Runtime.map_type(f, T)`: the type `f(T)`, from a table of `f` over the module's types.
"""
function emit_map_type!(fc::FnCtx, @nospecialize(f), t::CGVal)
    isconstant(t) && return const_value(fc, map_value!(fc.cgm, f, constant_value(t)))
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
        elems = Inst[Inst(:global_get, object_global!(img, map_value!(cgm, f, T))) for T in types]
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
        add_apply_type_types!(cgm)
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
            object_global!(cgm.image, map_value!(cgm, f, T))
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
    add_func!(cgm.mod, helper_name(cgm, "type_isa_" * typename_str(T)), ValType[jl], ValType[I32])
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
        (T isa DataType && (isconcretetype(T) || is_vararg_tuple(T))) || continue
        # (a type the module has only as a type object, of no representation: no value of it)
        l = try
            layout(ts, T)
        catch err
            err isa Unsupported || rethrow()
            continue
        end
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
    with_optional_config(cgm) do
        while true
            n = add_reflection_types!(cgm) + add_objectid_cases!(cgm) + add_tuple_cases!(cgm) +
                add_by_type_cases!(cgm) + add_getfield_any_cases!(cgm) + add_new_cases!(cgm)
            n == 0 && break
            process_worklist!(cgm)
        end
    end
    promote_getfield_any_cases!(cgm)
    promote_new_cases!(cgm)
end

"""
    with_optional_config(f, cgm)

`f()` emitting optional functions: with the caller's options (serialization included), but an
unsupported construct traps and is not an error of the program (its diagnostics are kept apart,
for the case that a program function needs it later).
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
        # kept per function, in case a program function needs it later
        for d in cgm.diagnostics[ndiag+1:end]
            info = get(cgm.funcs, d.first, nothing)
            info === nothing || push!(get!(() -> Any[], cgm.image.suppressed, info), d)
        end
        resize!(cgm.diagnostics, ndiag)
    end
end

## `Runtime.by_type(f, x, y)`: `f(x, y, T)` of the case of `f` for the type `T` of `x`

"""
The functions `Runtime.by_type` calls by the type of a value, and the types of the module each
has a case for (of the module's concrete types): `Base.wait` of each type Base has a `wait`
for (`Runtime.Tasks.wait_as`, for `@sync`), and `showerror` of each exception type whose
`showerror` the module can compile, as juliac checks code (`Runtime.showerror_as`, for
`Host.error_text`).
"""
const BY_TYPE_CASES = IdDict{Any,Function}(
    Runtime.Tasks.wait_as => (world, @nospecialize(T)) ->
        !(T <: Task) && !(T <: Base.UnwrapTaskFailedException) && hasmethod(Base.wait, Tuple{T}; world),
    Runtime.showerror_as => (world, @nospecialize(T)) -> T <: Exception && trim_safe_showerror(T, world))

# whether `showerror(::IOBuffer, ::T)` is trim-safe in `world` (once per type and world)
const SHOWERROR_TRIM_SAFE = Dict{Tuple{Any,UInt},Bool}()
trim_safe_showerror(@nospecialize(T), world::UInt) = get!(SHOWERROR_TRIM_SAFE, (T, world)) do
    try
        mi = entry_instance(showerror, (IOBuffer, T); world)
        isempty(trim_check([mi]; world, onlywarn=true))
    catch
        false
    end
end

"""
    by_type_func!(cgm, f) -> Func

`(x::\$JlValue, y::\$JlValue) -> i32`: `f(x, y, T)` of the case of `f` for the type `T` of `x`
(`true`), else `false` (0). Generated when the module's types are known (`finish_by_type!`).
"""
function by_type_func!(cgm::CGModule, @nospecialize(f))
    fs = get!(() -> Any[], cgm.helpers, :by_type)::Vector{Any}
    any(g -> g === f, fs) || push!(fs, f)
    return get!(cgm.helpers, (:by_type, f)) do
        jl = jlvalue_ref(cgm.types)
        add_func!(cgm.mod, string("jl_by_type_", nameof(f)), ValType[jl, jl], ValType[I32])
    end::Func
end

# the cases of the functions of `by_type`: of each type of the module each is for (the number
# of cases added)
function add_by_type_cases!(cgm::CGModule)
    n = 0
    world = cgm.world.world
    for f in get(cgm.helpers, :by_type, Any[])::Vector{Any}
        cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, (:by_type_cases, f))::Dict{Int,FuncInfo}
        seen = get!(() -> Set{Int}(), cgm.helpers, (:by_type_seen, f))::Set{Int}
        applies = BY_TYPE_CASES[f]
        for (id, T) in enumerate(copy(cgm.types.typelist))
            id in seen && continue
            push!(seen, id)
            (T isa DataType && isconcretetype(T) && applies(world, T)) || continue
            cases[id] = runtime_function!(cgm, f, (Any, Any, Type{T}))
            n += 1
        end
    end
    return n
end

function finish_by_type!(cgm::CGModule)
    ts = cgm.types
    for f in get(cgm.helpers, :by_type, Any[])::Vector{Any}
        func = cgm.helpers[(:by_type, f)]::Func
        cases = get(cgm.helpers, (:by_type_cases, f), Dict{Int,FuncInfo}())::Dict{Int,FuncInfo}
        b = Builder(cgm.mod, func)
        for id in sort!(collect(keys(cases)))
            emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0)
            emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b)
            # (the case returns `true` if it returns)
            emit!(b, :local_get, 0); emit!(b, :local_get, 1); call!(b, cases[id].func)
            foreach(_ -> emit!(b, :drop), cases[id].func.results)
            emit!(b, :i32_const, 1); return!(b)
            end!(b)
        end
        emit!(b, :i32_const, 0)
        finish!(b)
    end
    return nothing
end

## `getfield` of a value whose type is not concrete

"""
    getfield_any_func!(cgm, T, f) -> Func

`(x::\$JlValue) -> \$JlValue`: `getfield(x, f)` (a constant name or index `f`) of a value `x`
of the type `T` that is not concrete, as `Any`: natively the `getfield` builtin, which finds
the field by the value's type at run time. Here the module's case for the type of `x`
(`Runtime.getfield_as`, compiled for each concrete type of the module whose objects may be
`T`s, and of a tuple whose concrete type the module does not have), chosen by its type id.
Generated when the module's types are known (`finish_getfield_any!`). The cases are the
program's code, with their unsupported constructs, once a program function needs the helper
(`promote_getfield_any_cases!`); before, those of the optional functions needing it.
"""
function getfield_any_func!(cgm::CGModule, @nospecialize(T), f::Union{Symbol,Int})
    ks = get!(() -> Any[], cgm.helpers, :getfield_any)::Vector{Any}
    any(k -> k[1] === T && k[2] === f, ks) || push!(ks, (T, f))
    note_case_owner!(cgm, (:getfield_any_owners, T, f))
    return get!(cgm.helpers, (:getfield_any, T, f)) do
        jl = jlvalue_ref(cgm.types)
        add_func!(cgm.mod, helper_name(cgm, string("getfield_any_", typename_str(T), "_", f)),
                  ValType[jl], ValType[jl])
    end::Func
end

# the cases of the functions of `getfield_any_func!`: of each concrete type of the module
# whose objects may be of its type (the number of cases added)
function add_getfield_any_cases!(cgm::CGModule)
    n = 0
    for (T, f) in get(cgm.helpers, :getfield_any, Any[])::Vector{Any}
        cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, (:getfield_any_cases, T, f))::Dict{Int,FuncInfo}
        seen = get!(() -> Set{Int}(), cgm.helpers, (:getfield_any_seen, T, f))::Set{Int}
        for (id, S) in enumerate(copy(cgm.types.typelist))
            id in seen && continue
            push!(seen, id)
            # (an object of a kind, as `DataType`, may be a `Type{X}` without the kind being one;
            # an object of `Tuple` is a tuple whose concrete type the module does not have)
            ((S isa DataType && isconcretetype(S)) || S === Tuple) && typeintersect(S, T) !== Union{} || continue
            cases[id] = runtime_function!(cgm, Runtime.getfield_as, (Any, Val{S}, Val{f}))
            n += 1
        end
    end
    return n
end

# Runtime cases a program function needs are the program's code: their unsupported constructs
# are its errors. The functions needing a helper of cases, by `key` (`:program` for a program
# function, else the optional function, the one being emitted).
function note_case_owner!(cgm::CGModule, key)
    img = cgm.image
    owners = get!(() -> Any[], cgm.helpers, key)::Vector{Any}
    owner = img.optional_mode || img.owner in img.optional ? img.owner : :program
    any(o -> o === owner, owners) || push!(owners, owner)
    return owners
end

# the cases `cases` of a helper the functions `owners` need: the program's code if a program
# function needs it; else promoted with each optional function needing it (`promote_optional!`).
# After the cases are emitted (all functions emitted in optional mode are optional).
function promote_cases!(cgm::CGModule, owners::Vector{Any}, cases)
    img = cgm.image
    for owner in owners, c in cases
        if owner === :program || !(owner in img.optional)
            promote_optional!(cgm, c)
        else
            cs = get!(() -> Any[], img.optional_children, owner)
            any(x -> x === c, cs) || push!(cs, c)
        end
    end
end

# the cases of the `getfield` helpers (`promote_cases!`); but of a value of type `Any`, those of
# the runtime's own objects (types, modules, methods: no field of theirs is read in a module)
# stay optional: one reaching them traps, as `objectid` of a type it cannot be compiled for
function promote_getfield_any_cases!(cgm::CGModule)
    for (T, f) in get(cgm.helpers, :getfield_any, Any[])::Vector{Any}
        cases = get(cgm.helpers, (:getfield_any_cases, T, f), Dict{Int,FuncInfo}())::Dict{Int,FuncInfo}
        promote_cases!(cgm, cgm.helpers[(:getfield_any_owners, T, f)]::Vector{Any},
                       FuncInfo[c for (id, c) in cases
                                if !(T === Any && any(R -> cgm.types.typelist[id] === R, RUNTIME_TYPES))])
    end
end

function finish_getfield_any!(cgm::CGModule)
    ts = cgm.types
    for (T, f) in get(cgm.helpers, :getfield_any, Any[])::Vector{Any}
        func = cgm.helpers[(:getfield_any, T, f)]::Func
        cases = get(cgm.helpers, (:getfield_any_cases, T, f), Dict{Int,FuncInfo}())::Dict{Int,FuncInfo}
        b = Builder(cgm.mod, func)
        tid = add_local!(func, I32)
        emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
        for id in sort!(collect(keys(cases)))
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b)
            emit!(b, :local_get, 0); call!(b, cases[id].func)
            # (a case that always throws returns nothing)
            isempty(cases[id].func.results) ? unreachable!(b) : return!(b)
            end!(b)
        end
        # (no other object is a `T`)
        unreachable!(b)
        finish!(b)
    end
    return nothing
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
        elseif is_vararg_tuple(FT) && lf.elements !== nothing
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
    h = add_func!(cgm.mod, helper_name(cgm, "tuple_egal_" * typename_str(S)), ValType[r, r], ValType[I32])
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
    add_func!(cgm.mod, helper_name(cgm, "tuple_canon_" * typename_str(S)), ValType[l.leaves[1].type],
              ValType[jlvalue_ref(cgm.types)])
end

"`jl_tuple_from(x::\$JlValue) -> S`: the tuple object `x` as a value of the tuple type of unknown length `S`."
tuple_from_func!(cgm::CGModule, @nospecialize(S)) = get!(cgm.helpers, (:tuple_from, S)) do
    l = layout(cgm.types, S)
    add_func!(cgm.mod, helper_name(cgm, "tuple_from_" * typename_str(S)), ValType[jlvalue_ref(cgm.types)],
              ValType[l.leaves[1].type])
end

# the concrete tuple types of the module a value of the tuple type of unknown length `S` may
# have: natively `Tuple{typeof(x)...}` of its elements, which may not be a subtype of `S` (of
# an element `Int` of an `S` of `Type{<:Integer}`s, `Tuple{DataType}`)
function tuple_case_types(ts::Types, @nospecialize(S))
    return [(id, C) for (id, C) in enumerate(ts.typelist)
            if C isa DataType && C <: Tuple && isconcretetype(C) && C !== S && typeintersect(C, S) !== Union{}]
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
    elseif stg isa RefType && is_vararg_tuple(ml.elem.T) && ml.elem.elements !== nothing
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

## `Core.apply_type` and `new` of types known only at run time
#
# Natively both are calls of the builtins at run time (`jl_f_apply_type`, `jl_new_structv`).
# Types are not made at run time here: they are looked up among the module's types, by
# functions generated when those are known, as `jl_typeof` and `jl_subtype` are.

"The number of type variables of the type `W` (a `UnionAll`'s, nested)."
type_var_count(@nospecialize(W)) = W isa UnionAll ? 1 + type_var_count(W.body) : 0

"""
    apply_type_params(W, T, n) -> Union{Vector{Any},Nothing}

The `n` parameters `P` with `Core.apply_type(W, P...) === T`, or `nothing` if `T` is not
such a type (computed natively, for the module's types). `T` of parameters it leaves unbound
(a parameter the substitution of the earlier ones drops, as `NTuple{0,T}` is `Tuple{}` for
any `T`) is not an instantiation found by its parameters: such an application is the closed
world's error, never another type.
"""
function apply_type_params(@nospecialize(W), @nospecialize(T), n::Int)
    (T isa DataType && !Base.has_free_typevars(T)) || return nothing
    if W === Tuple
        (T <: Tuple && !Base.isvatuple(T) && length(T.parameters) == n) || return nothing
        P = collect(Any, T.parameters)
        any(p -> p isa TypeVar, P) && return nothing
    else
        U = Base.unwrap_unionall(W)
        (U isa DataType && U.name === T.name && T <: W) || return nothing
        env = ccall(:jl_type_intersection_with_env, Any, (Any, Any), T, W)[2]::Core.SimpleVector
        length(env) == n || return nothing
        P = collect(Any, env)
    end
    any(p -> p isa TypeVar || p isa Core.TypeofVararg, P) && return nothing
    R = try
        Core.apply_type(W, P...)
    catch
        nothing
    end
    return R === T ? P : nothing
end

"""
    apply_type_shape(W, n) -> Int

The number of type variables of `W` that `Core.apply_type(W, p1, …, pn)` of parameters known
only at run time binds (`n` for `Tuple`; more parameters than that are native's "too many
parameters" error, `apply_type_check`). Supported, as the module's types can then be looked up
by their parameters (an application of them is injective: one result per parameters, the
parameters of a result recovered from it, none erased): `Tuple`, and a `UnionAll` each of whose
type variables is a parameter of the type it makes and appears nowhere else in it (`Vector`,
`Dict`, `Val`, a closure's type). Otherwise an `Unsupported` error, so that a type the module
has is never reported as missing: an alias whose application may drop or normalize parameters
away (`NTuple{0,T}` is `Tuple{}` for every `T`), `Type`, and a partial application (fewer
parameters: a `UnionAll` made at run time).
"""
function apply_type_shape(@nospecialize(W), n::Int)
    W === Tuple && return n
    U = Base.unwrap_unionall(W)
    (W isa UnionAll && U isa DataType) ||
        unsupported("apply_type of types not known at compile time (", W, " of ", n, " parameters)")
    U.name === Tuple.name &&
        unsupported("apply_type of the tuple type alias ", W, " of parameters not known at compile time ",
                    "(its application may normalize parameters away: `NTuple{0,T}` is `Tuple{}` for every `T`)")
    U.name === Type.body.name &&
        unsupported("apply_type of `Type` of a parameter not known at compile time")
    vars = TypeVar[]
    V = W
    while V isa UnionAll
        push!(vars, V.var); V = V.body
    end
    # (each variable a parameter of the type made, and only there: an application then
    # instantiates no other type, whose bound errors natively come first, and erases none)
    all(v -> count(p -> p === v, U.parameters) == 1 &&
             !any(p -> p !== v && Base.has_typevar(p, v), U.parameters), vars) ||
        unsupported("apply_type of the alias ", W, " of parameters not known at compile time ",
                    "(its type variables are not each just a parameter of the type it makes)")
    n < length(vars) &&
        unsupported("apply_type of types not known at compile time (", W, " of ", n,
                    " parameters: a partial application)")
    return length(vars)
end

"""
    emit_apply_type!(fc, args, typ) -> CGVal

`Core.apply_type(W, ps...)` of parameters not known at compile time: a call of
`jl_apply_type_<W>`, the instantiations of `W` the module has (generated by
`finish_apply_type!`, the closed world's cache of `W`'s instantiations, `tn->cache`), else
native's error of an invalid application (`Runtime.apply_type_check`), else the closed-world
limit. `W` must be known and of a shape `apply_type_shape` supports.
"""
function emit_apply_type!(fc::FnCtx, args::Vector{Any}, @nospecialize(typ))
    all(a -> a isa CGVal, args) && isconstant(args[1]) ||
        unsupported("apply_type of types not known at compile time")
    W = constant_value(args[1])
    n = length(args) - 1
    n <= Runtime.MAX_APPLY_PARAMS ||
        unsupported("apply_type of types not known at compile time, of ", n, " parameters")
    k = apply_type_shape(W, n)
    # (a `Vararg` parameter of a tuple type changes its number of parameters: not supported;
    # one inference cannot rule out is an error at run time that says so, `apply_type_check`)
    if W === Tuple && any(a -> a.typ !== Union{} && a.typ <: Core.TypeofVararg, args[2:end])
        unsupported("apply_type(Tuple, …) of a Vararg parameter (not supported: it changes the number of parameters)")
    end
    cgm = fc.cgm
    h = get!(cgm.helpers, (:apply_type, W, n)) do
        jl = jlvalue_ref(cgm.types)
        f = add_func!(cgm.mod, helper_name(cgm, "apply_type_" * typename_str(W)),
                      ValType[jl for _ in 1:n], ValType[jl])
        # (`W` printed as far as a diagnostic is: a wrapper of fixed parameters can be large)
        msg = string("WasmCodegen: closed-world limit: Core.apply_type(", limited_sprint(print, W), ", …) of these parameters ",
                     "is a valid type that was not compiled into this module (types are not made at run ",
                     "time: the module has the types its code names)")
        # (the native errors of parameters that may not be ones, or outside the bounds)
        argtypes = (Val{W}, ntuple(_ -> Any, n)...)
        (; func=f, k, msg=object_global!(cgm.image, msg),
           throw=runtime_function!(cgm, Runtime.throw_apply_type_unknown, (String,)),
           check=runtime_function!(cgm, Runtime.apply_type_check, argtypes),
           cands=IdDict{Any,Vector{Any}}())
    end
    # (the types inference says it gives are the module's, as types code names are)
    for S in (typ isa Union ? Base.uniontypes(typ) : Any[typ])
        S isa DataType && S.name === Type.body.name || continue
        X = S.parameters[1]
        X isa DataType && !Base.has_free_typevars(X) && object_global!(cgm.image, X)
    end
    for a in args[2:end]
        push_val!(fc, convert_repr(fc, a, Any))
    end
    call!(fc.b, h.func)
    return convert_repr(fc, pop_val!(fc, Any), typ)
end

# the instantiations of each `W` of `jl_apply_type_<W>` among the module's types, with the
# objects of them and of their parameters (the number of objects added)
function add_apply_type_types!(cgm::CGModule)
    img, ts = cgm.image, cgm.types
    m0 = length(img.globals) + length(img.boxes)
    for (k, h) in collect(cgm.helpers)
        (k isa Tuple && length(k) == 3 && k[1] === :apply_type) || continue
        W, n = k[2], k[3]
        n == h.k || continue   # (too many parameters: no type, native's error)
        for T in copy(ts.typelist)
            haskey(h.cands, T) && continue
            P = apply_type_params(W, T, n)
            P === nothing && continue
            try
                object_global!(img, T)
                for p in P
                    boxed_object_global!(img, p)
                    p isa Type || egal_any_func!(cgm)
                end
            catch err
                err isa Unsupported || rethrow()
                continue
            end
            h.cands[T] = P
        end
    end
    return length(img.globals) + length(img.boxes) - m0
end

"""
    type_param_class(types, p) -> Vector{Any}

The module's type objects (of `types`; `abstract`, those not concrete) equal to the type `p`
(`jl_types_equal`), `p` first:
those the type cache may take for it as a parameter (`typekey_eq`, after `normalize_unionalls`
and `extract_wrapper`: `Tuple{S,S} where S` for `Tuple{T,T} where T`, `Tuple{Vararg{Int,N}}
where N` for `Tuple{Vararg{Int}}`, `Vector{T} where Int<:T<:Int` for `Vector{Int}`). Which of
them a row takes is decided natively, by applying `W` to them (`same_application`).
"""
function type_param_class(types::Vector{Any}, abstract::Vector{Any}, @nospecialize(p))
    class = Any[p]
    # (two concrete types are equal only if they are one: of a concrete `p`, the others only)
    for Q in (p isa DataType && isconcretetype(p) ? abstract : types)
        Q !== p && p == Q && push!(class, Q)
    end
    return class
end

# whether `Core.apply_type(W, P...)` with `Q` for the parameter `i` is `T` natively
function same_application(@nospecialize(W), P::Vector{Any}, i::Int, @nospecialize(Q), @nospecialize(T))
    Q === P[i] && return true
    R = try
        Core.apply_type(W, Any[j == i ? Q : P[j] for j in eachindex(P)]...)
    catch
        nothing
    end
    return R === T
end

function finish_apply_type!(cgm::CGModule)
    img, ts = cgm.image, cgm.types
    types = abstract = nothing
    classes = IdDict{Any,Vector{Any}}()
    for (k, h) in cgm.helpers
        (k isa Tuple && length(k) == 3 && k[1] === :apply_type) || continue
        W, n = k[2], k[3]
        b = Builder(cgm.mod, h.func)
        call_check(c::FuncInfo) = (for i in 1:n; emit!(b, :local_get, i - 1); end;
                                   call!(b, c.func); foreach(_ -> emit!(b, :drop), c.func.results))
        for T in sort!(collect(keys(h.cands)); by=T -> typeid!(ts, T))
            P = h.cands[T]
            for (i, p) in enumerate(P)
                if p isa Type
                    # (type objects are interned: by reference, to each of the module's type
                    # objects that natively gives this type in place of `p`, as the type cache
                    # takes types equal to it, `typekey_eq`; the rows stay disjoint, as each
                    # object gives one type)
                    if types === nothing
                        types = type_objects(cgm)
                        abstract = Any[Q for Q in types if !(Q isa DataType && isconcretetype(Q))]
                    end
                    class = get!(() -> type_param_class(types, abstract, p), classes, p)
                    class = Any[Q for Q in class if same_application(W, P, i, Q, T)]
                    for (j, Q) in enumerate(class)
                        emit!(b, :local_get, i - 1)
                        emit!(b, :global_get, object_global!(img, Q))
                        emit!(b, :ref_eq)
                        j > 1 && emit!(b, :i32_or)
                    end
                else
                    # (other values with `jl_egal`)
                    emit!(b, :local_get, i - 1)
                    emit!(b, :global_get, boxed_object_global!(img, p))
                    call!(b, egal_any_func!(cgm))
                end
                i > 1 && emit!(b, :i32_and)
            end
            n == 0 && emit!(b, :i32_const, 1)
            if!(b); emit!(b, :global_get, object_global!(img, T)); return!(b); end!(b)
        end
        # (not one of the module's: natively a TypeError if not a valid application)
        call_check(h.check)
        emit!(b, :global_get, h.msg)
        call!(b, h.throw.func)
        unreachable!(b)
        finish!(b)
    end
end

"""
    emit_new_rt!(fc, T, args, typ) -> CGVal

`new(T, args...)` of a type `T` known only at run time (`jl_new_structv` natively): a call of
`jl_new_<n>`, one per number of fields for the module, which goes by the type id of `T` to the
case of `new` for that type (`Runtime.new_as`). Its cases are the module's concrete types that
some site's `T` may be by inference (`add_new_cases!`); the members inference names are the
module's, and the cases of a site a program function has are the program's code
(`promote_new_cases!`). Of a `T` that inference bounds
only by `DataType` or `Type` (or wider), not supported: that would be every concrete type of the
module.
"""
function emit_new_rt!(fc::FnCtx, T::CGVal, args::Vector{CGVal}, @nospecialize(typ))
    Tinf = CC.widenconst(T.typ)
    members = Tinf isa Union ? Base.uniontypes(Tinf) : Any[Tinf]
    # (`Type{<:X}`, `Type{X}`; of `Type`, every type, not supported, as of `DataType`)
    is_type_bound(S) = (U = Base.unwrap_unionall(S); U isa DataType && U.name === Type.body.name &&
                        !(Type <: S))
    all(is_type_bound, members) ||
        unsupported("`new` of a type that is not known at compile time (of type ", Tinf, ")")
    n = length(args)
    n <= Runtime.MAX_NEW_FIELDS ||
        unsupported("`new` of a type not known at compile time, of ", n, " fields")
    cgm = fc.cgm
    ts = cgm.types
    bounds = get!(() -> Any[], cgm.helpers, (:new_rt_bounds, n))::Vector{Any}
    any(B -> B === Tinf, bounds) || push!(bounds, Tinf)
    note_case_owner!(cgm, (:new_rt_owners, Tinf, n))
    cases = get!(() -> Dict{Int,FuncInfo}(), cgm.helpers, (:new_rt_cases, n))::Dict{Int,FuncInfo}
    # (the types inference says it may be: the module's, their cases the program's code)
    for S in members
        X = S isa DataType ? S.parameters[1] : nothing
        if X isa DataType && new_case_type(ts, X, Tinf, n)
            id = typeid!(ts, X)
            haskey(cases, id) || (cases[id] = runtime_function!(cgm, Runtime.new_as, (Type{X}, ntuple(_ -> Any, n)...)))
        end
    end
    get!(() -> runtime_function!(cgm, Runtime.throw_new_not_concrete, (Any,)), cgm.helpers, :new_not_concrete)
    get!(() -> runtime_function!(cgm, Runtime.throw_invalid_struct_allocation, ()), cgm.helpers, :new_bad_arity)
    get!(() -> runtime_function!(cgm, Runtime.throw_new_closed_world, ()), cgm.helpers, :new_closed_world)
    f = get!(cgm.helpers, (:new_rt, n)) do
        jl = jlvalue_ref(ts)
        add_func!(cgm.mod, "jl_new_" * string(n), ValType[jl for _ in 0:n], ValType[jl])
    end
    push_val!(fc, convert_repr(fc, T, Any))
    for a in args
        v = convert_repr(fc, a, Any)
        v.kind === Bottom && return v
        push_val!(fc, v)
    end
    call!(fc.b, f)
    return convert_repr(fc, pop_val!(fc, Any), typ)
end

# whether `C` is a concrete type `new` of a type known only at run time, of inferred type
# `Tinf`, may build with `n` fields (`nothing`: of that type, but not with `n` fields, natively
# "invalid struct allocation")
function new_case_kind(ts::Types, @nospecialize(C), @nospecialize(Tinf), n::Int)
    (C isa DataType && isconcretetype(C) && C isa Tinf) || return false
    (is_memory_type(C) || C === String || C === Symbol || C === Core.SimpleVector || C === Module) && return false
    any(R -> C === R, RUNTIME_TYPES) && return false
    fieldcount(C) - C.name.n_uninitialized <= n <= fieldcount(C) || return nothing
    return true
end
new_case_type(ts::Types, @nospecialize(C), @nospecialize(Tinf), n::Int) = new_case_kind(ts, C, Tinf, n) === true

# the cases of the `new` helpers: of each type of the module some site's type may be, by
# inference (the number added)
function add_new_cases!(cgm::CGModule)
    ts = cgm.types
    added = 0
    for k in collect(keys(cgm.helpers))
        (k isa Tuple && length(k) == 2 && k[1] === :new_rt) || continue
        n = k[2]
        cases = cgm.helpers[(:new_rt_cases, n)]::Dict{Int,FuncInfo}
        bad = get!(() -> Set{Int}(), cgm.helpers, (:new_rt_bad, n))::Set{Int}
        for Tinf in cgm.helpers[(:new_rt_bounds, n)]::Vector{Any}
            seen = get!(() -> Set{Int}(), cgm.helpers, (:new_rt_seen, Tinf, n))::Set{Int}
            for (id, C) in enumerate(copy(ts.typelist))
                id in seen && continue
                push!(seen, id)
                kind = new_case_kind(ts, C, Tinf, n)
                kind === nothing && push!(bad, id)
                (kind === true && !haskey(cases, id)) || continue
                cases[id] = runtime_function!(cgm, Runtime.new_as, (Type{C}, ntuple(_ -> Any, n)...))
                added += 1
            end
        end
    end
    return added
end

# the cases of the `new` helpers, of the types each site's `T` may be (`promote_cases!`)
function promote_new_cases!(cgm::CGModule)
    ts = cgm.types
    for k in collect(keys(cgm.helpers))
        (k isa Tuple && length(k) == 2 && k[1] === :new_rt) || continue
        n = k[2]
        cases = cgm.helpers[(:new_rt_cases, n)]::Dict{Int,FuncInfo}
        for Tinf in cgm.helpers[(:new_rt_bounds, n)]::Vector{Any}
            promote_cases!(cgm, cgm.helpers[(:new_rt_owners, Tinf, n)]::Vector{Any},
                           FuncInfo[c for (id, c) in cases if ts.typelist[id] isa Tinf])
        end
    end
end

function finish_new!(cgm::CGModule)
    ts = cgm.types
    st = type_object_type!(ts)
    for (k, f) in cgm.helpers
        (k isa Tuple && length(k) == 2 && k[1] === :new_rt) || continue
        n = k[2]
        cases = cgm.helpers[(:new_rt_cases, n)]::Dict{Int,FuncInfo}
        bad = get(cgm.helpers, (:new_rt_bad, n), Set{Int}())::Set{Int}
        b = Builder(cgm.mod, f)
        tid = add_local!(f, I32)
        # (the id of the type a type object is: its third field; 0 for another object)
        emit!(b, :local_get, 0); emit!(b, :ref_test, st)
        if!(b)
        emit!(b, :local_get, 0); emit!(b, :ref_cast, st); emit!(b, :struct_get, st, 2); emit!(b, :local_set, tid)
        end!(b)
        for id in sort!(collect(keys(cases)))
            info = cases[id]
            length(info.func.params) == n && length(info.func.results) <= 1 ||
                error("WasmCodegen: the case of `new` of ", ts.typelist[id], " has an unexpected signature")
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b)
            for i in 1:n
                emit!(b, :local_get, i)
            end
            call!(b, info.func)
            # (a case that always throws, as of a field of type `Union{}`, returns nothing)
            isempty(info.func.results) ? unreachable!(b) : return!(b)
            end!(b)
        end
        # (a concrete type of the wrong number of fields)
        for id in sort!(collect(setdiff(bad, keys(cases))))
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b); call!(b, (cgm.helpers[:new_bad_arity]::FuncInfo).func); unreachable!(b); end!(b)
        end
        # (a concrete type a site's type may be with no case: one the module had not when the
        # cases were compiled, or one `new` is not supported for: the closed-world limit, not
        # the native error of a type that is not concrete)
        bounds = cgm.helpers[(:new_rt_bounds, n)]::Vector{Any}
        for (id, C) in enumerate(ts.typelist)
            (C isa DataType && isconcretetype(C) && !haskey(cases, id) && !(id in bad) &&
             any(B -> C isa B, bounds)) || continue
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b); call!(b, (cgm.helpers[:new_closed_world]::FuncInfo).func); unreachable!(b); end!(b)
        end
        emit!(b, :local_get, 0)
        call!(b, (cgm.helpers[:new_not_concrete]::FuncInfo).func)
        unreachable!(b)
        finish!(b)
    end
end

"""
The most rows a helper of `apply_type` or `new` at run time has (instantiations of one wrapper
and number of parameters; cases of one number of fields) before the module warns of it.
"""
const RT_TYPES_WARN = 512

"""
    rt_types_growth(cgm) -> Vector{Tuple{String,Int}}

The sizes of the helpers of `apply_type` and `new` at run time: each one's rows (the code of
the lookup is linear in them, and in the parameters of each), by wrapper and number of
parameters, and by number of fields. Reported with `progress`, and in a warning above
`RT_TYPES_WARN`.
"""
function rt_types_growth(cgm::CGModule)
    out = Tuple{String,Int}[]
    for (k, h) in cgm.helpers
        k isa Tuple || continue
        if length(k) == 3 && k[1] === :apply_type
            push!(out, (string("apply_type(", k[2], ", ", k[3], " parameters)"), length(h.cands)))
        elseif length(k) == 2 && k[1] === :new_rt_cases
            push!(out, (string("new of ", k[2], " fields"), length(h)))
        end
    end
    return sort!(out; by=last, rev=true)
end

function report_rt_types_growth(cgm::CGModule, t::UInt64)
    g = rt_types_growth(cgm)
    isempty(g) && return
    progress(cgm.config, "types at run time", t, join((string(w, ": ", n) for (w, n) in g), ", "))
    big = filter(x -> last(x) > RT_TYPES_WARN, g)
    isempty(big) ||
        @warn string("WasmCodegen: large helpers of apply_type/new of types known only at run time ",
                     "(more than ", RT_TYPES_WARN, " rows; the lookup is linear in them): ",
                     join((string(w, ": ", n) for (w, n) in big), ", "))
    return
end
