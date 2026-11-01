# C function pointers, and FunctionWrappers built on them with no code of its own in the compiler.
using FunctionWrappers: FunctionWrapper
import FunctionWrappers

add1(x::Float64) = x + 1.0
twice(x::Int32, y::Float64) = 2.0 * x + y
cf_direct(x::Float64) = ccall(@cfunction(add1, Float64, (Float64,)), Float64, (Float64,), x)
cf_two(x::Float64) = ccall(@cfunction(twice, Float64, (Int32, Float64)), Float64, (Int32, Float64), Int32(3), x)
function cf_select(i::Int, x::Float64)
    p = i == 1 ? @cfunction(add1, Float64, (Float64,)) : @cfunction(sqrt, Float64, (Float64,))
    return ccall(p, Float64, (Float64,), x)
end
cf_null(x::Float64) = @cfunction(add1, Float64, (Float64,)) != C_NULL ? x : -x

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
fw_bool(x::Float64) = FunctionWrapper{Bool, Tuple{Float64, Float64}}(>)(x, 1.0)

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
function fw_two_types(x::Float64)
    ws = [FunctionWrapper{Float64, Tuple{Float64}}(Scale(3.0)), FunctionWrapper{Float64, Tuple{Float64}}(y -> y - 1.0)]
    return ws[1](x) + ws[2](x)
end
fw_vector_result(x::Float64) = FunctionWrapper{Vector{Float64}, Tuple{Float64}}(y -> [y, y + 1])(x)[2]
fw_any(x::Float64) = FunctionWrapper{Any, Tuple{Float64}}(y -> y + 1)(x)::Float64

# a wrapper of the image: its pointers are null there, and the program sets them
const IMG = FunctionWrapper{Float64, Tuple{Float64}}(Scale(2.0))
function set_wrapper!(w::FunctionWrapper{Ret, Args}, ::Type{T}) where {Ret, Args, T}
    w.ptr = FunctionWrappers.gen_fptr(Ret, Args, T)
    w.objptr = Base.unsafe_convert(Ref{T}, w.obj::Base.RefValue{T})
    return nothing
end
fw_image(x::Float64) = (set_wrapper!(IMG, Scale); IMG(x))
function null_img()
    p, o = IMG.ptr, IMG.objptr
    IMG.ptr = C_NULL; IMG.objptr = C_NULL
    return () -> (IMG.ptr = p; IMG.objptr = o; nothing)
end

# an exception crosses a C function pointer
fails(x::Float64) = x > 0.0 ? throw(DomainError(x)) : x
function fw_throw(x::Float64)
    w = FunctionWrapper{Float64, Tuple{Float64}}(fails)
    try
        return w(x)
    catch e
        return e isa DomainError ? 7.0 : 8.0
    end
end

@testset "C function pointers" begin
    for (f, args) in ((cf_direct, (1.5,)), (cf_two, (0.5,)), (cf_select, (1, 4.0)), (cf_select, (2, 4.0)),
                      (cf_null, (1.0,)), (fw_inline, (1.5, 2.0)), (fw_mutable, (3,)),
                      (fw_closure, (1.5,)), (fw_bool, (2.0,)), (fw_singleton, (1.5,)), (fw_vectors, (0.25,)),
                      (fw_two_types, (2.0,)), (fw_vector_result, (1.0,)), (fw_any, (1.0,)))
        c = compile(f, typeof.(args); config = WasmCodegen.Config(verify = :off))
        expected = f(args...)
        @test wasm_run(c, string(nameof(f)), args...; rettype = typeof(expected)) === expected
    end
    c = compile(fw_throw, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test wasm_run(c, "fw_throw", 1.0; rettype = Float64) === 7.0
    @test wasm_run(c, "fw_throw", -1.0; rettype = Float64) === -1.0
    c = compile(fw_image, (Float64,); config = WasmCodegen.Config(verify = :off, pre_image_hooks = Any[null_img]))
    @test wasm_run(c, "fw_image", 1.5; rettype = Float64) === fw_image(1.5)
end
