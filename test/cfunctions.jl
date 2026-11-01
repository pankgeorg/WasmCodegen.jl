# C function pointers: `cfunction` and `ccall` through a pointer, on their own and as FunctionWrappers
# uses them (with no code of its own in the compiler). Results are compared with native Julia's.
module CFunctionPrograms
using FunctionWrappers: FunctionWrapper
import FunctionWrappers

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

## FunctionWrappers

struct Scale
    c::Float64
end
(s::Scale)(x::Float64) = s.c * x + 1.0
fw_inline(x::Float64, c::Float64) = (w = FunctionWrapper{Float64, Tuple{Float64}}(Scale(c)); w(x) + w(2x))

mutable struct Counter
    n::Int
end
(c::Counter)(k::Int) = (c.n += k; c.n)
function fw_mutable(k::Int)
    c = Counter(10)
    w = FunctionWrapper{Int, Tuple{Int}}(c)
    w(k); w(k)
    return c.n
end

fw_closure(x::Float64) = (v = [x, 2x]; FunctionWrapper{Float64, Tuple{Int}}(i -> v[i])(2))
adder(c) = y -> y + c
const AF = FunctionWrapper{Float64, Tuple{Float64}}
fw_captures(x::Float64) = (ws = AF[AF(adder(1.0)), AF(adder(x))]; ws[1](x) + 10ws[2](x))
fw_two_types(x::Float64) = (ws = AF[AF(Scale(3.0)), AF(y -> y - 1.0)]; ws[1](x) + ws[2](x))
fw_same_pointer(x::Float64) = (a = AF(adder(1.0)); b = AF(adder(2.0)); a.ptr == b.ptr ? a(x) + b(x) : -x)
fw_distinct_pointer(x::Float64) = (a = AF(adder(1.0)); b = AF(Scale(2.0)); a.ptr != b.ptr ? a(x) + b(x) : -x)
fw_bool(x::Float64) = FunctionWrapper{Bool, Tuple{Float64, Float64}}(>)(x, 1.0)
fw_convert_result(x::Float64) = FunctionWrapper{Float64, Tuple{Float64}}(y -> y > 0.0 ? 2 : 3)(x)
fw_convert_arg(x::Float64) = FunctionWrapper{Float64, Tuple{Float64}}(identity)(Int(round(x)))
fw_nothing_result(x::Float64) = (b = Ref(0.0); FunctionWrapper{Nothing, Tuple{Float64}}(y -> (b[] = y; 1.0))(x); b[])

struct NoParams end
struct Shift
    c::Float64
end
(s::Shift)(x::Float64, ::NoParams) = x - s.c
fw_singleton(x::Float64) = FunctionWrapper{Float64, Tuple{Float64, NoParams}}(Shift(x))(2x, NoParams())

const VF = FunctionWrapper{Nothing, Tuple{Vector{Float64}, Vector{Float64}, Float64}}
function fw_vectors(t::Float64)
    a = 2.0
    w = VF((du, u, s) -> (du .= a .* u .+ s; nothing))
    u = [1.0, 2.0]; du = zeros(2)
    w(du, u, t)
    return du[1] + 10du[2]
end
function fw_aliased(t::Float64)
    w = VF((du, u, s) -> (du === u && (du[1] += s); du[2] = u[1]; nothing))
    u = [1.0, 2.0]
    w(u, u, t)
    return u[1] + 10u[2]
end
fw_matrix(x::Float64) = (m = [x 2x; 3x 4x]; FunctionWrapper{Float64, Tuple{Matrix{Float64}, Int}}((a, i) -> a[i, 2])(m, 2))
fw_vector_result(x::Float64) = FunctionWrapper{Vector{Float64}, Tuple{Float64}}(y -> [y, y + 1])(x)[2]
fw_any_result(x::Float64) = FunctionWrapper{Any, Tuple{Float64}}(y -> y + 1)(x)::Float64
fw_any_arg(x::Float64) = FunctionWrapper{Float64, Tuple{Any}}(y -> y::Float64 + 1.0)(x)
fw_nested(x::Float64) = (i = AF(adder(x)); o = AF(y -> AF(adder(y))(i(y))); o(1.0))

fails(x::Float64) = x > 0.0 ? throw(DomainError(x)) : x
function fw_throw(x::Float64)
    w = FunctionWrapper{Float64, Tuple{Float64}}(fails)
    try
        return w(x)
    catch e
        return e isa DomainError ? 7.0 : 8.0
    end
end

## wrappers of the image: their pointers are null there and the program sets them

function set_wrapper!(w::FunctionWrapper{Ret, Args}, ::Type{T}) where {Ret, Args, T}
    w.ptr = FunctionWrappers.gen_fptr(Ret, Args, T)
    w.objptr = Base.unsafe_convert(Ref{T}, w.obj::Base.RefValue{T})
    return nothing
end
const IMG = AF(Scale(2.0))
const COUNT = Counter(5)
const IMGM = FunctionWrapper{Int, Tuple{Int}}(COUNT)
const STATE = [1.0, 2.0]
const CAP = adder(STATE[2])
const IMGC = AF(CAP)
mutable struct Holder
    w::Union{Nothing, AF}
end
struct BackRef
    h::Holder
end
(b::BackRef)(x::Float64) = b.h.w === nothing ? -1.0 : x + 1.0
const HOLDER = Holder(nothing)
const IMGB = AF(BackRef(HOLDER))
HOLDER.w = IMGB
const IMAGE_WRAPPERS = (IMG, IMGM, IMGC, IMGB)
const SET = Ref(false)
function set_all!()
    SET[] && return
    SET[] = true
    set_wrapper!(IMG, Scale)
    set_wrapper!(IMGM, Counter)
    set_wrapper!(IMGC, typeof(CAP))
    set_wrapper!(IMGB, BackRef)
    nothing
end
img_inline(x::Float64) = (set_all!(); IMG(x))
img_mutable(k::Int) = (set_all!(); IMGM(k); COUNT.n)
img_closure(x::Float64) = (set_all!(); IMGC(x))
img_cycle(x::Float64) = (set_all!(); IMGB(x))
function null_image()
    saved = [(w, w.ptr, w.objptr) for w in IMAGE_WRAPPERS]
    for (w, _, _) in saved
        w.ptr = C_NULL; w.objptr = C_NULL
    end
    return () -> foreach(((w, p, o),) -> (w.ptr = p; w.objptr = o), saved)
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
        return e isa ErrorException ? 11.0 : 12.0
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

## what is reported

closure_value(x::Float64) = (f = y -> y + x; ccall(@cfunction($f, Float64, (Float64,)), Float64, (Float64,), x))
ref_any(x::Float64) = @cfunction(add1, Float64, (Ref{Any},))
wrong_result(x::Float64) = @cfunction(string, Float64, (Float64,))
ignored(x::Float64) = x + 1.0
void_of_value(x::Float64) = @cfunction(ignored, Cvoid, (Float64,))
constant_target(x::Float64) = ccall(Ptr{Cvoid}(UInt(0x1234)), Float64, (Float64,), x)
null_target(x::Float64) = ccall(Ptr{Cvoid}(UInt(0)), Float64, (Float64,), x)
no_cfunction(x::Float64, p::Ptr{Cvoid}) = ccall(p, Float64, (Float64,), x)
variadic(x::Float64) = ccall(@cfunction(add1, Float64, (Float64,)), Float64, (Float64, Float64...), x, x)
end

@testset "C function pointers" begin
    P = CFunctionPrograms
    cases = [(P.c_direct, (1.5,)), (P.c_scalars, (0.5,)), (P.c_select, (1, 4.0)), (P.c_select, (2, 4.0)),
             (P.c_notnull, (1.0,)), (P.c_copies, (1.0,)), (P.c_distinct, (1.0,)), (P.c_roundtrip, (1.0,)),
             (P.c_ref_of_bits, (1.5,)), (P.c_ref_into_array, (1.5,)), (P.c_write_through, (1.5,)),
             (P.c_object_ref, (1.5,)), (P.c_object_address, (1.5,)), (P.c_ref_result, (1.5,)),
             (P.c_any_result, (1.5,)), (P.c_void_result, (1.5,)),
             (P.fw_inline, (1.5, 2.0)), (P.fw_mutable, (3,)), (P.fw_closure, (1.5,)), (P.fw_captures, (2.0,)),
             (P.fw_two_types, (2.0,)), (P.fw_distinct_pointer, (2.0,)),
             (P.fw_bool, (2.0,)), (P.fw_convert_result, (1.0,)), (P.fw_convert_arg, (2.0,)),
             (P.fw_nothing_result, (1.5,)), (P.fw_singleton, (1.5,)), (P.fw_vectors, (0.25,)),
             (P.fw_aliased, (0.25,)), (P.fw_matrix, (1.5,)), (P.fw_vector_result, (1.0,)),
             (P.fw_any_result, (1.0,)), (P.fw_any_arg, (1.0,)), (P.fw_nested, (1.5,))]
    names = ["e$i" for i in eachindex(cases)]
    c = compile([Entry(f, typeof.(args); name) for ((f, args), name) in zip(cases, names)]; config = WasmCodegen.Config(verify = :off))
    for ((f, args), name) in zip(cases, names)
        expected = f(args...)
        @test wasm_run(c, name, args...; rettype = typeof(expected)) === expected
    end

    # one pointer for one function and signature (natively, one per compiled call site)
    c = compile(P.fw_same_pointer, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "fw_same_pointer", 2.0; rettype = Float64) === 7.0

    c = compile(P.fw_throw, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "fw_throw", 1.0; rettype = Float64) === 7.0
    @test wasm_run(c, "fw_throw", -1.0; rettype = Float64) === -1.0

    c = compile([Entry(P.img_inline, (Float64,)), Entry(P.img_mutable, (Int,)), Entry(P.img_closure, (Float64,)),
                 Entry(P.img_cycle, (Float64,))];
                config = WasmCodegen.Config(verify = :off, shell_first_mutables = true, pre_image_hooks = Any[P.null_image]))
    @test wasm_run(c, "img_inline", 1.5; rettype = Float64) === P.img_inline(1.5)
    @test wasm_run(c, "img_closure", 1.5; rettype = Float64) === P.img_closure(1.5)
    @test wasm_run(c, "img_cycle", 1.5; rettype = Float64) === P.img_cycle(1.5)
    @test wasm_run(c, "img_mutable", 3; rettype = Int) === 8

    # a wrapper of the image with its native pointers is refused
    @test_throws WasmCodegen.UnsupportedConstructs compile(P.img_inline, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test_throws WasmCodegen.UnsupportedConstructs compile(P.img_inline, (Float64,);
                                                           config = WasmCodegen.Config(verify = :off, shell_first_mutables = true))

    # a pointer that is not a function of the call's signature is an error of the program
    c = compile([Entry(P.catch_null, (Float64,)), Entry(P.catch_wrong, (Float64,))]; config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "catch_null", 1.0; rettype = Float64) === 11.0
    @test wasm_run(c, "catch_wrong", 1.0; rettype = Float64) === 11.0

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
    @test occursin("which no cfunction of the module has", report(P.no_cfunction, (Float64, Ptr{Cvoid})))
    @test occursin("which no cfunction of the module has", report(P.bad_call, (Float64,)))
    @test occursin("a variadic ccall", report(P.variadic, (Float64,)))
end
