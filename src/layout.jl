# How Julia values are represented: the kind of representation of a type, its leaves (the
# Wasm values of an inline value), and the Wasm types of objects.

"""
    Kind

The representation of the values of a type:

- `Ghost`: no run-time representation (singletons, zero-size types, unique `Type{T}`);
- `Inline`: a flat list of Wasm values, the *leaves* (primitives, immutable structs,
  tuples and closures, whose leaves are their fields' leaves);
- `Boxed`: a reference to an object (mutable types, abstract types, unions, `Memory`,
  `String`, large immutable values);
- `Bottom`: no value (`Union{}`).
"""
@enum Kind Ghost Inline Boxed Bottom

"""
    Leaf(type, storage)

A Wasm value of an inline value: its type on the operand stack, and how it is stored in
a field or an array (packed `i8`/`i16` for small integers).
"""
struct Leaf
    type::ValType
    storage::StorageType
end
Leaf(t::ValType) = Leaf(t, t)

"""
    Layout

The representation of a Julia type `T`: its kind, its leaves (one reference for a boxed
type), and for structs the leaves (inline) or the Wasm fields (mutable structs) of each
field. `wtype` is the Wasm type of the objects of a boxed type (a struct or an array).
"""
mutable struct Layout
    T::Any
    kind::Kind
    leaves::Vector{Leaf}
    fields::Vector{UnitRange{Int}}
    wtype::Union{Nothing,TypeRef}
    "For a large homogeneous tuple (an object holding an array): how its elements are stored."
    elements::Any
end
Layout(T, kind, leaves, fields, wtype) = Layout(T, kind, leaves, fields, wtype, nothing)

"The maximum number of leaves of an inline type; larger immutable types are boxed."
const MAX_INLINE_LEAVES = 64

"The number of Wasm fields of the header of every object: the type id and the hash."
const HEADER_FIELDS = 2

"""
    Types

The Wasm types of a module for Julia types: layouts, the object header type `\$JlValue`,
array types by element storage, boxes, type ids.
"""
mutable struct Types
    mod::WModule
    layouts::IdDict{Any,Layout}
    jlvalue::TypeRef
    arrays::Dict{StorageType,TypeRef}
    boxes::IdDict{Any,TypeRef}
    typeids::IdDict{Any,Int32}
    "The types by type id (1-based)."
    typelist::Vector{Any}
    "The layouts being computed (to detect types containing themselves)."
    inprogress::IdSet{Any}
end

function Types(m::WModule)
    jlvalue = add_type!(m, StructType([FieldType(I32, false), FieldType(I32, true)]);
                        final=false)
    return Types(m, IdDict{Any,Layout}(), jlvalue, Dict{StorageType,TypeRef}(),
                 IdDict{Any,TypeRef}(), IdDict{Any,Int32}(), Any[], IdSet{Any}())
end

"The reference type of `\$JlValue` objects (any boxed Julia value)."
jlvalue_ref(ts::Types) = RefType(ts.jlvalue, true)

"""
    typeid!(ts, T) -> Int32

The type id of the concrete type `T` (assigned on first use, from 1).
"""
function typeid!(ts::Types, @nospecialize(T))
    get!(ts.typeids, T) do
        push!(ts.typelist, T)
        Int32(length(ts.typelist))
    end
end

## ghosts and kinds

"""
    unique_type_parameter(T) -> Union{Some,Nothing}

The `X` of a `Type{X}` that only `X` is an instance of, or `nothing` (as JuliaCodegen).
"""
function unique_type_parameter(@nospecialize T)
    (T isa DataType && T.name === Type.body.name) || return nothing
    X = T.parameters[1]
    has_unique_rep(X) || return nothing
    return Some(X)
end

function has_unique_rep(@nospecialize X)
    X === typeof(Union{}) && return false
    X === Union{} && return true
    X isa TypeVar && return false
    X isa Type || return true
    isconcretetype(X) && return true
    if X isa DataType && X.name !== Tuple.name
        return all(has_unique_rep, X.parameters)
    end
    return false
end

"""
    ghost_value(T) -> Union{Some,Nothing}

The only value of type `T` if it is a singleton type, else `nothing`.
"""
function ghost_value(@nospecialize T)
    X = unique_type_parameter(T)
    X === nothing || return X
    T isa DataType || return nothing
    !ismutabletype(T) && isdefined(T, :instance) && return Some(T.instance)
    return nothing
end

"""
    tuple_array_layout(ts, T, E) -> Layout

The layout of tuples of type `T` as objects holding an array of their elements (stored
as those of a `Memory{E}`): large tuples of one element type, and tuples whose length is
not known at compile time (`Tuple{Vararg{E}}`).
"""
function tuple_array_layout(ts::Types, @nospecialize(T), @nospecialize(E))
    ml = memory_layout(ts, E)
    wtype = get!(ts.boxes, (:tuplearray, ml.array)) do
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(RefType(ml.array, true), false)]);
                  final=true, super=ts.jlvalue)
    end
    l = boxed_layout(ts, T, wtype)
    l.elements = ml
    return l
end

"Whether `T` is a tuple type whose length is not known (`Tuple{A, Vararg{B}}`)."
is_vararg_tuple(@nospecialize T) = T isa DataType && T.name === Tuple.name && Base.isvatuple(T)

"The type of the elements of a vararg tuple type: their join."
function vararg_eltype(@nospecialize T)
    E = Union{}
    for P in T.parameters
        P isa Core.TypeofVararg && (P = isdefined(P, :T) ? P.T : Any)
        E = typejoin(E, P)
    end
    return E
end

is_homogeneous_tuple(@nospecialize T) = T isa DataType && T <: Tuple && isconcretetype(T) &&
    fieldcount(T) > 0 && all(i -> fieldtype(T, i) === fieldtype(T, 1), 1:fieldcount(T))

function is_inline_tuple(@nospecialize T)
    (T isa DataType && T.name === Tuple.name && !isconcretetype(T) && !Base.isvatuple(T)) ||
        return false
    is_union_tuple(T) && return true
    return all(P -> (P isa DataType && isconcretetype(P)) || unique_type_parameter(P) !== nothing ||
                    is_inline_tuple(P), T.parameters)
end

"The most concrete tuple types an inline tuple with union elements may have."
const MAX_TUPLE_COMBINATIONS = 16

"""
    is_union_tuple(T) -> Bool

Whether `T` is a tuple type of known length with an element of a small union of concrete
types (`Tuple{Bool, Union{Nothing, Int}}`): inline like a concrete tuple (the union element
boxed), and of one of a few concrete tuple types (`tuple_combinations`) when boxed.
"""
function is_union_tuple(@nospecialize T)
    (T isa DataType && T.name === Tuple.name && !isconcretetype(T) && !Base.isvatuple(T)) || return false
    for P in T.parameters
        if P isa Union
            all(U -> U isa DataType && isconcretetype(U), Base.uniontypes(P)) || return false
        else
            ((P isa DataType && isconcretetype(P)) || is_union_tuple(P)) || return false
        end
    end
    return length(tuple_combinations(T)) <= MAX_TUPLE_COMBINATIONS
end

# the types an element of declared type `P` of a union tuple may have
element_variants(@nospecialize P) =
    P isa Union ? Base.uniontypes(P) : isconcretetype(P) ? Any[P] : tuple_combinations(P)

"The concrete tuple types a value of the union tuple type `T` may have."
tuple_combinations(@nospecialize T) =
    Any[Tuple{c...} for c in Iterators.product((element_variants(P) for P in T.parameters)...)]

is_memory_type(@nospecialize T) = T isa DataType && T.name === GenericMemory.body.body.body.name
is_memoryref_type(@nospecialize T) =
    T isa DataType && T.name === GenericMemoryRef.body.body.body.name
memory_eltype(@nospecialize T) = T.parameters[2]

# the runtime's own objects, which have no Julia-level layout to follow
const RUNTIME_TYPES = Any[DataType, UnionAll, Union, Core.TypeofBottom, TypeVar,
                          Core.SimpleVector, Module, Method, Core.MethodInstance,
                          Core.CodeInstance, Core.TypeName]

function primitive_leaves(@nospecialize T)
    T === Float64 && return [Leaf(F64)]
    T === Float32 && return [Leaf(F32)]
    sz = sizeof(T)
    sz == 1 && return [Leaf(I32, I8)]
    sz == 2 && return [Leaf(I32, I16)]
    sz == 4 && return [Leaf(I32)]
    sz == 8 && return [Leaf(I64)]
    sz == 16 && return [Leaf(I64), Leaf(I64)]
    unsupported("the primitive type ", T, " of ", sz, " bytes")
end

"""
    layout(ts, T) -> Layout

The representation of values of type `T`.
"""
function layout(ts::Types, @nospecialize(T))
    l = get(ts.layouts, T, nothing)
    l === nothing || return l
    T in ts.inprogress && unsupported("the type ", T, ", which contains itself inline")
    push!(ts.inprogress, T)
    try
        l = compute_layout(ts, T)
    finally
        delete!(ts.inprogress, T)
    end
    ts.layouts[T] = l
    return l
end

function boxed_layout(ts::Types, @nospecialize(T), wtype::TypeRef)
    return Layout(T, Boxed, [Leaf(RefType(wtype, true))], UnitRange{Int}[], wtype)
end

function compute_layout(ts::Types, @nospecialize(T))
    T === Union{} && return Layout(T, Bottom, Leaf[], UnitRange{Int}[], nothing)
    ghost_value(T) === nothing ||
        return Layout(T, Ghost, Leaf[], UnitRange{Int}[], nothing)
    # a tuple with singleton `Type{X}` elements (varargs packed by the IR) is not a
    # concrete type, but its values are inline all the same
    is_inline_tuple(T) && return immutable_layout(ts, T)
    is_vararg_tuple(T) && return tuple_array_layout(ts, T, vararg_eltype(T))
    (T === Core.TypeName || T === Module) && return boxed_layout(ts, T, named_object_type!(ts))
    # a SimpleVector (a type's parameters): its elements in an array, as a large tuple's
    T === Core.SimpleVector && return tuple_array_layout(ts, T, Any)
    if !(T isa DataType) || !isconcretetype(T) || any(R -> T === R, RUNTIME_TYPES)
        # abstract types, unions, type objects: any object
        return Layout(T, Boxed, [Leaf(jlvalue_ref(ts))], UnitRange{Int}[], ts.jlvalue)
    end
    if is_ptr_type(T)
        # the address and the object it points into (see pointers.jl)
        return Layout(T, Inline, [Leaf(I64), Leaf(jlvalue_ref(ts))], UnitRange{Int}[], nothing)
    elseif isprimitivetype(T)
        return Layout(T, Inline, primitive_leaves(T), UnitRange{Int}[], nothing)
    elseif is_memory_type(T)
        return boxed_layout(ts, T, memory_struct_type!(ts, memory_eltype(T)))
    elseif T === String || T === Symbol
        return boxed_layout(ts, T, bytes_object_type!(ts, T))
    elseif is_memoryref_type(T)
        # the Memory object, its array, and the index of the element (0-based)
        mem = memory_struct_type!(ts, memory_eltype(T))
        arr = memory_array_type!(ts, memory_eltype(T))
        return Layout(T, Inline, [Leaf(RefType(mem, true)), Leaf(RefType(arr, true)), Leaf(I32)],
                      UnitRange{Int}[], nothing)
    elseif ismutabletype(T)
        return mutable_struct_layout(ts, T)
    elseif !Base.allocatedinline(T)
        # an immutable type Julia does not store inline: one that contains itself
        # (`Base.ImmutableDict`), an immutable object
        return struct_object_layout(ts, T, false)
    else
        return immutable_layout(ts, T)
    end
end

"""
    field_leaves(ts, FT) -> Vector{Leaf}

The leaves a field of declared type `FT` occupies in its parent: those of an inline type,
one reference for a boxed one (unions included: Julia stores some inline, they are boxed
here), none for a ghost.
"""
function field_leaves(ts::Types, @nospecialize(FT))
    l = layout(ts, FT)
    l.kind === Ghost && return Leaf[]
    l.kind === Bottom && return Leaf[]
    return l.leaves
end

function struct_field_ranges(ts::Types, @nospecialize(T), offset::Int)
    leaves = Leaf[]
    ranges = UnitRange{Int}[]
    for i in 1:fieldcount(T)
        fl = field_leaves(ts, fieldtype(T, i))
        start = length(leaves) + 1
        append!(leaves, fl)
        push!(ranges, (start:length(leaves)) .+ offset)
    end
    return leaves, ranges
end

function immutable_layout(ts::Types, @nospecialize(T))
    leaves, ranges = struct_field_ranges(ts, T, 0)
    if length(leaves) > MAX_INLINE_LEAVES && is_homogeneous_tuple(T)
        # a large tuple of one element type: an immutable object holding an array, which
        # (unlike a struct) can be indexed at run time
        return tuple_array_layout(ts, T, fieldtype(T, 1))
    end
    if length(leaves) > MAX_INLINE_LEAVES
        # a large immutable value: an immutable object
        l = boxed_layout(ts, T, box_type!(ts, T, leaves))
        l.fields = [r .+ HEADER_FIELDS for r in ranges]
        return l
    end
    return Layout(T, Inline, leaves, ranges, nothing)
end

mutable_struct_layout(ts::Types, @nospecialize(T)) = struct_object_layout(ts, T, true)

# the layout of a struct whose values are objects with a Wasm field per leaf (mutable or
# not); the type is declared first, as fields may refer to it
function struct_object_layout(ts::Types, @nospecialize(T), mutable::Bool)
    m = ts.mod
    idx = length(m.types)
    wtype = TypeRef(idx)
    push!(m.types, SubType(StructType(FieldType[]); final=true, super=ts.jlvalue))
    l = boxed_layout(ts, T, wtype)
    ts.layouts[T] = l
    mutable || (ts.boxes[(:box, T)] = wtype)
    leaves, ranges = struct_field_ranges(ts, T, HEADER_FIELDS)
    fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
    for leaf in leaves
        push!(fields, FieldType(nullable_storage(leaf.storage), mutable))
    end
    m.types[idx+1] = SubType(StructType(fields); final=true, super=ts.jlvalue)
    l.fields = ranges
    return l
end

nullable_storage(t::RefType) = RefType(t.heap, true)
nullable_storage(t) = t

## arrays

"""
    array_type!(ts, storage) -> TypeRef

The Wasm array type with mutable elements of `storage` (shared by all Julia types whose
elements are stored that way).
"""
function array_type!(ts::Types, storage::StorageType)
    get!(ts.arrays, storage) do
        add_type!(ts.mod, ArrayType(FieldType(storage, true)))
    end
end

"""
    MemoryLayout

How the elements of a `Memory{T}` are stored in its array: as `storage`, `stride` array
elements per Julia element. Inline elements whose leaves are stored alike are stored as
their leaves (as Julia lays them out); other isbits elements have their leaves `widened`
to `i64`s (so that elements never are undefined); other inline elements are `boxed` (a
reference per element to a box).
"""
struct MemoryLayout
    elem::Layout
    array::TypeRef
    storage::StorageType
    stride::Int
    boxed::Bool
    widened::Bool
end

function memory_layout(ts::Types, @nospecialize(E))
    el = layout(ts, E)
    if el.kind === Ghost || el.kind === Bottom
        return MemoryLayout(el, array_type!(ts, I8), I8, 1, false, false)
    end
    leaves = el.leaves
    s = nullable_storage(leaves[1].storage)
    el.kind === Boxed && return MemoryLayout(el, array_type!(ts, s), s, 1, false, false)
    if all(l -> nullable_storage(l.storage) == s, leaves)
        return MemoryLayout(el, array_type!(ts, s), s, length(leaves), false, false)
    end
    if all(l -> l.type isa NumType, leaves)
        return MemoryLayout(el, array_type!(ts, I64), I64, length(leaves), false, true)
    end
    # (a tuple with union elements is boxed as one of several concrete tuple types: any object)
    box = is_union_tuple(E) ? ts.jlvalue : box_type!(ts, E)
    st = RefType(box, true)
    return MemoryLayout(el, array_type!(ts, st), st, 1, true, false)
end

memory_array_type!(ts::Types, @nospecialize(E)) = memory_layout(ts, E).array

## objects

"""
    box_type!(ts, T) -> TypeRef

The Wasm struct type of boxes of values of the inline (or ghost) type `T`: the header
and its leaves, immutable.
"""
function box_type!(ts::Types, @nospecialize(T), leaves::Vector{Leaf}=Leaf[])
    get!(ts.boxes, (:box, T)) do
        if isempty(leaves)
            l = layout(ts, T)
            leaves = l.kind === Ghost ? Leaf[] : l.leaves
        end
        fields = FieldType[FieldType(I32, false), FieldType(I32, true)]
        for leaf in leaves
            push!(fields, FieldType(nullable_storage(leaf.storage), false))
        end
        add_type!(ts.mod, StructType(fields); final=true, super=ts.jlvalue)
    end
end

"""
    memory_struct_type!(ts, E) -> TypeRef

The Wasm struct type of `Memory{E}` objects: the header and the array of the elements.
"""
function memory_struct_type!(ts::Types, @nospecialize(E))
    get!(ts.boxes, (:memory, memory_array_type!(ts, E))) do
        arr = memory_array_type!(ts, E)
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(RefType(arr, true), false)]);
                  final=true, super=ts.jlvalue)
    end
end

"""
    bytes_object_type!(ts, T) -> TypeRef

The Wasm struct type of `String`s or `Symbol`s: the header and the bytes (the array type
of `Memory{UInt8}`, which the conversions between strings and memory share). A symbol also
has its hash, as Julia's runtime computes it (`objectid`, `SYMBOL_HASH_FIELD`).
"""
function bytes_object_type!(ts::Types, @nospecialize(T))
    get!(ts.boxes, T) do
        bytes = array_type!(ts, I8)
        fields = [FieldType(I32, false), FieldType(I32, true), FieldType(RefType(bytes, true), false)]
        T === Symbol && push!(fields, FieldType(I64, false))
        add_type!(ts.mod, StructType(fields); final=true, super=ts.jlvalue)
    end
end

"""
    type_object_type!(ts) -> TypeRef

The Wasm struct type of type objects (`DataType`s, `UnionAll`s, `Union`s used as values):
the header and the id of the type they are (each type object is one global, so `===` is
reference equality).
"""
function type_object_type!(ts::Types)
    get!(ts.boxes, :typeobject) do
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(I32, false)]);
                  final=true, super=ts.jlvalue)
    end
end

"""
    named_object_type!(ts) -> TypeRef

The Wasm struct type of `Core.TypeName` and `Module` objects: the header and the name (a
Symbol), what code reads of them at run time (to print a type's or a module's name).
"""
function named_object_type!(ts::Types)
    get!(ts.boxes, :typename) do
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(layout(ts, Symbol).leaves[1].type, false)]);
                  final=true, super=ts.jlvalue)
    end
end

"The field of the array of the objects of `Memory`, `String` and `Symbol`."
const DATA_FIELD = HEADER_FIELDS

"""
    funcptr_box_type!(ts, sig) -> TypeRef

The Wasm struct type of the boxes that own function pointers: the header and a nullable
reference to a function of type `sig` (field `DATA_FIELD`). See `runtime/fwrappers.jl`.
"""
function funcptr_box_type!(ts::Types, sig::TypeRef)
    get!(ts.boxes, (:funcptr, sig)) do
        add_type!(ts.mod, StructType([FieldType(I32, false), FieldType(I32, true),
                                       FieldType(RefType(sig, true), false)]);
                  final=true, super=ts.jlvalue)
    end
end
"The index of the hash of a `Symbol` object (after its bytes)."
const SYMBOL_HASH_FIELD = DATA_FIELD + 1

"Whether the objects of the boxed type `T` are `\$JlValue`s (they all are)."
is_jlvalue_type(ts::Types, @nospecialize(T)) = true

"""
    valtypes(ts, T) -> Vector{ValType}

The Wasm types of the leaves of values of type `T` (parameters, results, locals).
"""
valtypes(ts::Types, @nospecialize(T)) = ValType[l.type for l in layout(ts, T).leaves]
