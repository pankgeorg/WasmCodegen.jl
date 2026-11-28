# C function pointers: `cfunction` and `ccall` through a pointer. Results are compared with
# native Julia's.
module CFunctionPrograms

## plain C function pointers

add1(x::Float64) = x + 1.0
twice(x::Int32, y::Float64) = 2.0 * x + y
c_direct(x::Float64) = ccall(@cfunction(add1, Float64, (Float64,)), Float64, (Float64,), x)
c_scalars(x::Float64) = ccall(@cfunction(twice, Float64, (Int32, Float64)), Float64, (Int32, Float64), Int32(3), x)
function c_select(i::Int, x::Float64)
    p = i == 1 ? @cfunction(add1, Float64, (Float64,)) : @cfunction(sqrt, Float64, (Float64,))
    return ccall(p, Float64, (Float64,), x)
end
c_notnull(x::Float64) = @cfunction(add1, Float64, (Float64,)) != C_NULL ? x : -x
function c_copies(x::Float64)
    p = @cfunction(add1, Float64, (Float64,))
    q = p
    r = [p]
    return p == q && r[1] == p ? ccall(r[1], Float64, (Float64,), x) : -x
end
const PTRS = Ptr{Cvoid}[C_NULL, C_NULL]
function c_distinct(x::Float64)
    PTRS[1] = @cfunction(add1, Float64, (Float64,))
    PTRS[2] = @cfunction(sqrt, Float64, (Float64,))
    return PTRS[1] != PTRS[2] ? x : -x
end
function c_roundtrip(x::Float64)
    u = UInt(@cfunction(add1, Float64, (Float64,)))
    return ccall(Ptr{Cvoid}(u), Float64, (Float64,), x)
end
readref(r::Float64) = r * 2.0
c_ref_of_bits(x::Float64) = ccall(@cfunction(readref, Float64, (Ref{Float64},)), Float64, (Ref{Float64},), x)
c_ref_into_array(x::Float64) = (v = [0.0, x]; GC.@preserve v ccall(@cfunction(readref, Float64, (Ref{Float64},)), Float64, (Ptr{Float64},), pointer(v, 2)))
writeptr(p::Ptr{Float64}, x::Float64) = (unsafe_store!(p, x); nothing)
function c_write_through(x::Float64)
    v = [0.0, 0.0]
    GC.@preserve v ccall(@cfunction(writeptr, Cvoid, (Ptr{Float64}, Float64)), Cvoid, (Ptr{Float64}, Float64), pointer(v, 2), x)
    return v[2]
end
samevec(a::Vector{Float64}, b::Vector{Float64}) = a === b
c_object_ref(x::Float64) = (v = [x]; ccall(@cfunction(samevec, Bool, (Ref{Vector{Float64}}, Ref{Vector{Float64}})), Bool, (Any, Any), v, v))
mutable struct Box
    x::Float64
end
address_of(b::Box, p::Ptr{Cvoid}) = pointer_from_objref(b) == p
function c_object_address(x::Float64)
    b = Box(x)
    return ccall(@cfunction(address_of, Bool, (Any, Ptr{Cvoid})), Bool, (Any, Any), b, b)
end
newvec(x::Float64) = [x, x + 1.0]
c_ref_result(x::Float64) = ccall(@cfunction(newvec, Ref{Vector{Float64}}, (Float64,)), Ref{Vector{Float64}}, (Float64,), x)[2]
c_any_result(x::Float64) = ccall(@cfunction(add1, Any, (Float64,)), Any, (Float64,), x)::Float64
const LAST = Ref(0.0)
remember(x::Float64) = (LAST[] = x; nothing)
c_void_result(x::Float64) = (ccall(@cfunction(remember, Cvoid, (Float64,)), Cvoid, (Float64,), x); LAST[])

isptr(x::Any) = x isa Ptr{Float64}
function c_any_pointer(x::Float64)
    v = [x]
    return GC.@preserve v ccall(@cfunction(isptr, Bool, (Any,)), Bool, (Any,), pointer(v))
end
c_any_null_pointer(x::Float64) = ccall(@cfunction(isptr, Bool, (Any,)), Bool, (Any,), Ptr{Float64}(0))
objaddress(v::Vector{Float64}) = pointer_from_objref(v)
function c_ptr_result_as_ref(x::Float64)
    v = [x]
    p = @cfunction(objaddress, Ptr{Cvoid}, (Ref{Vector{Float64}},))
    return GC.@preserve v ccall(p, Ref{Vector{Float64}}, (Any,), v)[1]
end
function c_ref_result_as_ptr(x::Float64)
    p = @cfunction(identity, Ref{Vector{Float64}}, (Ref{Vector{Float64}},))
    v = [x]
    return GC.@preserve v (unsafe_pointer_to_objref(ccall(p, Ptr{Cvoid}, (Any,), v))::Vector{Float64})[1]
end
function c_any_result_as_ptr(x::Float64)
    p = @cfunction(identity, Any, (Any,))
    v = [x]
    return GC.@preserve v (unsafe_pointer_to_objref(ccall(p, Ptr{Cvoid}, (Any,), v))::Vector{Float64})[1]
end
function c_ptr_result_as_any(x::Float64)
    v = [x]
    p = @cfunction(objaddress, Ptr{Cvoid}, (Ref{Vector{Float64}},))
    return GC.@preserve v (ccall(p, Any, (Any,), v)::Vector{Float64})[1]
end
struct InlineReference
    a::String
    b::Float64
end
field_b(v::InlineReference) = v.b
function c_ref_into_inline_array(x::Float64)
    a = [InlineReference("a", 1.0), InlineReference("b", x)]
    return ccall(@cfunction(field_b, Float64, (Ref{InlineReference},)), Float64, (Ref{InlineReference},), Ref(a, 2))
end
new_inline(x::Float64) = InlineReference("returned", x)
null_pointer(::Float64) = C_NULL
c_ref_inline_result(x::Float64) = ccall(@cfunction(new_inline, Ref{InlineReference}, (Float64,)), Ref{InlineReference}, (Float64,), x).b
c_ref_bits_result(x::Float64) = ccall(@cfunction(add1, Ref{Float64}, (Float64,)), Ref{Float64}, (Float64,), x)
c_ref_pointer_result(x::Float64) =
    ccall(@cfunction(null_pointer, Ref{Ptr{Cvoid}}, (Float64,)), Ref{Ptr{Cvoid}}, (Float64,), x) == C_NULL
read_ref(r::Float64) = 2.0 * r
c_any_as_ref(x::Float64) = ccall(@cfunction(read_ref, Float64, (Ref{Float64},)), Float64, (Any,), x)
is_null(p::Ptr{Cvoid}) = p == C_NULL
c_ref_of_pointer(::Float64) = ccall(@cfunction(is_null, Bool, (Ref{Ptr{Cvoid}},)), Bool, (Ref{Ptr{Cvoid}},), Ref(C_NULL))
c_ref_bits_result_as_ptr(x::Float64) = ccall(@cfunction(add1, Ref{Float64}, (Float64,)), Ptr{Cvoid}, (Float64,), x) != C_NULL
# one pointer per compiled `cfunction`: two of one function and signature are two, one run twice is one
function c_sites(x::Float64)
    p = @cfunction(add1, Float64, (Float64,))
    q = @cfunction(add1, Float64, (Float64,))
    ps = Vector{Ptr{Cvoid}}(undef, 2)
    for i in 1:2
        ps[i] = @cfunction(add1, Float64, (Float64,))
    end
    return p != q && ps[1] == ps[2] ? ccall(q, Float64, (Float64,), x) : -x
end

## errors of the program

wrong_signature() = @cfunction(add1, Float64, (Float64,))
bad_call(x::Float64) = ccall(wrong_signature(), Float64, (Float64, Float64), x, x)
const HOLE = Ref(C_NULL)
not_a_function(x::Float64) = ccall(HOLE[], Float64, (Float64,), x)
bad_null(x::Float64) = (keep = @cfunction(add1, Float64, (Float64,)); keep == C_NULL ? x : not_a_function(x))
function caught(f, x::Float64)
    try
        return f(x)
    catch e
        return e isa ErrorException ? 11.0 : e isa UndefRefError ? 12.0 : 13.0
    end
end
catch_null(x::Float64) = caught(bad_null, x)
fromint(i::Int32) = Float64(i)
const OTHER = Ref(C_NULL)
function catch_wrong(x::Float64)
    OTHER[] = @cfunction(add1, Float64, (Float64,))
    keep = @cfunction(fromint, Float64, (Int32,))
    return caught(z -> ccall(OTHER[], Float64, (Int32,), Int32(1)) + ccall(keep, Float64, (Int32,), Int32(2)), x)
end
# a signature no `cfunction` of the module has: an ErrorException when the call is reached, and
# no error of a call that is not (a list of callbacks that stays empty)
catch_unmade(x::Float64) = caught(bad_call, x)
const CALLBACKS = Ptr{Cvoid}[]
function unreached(x::Float64)
    s = x
    for p in CALLBACKS
        s += ccall(p, Float64, (Float64, Float64, Float64), x, x, x)
    end
    return s
end

## what is reported

closure_value(x::Float64) = (f = y -> y + x; ccall(@cfunction($f, Float64, (Float64,)), Float64, (Float64,), x))
ref_any(x::Float64) = @cfunction(add1, Float64, (Ref{Any},))
wrong_result(x::Float64) = @cfunction(string, Float64, (Float64,))
ignored(x::Float64) = x + 1.0
void_of_value(x::Float64) = @cfunction(ignored, Cvoid, (Float64,))
constant_target(x::Float64) = ccall(Ptr{Cvoid}(UInt(0x1234)), Float64, (Float64,), x)
null_target(x::Float64) = ccall(Ptr{Cvoid}(UInt(0)), Float64, (Float64,), x)
variadic(x::Float64) = ccall(@cfunction(add1, Float64, (Float64,)), Float64, (Float64, Float64...), x, x)
mutable struct Cell
    x::Int
end
seven(c::Cell) = c.x == 7
mutable_by_value(x::Float64) = ccall(@cfunction(seven, Bool, (Cell,)), Bool, (Cell,), Cell(7))
of_nothing(::Nothing) = 1.0
nothing_argument(x::Float64) = ccall(@cfunction(of_nothing, Float64, (Nothing,)), Float64, (Nothing,), nothing)
struct Named
    s::String
end
named(x::Float64) = Named("x")
struct_with_reference(x::Float64) = ccall(@cfunction(named, Named, (Float64,)), Named, (Float64,), x)
# a type's kind: by value as an argument (an immutable `UnionAll`, the same object), a struct
# that holds references as a result
is_vector(T::UnionAll) = T === Vector
c_kind_argument(x::Float64) = ccall(@cfunction(is_vector, Bool, (UnionAll,)), Bool, (UnionAll,), Vector) ? x : -x
vector_type(::Any) = Vector
kind_result(x::Float64) = ccall(@cfunction(vector_type, UnionAll, (Any,)), Any, (Any,), x) === Vector
end

@testset "C function pointers" begin
    P = CFunctionPrograms
    cases = [(P.c_direct, (1.5,)), (P.c_scalars, (0.5,)), (P.c_select, (1, 4.0)), (P.c_select, (2, 4.0)),
             (P.c_notnull, (1.0,)), (P.c_copies, (1.0,)), (P.c_distinct, (1.0,)), (P.c_roundtrip, (1.0,)),
             (P.c_sites, (1.0,)), (P.c_any_pointer, (1.5,)), (P.c_any_null_pointer, (1.5,)),
             (P.c_ptr_result_as_ref, (1.5,)), (P.c_ref_result_as_ptr, (1.5,)), (P.c_any_result_as_ptr, (1.5,)),
             (P.c_ptr_result_as_any, (1.5,)), (P.c_ref_into_inline_array, (1.5,)),
             (P.c_ref_inline_result, (1.5,)), (P.c_ref_bits_result, (1.5,)), (P.c_ref_pointer_result, (1.5,)),
             (P.c_any_as_ref, (1.5,)), (P.c_ref_of_pointer, (1.5,)), (P.c_ref_bits_result_as_ptr, (1.5,)),
             (P.c_ref_of_bits, (1.5,)), (P.c_ref_into_array, (1.5,)), (P.c_write_through, (1.5,)),
             (P.c_object_ref, (1.5,)), (P.c_object_address, (1.5,)), (P.c_ref_result, (1.5,)),
             (P.c_any_result, (1.5,)), (P.c_void_result, (1.5,)), (P.c_kind_argument, (1.5,))]
    names = ["e$i" for i in eachindex(cases)]
    c = compile([Entry(f, typeof.(args); name) for ((f, args), name) in zip(cases, names)]; config = WasmCodegen.Config(verify = :off))
    for ((f, args), name) in zip(cases, names)
        expected = f(args...)
        @test wasm_run(c, name, args...; rettype = typeof(expected)) === expected
    end

    # a call through a null pointer: an UndefRefError, as natively; through a function of another
    # signature (natively undefined behavior), an ErrorException
    c = compile([Entry(P.catch_null, (Float64,)), Entry(P.catch_wrong, (Float64,))]; config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "catch_null", 1.0; rettype = Float64) === P.catch_null(1.0)
    @test wasm_run(c, "catch_wrong", 1.0; rettype = Float64) === 11.0
    c = compile([Entry(P.catch_unmade, (Float64,)), Entry(P.unreached, (Float64,))]; config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "catch_unmade", 1.0; rettype = Float64) === 11.0
    @test wasm_run(c, "unreached", 1.5; rettype = Float64) === P.unreached(1.5)

    function report(f, argtypes)
        e = try
            compile(f, argtypes; config = WasmCodegen.Config(verify = :off))
            nothing
        catch err
            err
        end
        return e isa WasmCodegen.UnsupportedConstructs ? sprint(showerror, e) : e
    end
    @test occursin("a cfunction of", report(P.closure_value, (Float64,)))
    @test occursin("which is not concrete", report(P.ref_any, (Float64,)))
    @test occursin("a cfunction whose function returns", report(P.wrong_result, (Float64,)))
    @test occursin("a cfunction whose function returns", report(P.void_of_value, (Float64,)))
    @test occursin("a pointer of the build process", report(P.constant_target, (Float64,)))
    @test occursin("a ccall through the constant pointer", report(P.null_target, (Float64,)))
    @test occursin("a variadic ccall", report(P.variadic, (Float64,)))
    # what native Julia copies (a mutable struct by value) or cannot compile (an argument of no
    # size, a result by value that holds references)
    @test occursin("the mutable type", report(P.mutable_by_value, (Float64,)))
    @test occursin("of no size", report(P.nothing_argument, (Float64,)))
    @test occursin("whose fields hold references", report(P.struct_with_reference, (Float64,)))
    @test occursin("whose fields hold references", report(P.kind_result, (Float64,)))
end
