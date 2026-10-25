# FunctionWrappers with mutable objects created shell-first (`Config(funcref_wrappers = true,
# shell_first_mutables = true)`): a wrapper reached through a mutable object's field, whose wrapped
# closure captures that object. The module is compiled before the native call mutates the object, so a
# serialized copy instead of an alias returns the old value.
module FWShellFirst
    using FunctionWrappers: FunctionWrapper
    const W = FunctionWrapper{Float64, Tuple{Float64}}
    mutable struct Integ
        t::Float64
        cb::Any
    end
    const I = let i = Integ(0.0, nothing)
        i.cb = W(x -> x + i.t)
        i
    end
    run(x::Float64) = (I.t = x; (I.cb::W)(1.0))
    const FW0 = W(x -> 2x)
    direct(x::Float64) = FW0(x)
end

@testset "FunctionWrappers in shell-first mutable objects" begin
    config = WasmCodegen.Config(funcref_wrappers = true, shell_first_mutables = true)
    cases = [(FWShellFirst.run, 1.5), (FWShellFirst.direct, 2.5)]
    compiled = [WasmCodegen.compile(f, (Float64,); config) for (f, _) in cases]
    for ((f, x), c) in zip(cases, compiled)
        got = wasm_run(c, string(nameof(f)), x; rettype = Float64)
        @test got === Base.invokelatest(f, x)
    end
end
