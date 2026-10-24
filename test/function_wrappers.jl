# FunctionWrappers through typed function references (`Config(funcref_wrappers = true)`): wrappers built
# at compile time and serialized, and wrappers built at run time; by-value arguments and results.
using FunctionWrappers: FunctionWrapper

struct Scale
    c::Float64
end
(s::Scale)(x::Float64) = s.c * x + 1.0
const FWS = FunctionWrapper{Float64, Tuple{Float64}}(Scale(2.0))
fw_const(x::Float64) = FWS(x)
function fw_runtime(x::Float64, c::Float64)
    fw = FunctionWrapper{Float64, Tuple{Float64}}(Scale(c))
    return fw(x) + fw(2x)
end
const ACC = Ref(0.0)
const FWN = FunctionWrapper{Nothing, Tuple{Float64, Int}}((x, k) -> (ACC[] += k * x; nothing))
function fw_nothing(x::Float64)
    ACC[] = 0.0
    FWN(x, 1)
    FWN(x, 3)
    return ACC[]
end
# wrappers of one signature over different object types side by side
const FWV = [FunctionWrapper{Float64, Tuple{Float64}}(Scale(3.0)), FunctionWrapper{Float64, Tuple{Float64}}(x -> x - 1.0)]
fw_vector(x::Float64) = FWV[1](x) + FWV[2](x)
fw_bool(x::Float64) = FunctionWrapper{Bool, Tuple{Float64, Float64}}(>)(x, 1.0)
# a singleton argument (FunctionWrappers passes it as `Ref{T}` in the cfunction, `Any` in the ccall),
# e.g. `FunctionWrapper{Float64, Tuple{Float64, SciMLBase.NullParameters}}`
struct NoParams end
struct Shift
    c::Float64
end
(s::Shift)(x::Float64, ::NoParams) = x - s.c
const FWG = FunctionWrapper{Float64, Tuple{Float64, NoParams}}(Shift(0.25))
fw_singleton_const(x::Float64) = FWG(x, NoParams())
fw_singleton(x::Float64) = FWG(x, NoParams()) + FunctionWrapper{Float64, Tuple{Float64, NoParams}}(Shift(x))(2x, NoParams())

const FWC = WasmCodegen.Config(funcref_wrappers = true)

const DUMP = get(ENV, "WCG_TEST_DUMP", "")
function fwrapper_test(f, args...)
    expected = Base.invokelatest(f, args...)
    c = WasmCodegen.compile(f, map(Core.Typeof, args); config = FWC, validate = isempty(DUMP))
    if !isempty(DUMP)
        mkpath(DUMP); write(joinpath(DUMP, string(nameof(f), ".wasm")), c.bytes)
        WasmBuilder.validate(c.bytes)
    end
    got = wasm_run(c, string(nameof(f)), args...; rettype = typeof(expected))
    @test got === expected
end

@testset "FunctionWrappers as funcrefs" begin
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(fw_const, (Float64,); config = WasmCodegen.Config(verify = :off))
    fwrapper_test(fw_const, 1.5)
    fwrapper_test(fw_runtime, 1.5, 4.0)
    fwrapper_test(fw_nothing, 2.5)
    fwrapper_test(fw_vector, 5.0)
    fwrapper_test(fw_bool, 2.0)
    fwrapper_test(fw_bool, 0.5)
    fwrapper_test(fw_singleton_const, 1.5)
    # natively on Julia 1.13 a wrapper built and called in one function can return a wrong value
    # (JuliaLang/FunctionWrappers.jl#36), so the module is compared with the unwrapped calls
    c = WasmCodegen.compile(fw_singleton, (Float64,); config = FWC, validate = isempty(DUMP))
    @test wasm_run(c, "fw_singleton", 1.5; rettype = Float64) === Shift(0.25)(1.5, NoParams()) + Shift(1.5)(3.0, NoParams())
end
