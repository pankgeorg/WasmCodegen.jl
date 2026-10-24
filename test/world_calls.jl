# `invoke_in_world` / `invokelatest` of a constant callee as direct calls (`Config(direct_world_calls = true)`).
addw(a::Float64, b::Float64) = a + b
mulkw(a::Float64; k::Float64 = 2.0) = a * k
struct BoxedValue
    v::Float64
end
world_add(x::Float64) = Base.invoke_in_world(Base.get_world_counter(), addw, x, 1.5)::Float64
# inference does not type a world call, so the program asserts the result
world_kw(x::Float64) = Base.invoke_in_world(Base.get_world_counter(), mulkw, x; k = 3.0)::Float64
world_ctor(x::Float64) = (Base.invoke_in_world(Base.get_world_counter(), BoxedValue, x)::BoxedValue).v
latest_add(x::Float64) = Core._call_latest(addw, x, 2.5)::Float64
# a world passed in at run time
world_runtime(x::Float64, w::UInt) = Base.invoke_in_world(w, addw, x, 0.25)::Float64

const DIRECT = WasmCodegen.Config(direct_world_calls = true)

function world_test(f, args...)
    expected = Base.invokelatest(f, args...)
    c = WasmCodegen.compile(f, map(Core.Typeof, args); config = DIRECT)
    got = wasm_run(c, string(nameof(f)), args...; rettype = typeof(expected))
    @test got === expected
end

@testset "direct world calls" begin
    # off by default: the builtin stays unsupported
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(world_add, (Float64,); config = WasmCodegen.Config(verify = :off))
    world_test(world_add, 1.0)
    world_test(world_kw, 2.0)
    world_test(world_ctor, 4.5)
    world_test(latest_add, 1.0)
    world_test(world_runtime, 1.0, Base.get_world_counter())
end
