# Values in generated code.

"A leaf of a value: a local of the function, or one instruction that pushes a constant."
const LeafVal = Union{Int,Inst}

"""
    PtrOrigin(mem, array, index, eltype)

Where a pointer points, when it is known statically: the byte `index` (an i32 leaf) of
the array (a leaf) of the object `mem` (a Memory or a String, a leaf) of elements of type
`eltype`; or, with `array === nothing`, into the object `mem` itself (`jl_value_ptr` of a
`Ref`). Loads, stores and copies through a pointer with an origin are compiled to accesses
of its array (see pointers.jl). `terminated`: the bytes of a String or Symbol, whose byte
past the end is a NUL (as natively).
"""
struct PtrOrigin
    mem::Any
    array::Any
    index::Any
    eltype::Any
    terminated::Bool
end
PtrOrigin(mem, array, index, eltype) = PtrOrigin(mem, array, index, eltype, false)
PtrOrigin(array, index, eltype) = PtrOrigin(nothing, array, index, eltype)

is_object_origin(o::PtrOrigin) = o.array === nothing

"""
    CGVal

A value in generated code: its Julia type `typ` (widened), its representation `kind`,
its leaves (a local, or a constant instruction, per Wasm value of the layout of `typ`),
the value itself when it is known at compile time, and for a pointer, its origin.
"""
struct CGVal
    typ::Any
    kind::Kind
    leaves::Vector{LeafVal}
    constant::Union{Nothing,Some{Any}}
    origin::Union{Nothing,PtrOrigin}
end

CGVal(@nospecialize(typ), kind::Kind, leaves::AbstractVector) =
    CGVal(typ, kind, convert(Vector{LeafVal}, leaves), nothing, nothing)
CGVal(@nospecialize(typ), kind::Kind, leaves::AbstractVector, constant) =
    CGVal(typ, kind, convert(Vector{LeafVal}, leaves), constant, nothing)

"The ghost value `v` of type `T`."
ghost(@nospecialize(T), @nospecialize(v)) = CGVal(T, Ghost, LeafVal[], Some{Any}(v))

"The value of code that never returns."
bottom() = CGVal(Union{}, Bottom, LeafVal[], nothing)

isconstant(v::CGVal) = v.constant !== nothing
constant_value(v::CGVal) = something(v.constant)

function Base.show(io::IO, v::CGVal)
    print(io, "CGVal(", v.kind, ", ", v.typ)
    isconstant(v) && (print(io, ", constant="); show(io, constant_value(v)))
    print(io, ", ", v.leaves, ")")
end

"""
    MultiVal

The results of a structured control flow operation (an `if` or a loop), read with
`getfield(op, i)`.
"""
struct MultiVal
    vals::Vector{CGVal}
end

"""
    SplitUnion

A value of a union of concrete types `typ` held unboxed: one value per member type of the
union it was made as (`vals`, in the order of `members`, a superset of the members of `typ`)
and the local `tag`, the (1-based, i32) index of the member it is. Only `isa` with a type
known at compile time and narrowing read it (`analyze_split_unions!`): to a member, its
value; to a smaller union, the same `SplitUnion` of that type. Only `vals[tag]` holds the
value; the others hold whatever was last assigned to them.
"""
struct SplitUnion
    typ::Any
    members::Vector{Any}
    tag::Int
    vals::Vector{CGVal}
end
