# Building tuples of known length whose element types are not all known at compile time
# (`Tuple{Any}`, `Tuple{String, Any}`): natively `Core.tuple` makes their type at run time from
# the elements' (`jl_f_tuple`). Here such a tuple is an object of the module's concrete tuple
# type of its elements, found at run time (`tuple_canon_func!`), read by its type
# (`get_field_any!`); of a type no code names, `typeof` of it is the closed world's error.

module AbstractTupleTests

using Test
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen, LAST_OUTPUT

# a value of a type known only at run time
@noinline pick(i::Int) = i == 1 ? Base.inferencebarrier(1) : i == 2 ? Base.inferencebarrier("two") :
                         i == 3 ? Base.inferencebarrier(nothing) : Base.inferencebarrier(2.5)
@noinline small(i::Int)::Union{Int,String} = isodd(i) ? i : string(i)
@noinline id(x) = x

# the type `Core.tuple` gives, of the elements' types
function at_type(i::Int)
    t = (pick(i),)
    T = typeof(t)
    return (T === Tuple{Int}) + 2 * (T === Tuple{String}) + 4 * (T === Tuple{Nothing}) + 8 * (T === Tuple{Float64})
end
function at_type2(i::Int)
    t = (small(i), pick(i))
    T = typeof(t)
    return (T === Tuple{Int,Int}) + 2 * (T === Tuple{String,String}) + 4 * (T === Tuple{Int,Nothing}) +
           8 * (T === Tuple{String,Float64})
end
# a type object as an element: natively `Tuple{DataType}`, not `Tuple{Type{Int}}`
at_type_elem(i::Int) = (t = (typeof(pick(i)),); (typeof(t) === Tuple{DataType}, t[1] === Int, t[1] === String))
# (; exception = e): `splatnew` of `NamedTuple{names, typeof(t)}` at run time
function at_namedtuple(i::Int)
    nt = (; exception = pick(i), n = i)
    T = typeof(nt)
    return (T === @NamedTuple{exception::Int, n::Int}) + 2 * (T === @NamedTuple{exception::String, n::Int}) +
           4 * (nt.exception isa Nothing) + 8 * (nt.n == i)
end
@noinline kw(; exception, n = 0) = (exception isa Int ? 1 : exception isa String ? 2 : 3) + 10n
# (the `NamedTuple` types it may make, named by the program)
at_kwcall(i::Int) = kw(; exception = pick(i), n = i) +
    100 * (id(typeof((; exception = pick(i), n = i))) in (@NamedTuple{exception::Int, n::Int}, @NamedTuple{exception::String, n::Int}))

# the fields, at constant and run-time indices
function at_fields(i::Int)
    t = (pick(i), "s", small(i), pick(i + 1))
    s = 0
    for x in t
        s = 7s + (x isa Int ? 1 : x isa String ? sizeof(x) + 2 : x === nothing ? 3 : 4)
    end
    k = id(i) % 4 + 1
    return (s, length(t), sizeof(t[2]), t[k] isa String, nfields(t))
end
function at_bounds(i::Int)
    t = (pick(i), pick(i + 1))
    try
        return t[id(i) + 1] isa Int ? 1 : 2
    catch err
        return err isa BoundsError ? -1 : -2
    end
end

# isa, === and objectid (`==` and `hash` of the elements are calls of functions of `Any`s)
function at_compare(i::Int)
    t = (pick(i),)
    u = (pick(i),)
    return (t === (1,), t === ("two",), t === (nothing,), t === u, t === (2.5,),
            t isa Tuple{Int}, t isa Tuple{Union{String,Nothing}}, t isa Union{Nothing,Tuple{Int}},
            objectid(t) == objectid(u))
end
# narrowing on a union-split path (a PiNode where it may not hold)
function at_pi(i::Int)
    t = i > 2 ? (pick(i),) : nothing
    t === nothing && return 0
    return t[1] isa Int ? 1 : t[1] === nothing ? 3 : 4
end
# a union element back from the erased tuple
at_union_back(i::Int) = (t = (small(i), pick(i)); x = t[1]; x isa Int ? x : sizeof(x))

# stored: a field, a vector element, an image constant
struct AtHolder
    t::Tuple{Any}
    u::Tuple{String,Any}
end
const AT_CONST = Tuple{Any}[(1,), ("abc",), (nothing,)]
const AT_HOLDER = AtHolder((2.5,), ("k", 7))
function at_stored(i::Int)
    h = id(AtHolder((pick(i),), ("x", pick(i + 1))))
    v = Tuple{Any}[]
    push!(v, h.t); push!(v, (pick(i + 1),))
    c = AT_CONST[mod1(i, 3)]
    return (h.t[1] isa Int, h.u[2] isa String, v[2] === (pick(i + 1),), v[1] === h.t, c[1] isa String,
            AT_HOLDER.t === (2.5,), AT_HOLDER.u[2] === 7, id(h) === h)
end

# the varargs of printing: a small union, a `Type` of an abstract type (Tuple{String, Type{<:Integer}})
at_string(i::Int) = (s = string("a", small(i), 'c'); (sizeof(s), hash(s)))
@noinline itype(i::Int)::Type{<:Integer} = isodd(i) ? Int : UInt8
function at_error(i::Int)
    try
        error("value of type ", itype(i), "!")
    catch err
        s = (err::ErrorException).msg::String
        return (sizeof(s), hash(s))
    end
end

# a large tuple of one type as an object: of its own type, as before
at_large(i::Int) = (t = ntuple(k -> k * i, 70); x = id(t); (typeof(x) === NTuple{70,Int}, x === t, x[70]))

# a tuple whose concrete type no code of the module names: built, read and compared, but its
# `typeof` is the closed world's error
struct AtUnnamed
    a::Int
end
@noinline unnamed(i::Int) = Base.inferencebarrier(AtUnnamed(i))
function at_unnamed_ok(i::Int)
    t, u = (unnamed(i), i), (unnamed(i), id(i))
    return (t[1] isa AtUnnamed, (t[1]::AtUnnamed).a, t === u, t[2] === u[2], objectid(t) == objectid(u))
end
# (compared with a type, as `<: Tuple` of it is folded by inference)
at_unnamed_typeof(i::Int) = id(typeof(id((unnamed(i),)))) === Tuple{Int}

@testset "tuples of abstract type" begin
    for i in 1:4
        @wtest at_type(i)
        @wtest at_type2(i)
        @wtest at_type_elem(i)
        @wtest at_fields(i)
        @wtest at_compare(i)
        @wtest at_pi(i)
        @wtest at_union_back(i)
        @wtest at_stored(i)
        @wtest at_string(i)
        @wtest at_error(i)
        @wtest at_unnamed_ok(i)
    end
    for i in 0:2
        @wtest at_bounds(i)
    end
    # (of the `NamedTuple` types code names: of an `Int` and of a `String`)
    for i in 1:2
        @wtest at_namedtuple(i)
        @wtest at_kwcall(i)
    end
    @wtest at_large(3)
    # (with trim = :safe: none of them is an unsupported construct)
    for (f, at) in ((at_type, (Int,)), (at_namedtuple, (Int,)), (at_fields, (Int,)), (at_string, (Int,)))
        @test isempty(WasmCodegen.compile(f, at).cgm.diagnostics)
    end
    # the closed world: natively `Tuple{AtUnnamed}`; here an error with a message
    @test !at_unnamed_typeof(1)
    @test at_namedtuple(4) == 8
    let got = wasm_run(wcompile(at_unnamed_typeof, (Int,)), "at_unnamed_typeof", 1; rettype=Bool)
        @test got isa Tuple && got[1] === :trap
        @test occursin("typeof of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
    # (a `NamedTuple` of a value whose tuple type no code names: `Tuple{Float64, Int}`, the
    # `typeof` of `NamedTuple{names}(t)`)
    let got = wasm_run(wcompile(at_namedtuple, (Int,)), "at_namedtuple", 4; rettype=Int)
        @test got isa Tuple && got[1] === :trap
        @test occursin("typeof of a tuple whose concrete type the module does not have", LAST_OUTPUT[])
    end
end

end
