# Config(inline_cap): a large @inline callee stays a call under a small cap and is inlined under a
# large one, the results are the same, and compilations with different caps do not share code.
using Test, WasmCodegen
isdefined(@__MODULE__, :wasm_run) || include(joinpath(@__DIR__, "harness.jl"))

@inline function big_kernel(x::Float64, n::Int)
    s = x
    Base.Cartesian.@nexprs 24 i -> (s = s * 1.0001 + sin(s + i); n > i && (s += cos(s * i)))
    return s
end
cap_probe(x::Float64, n::Int) = big_kernel(x, n) + big_kernel(x + 1.0, n - 1)
# a new caller of the same callee, compiled after it is cached
cap_probe2(x::Float64, n::Int) = 2.0 * big_kernel(x - 1.0, n)

# (the cap needs Julia 1.13's inlining policy)
VERSION >= v"1.13-" && @testset "inline_cap" begin
    WasmCodegen.with_trim_patches() do _, w
        entries = [WasmCodegen.Entry(cap_probe, (Float64, Int))]
        uncapped = WasmCodegen.compile(entries; world=w, validate=false, config=WasmCodegen.Config(verify=:off))
        capped = WasmCodegen.compile(entries; world=w, validate=false, config=WasmCodegen.Config(verify=:off, inline_cap=50))
        again = WasmCodegen.compile(entries; world=w, validate=false, config=WasmCodegen.Config(verify=:off))
        # the callee is a function of its own only under the cap
        has_kernel(c) = any(mi -> mi.def isa Method && mi.def.name === :big_kernel, c.world.order)
        @test !has_kernel(uncapped)
        @test has_kernel(capped)
        # the uncapped compilation after the capped one is unchanged (separate cache owners)
        @test again.bytes == uncapped.bytes
        # a cap above the callee's size inlines it, in its own cache: positive caps do not share code
        loose = WasmCodegen.compile(entries; world=w, validate=false, config=WasmCodegen.Config(verify=:off, inline_cap=100_000))
        @test !has_kernel(loose)
        @test has_kernel(WasmCodegen.compile(entries; world=w, validate=false, config=WasmCodegen.Config(verify=:off, inline_cap=50)))
        # a new caller of the callee cached (compressed) by the compilations above is capped too
        capped2 = WasmCodegen.compile([WasmCodegen.Entry(cap_probe2, (Float64, Int))]; world=w, validate=false,
                                      config=WasmCodegen.Config(verify=:off, inline_cap=50))
        @test has_kernel(capped2)
        @test wasm_run(capped2, "cap_probe2", 0.3, 7; rettype=Float64) === cap_probe2(0.3, 7)
        @test capped.world.inline_cap == 50
        # the same results, natively and in both modules (no muladd: natively it may fuse)
        for (x, n) in ((0.3, 0), (0.3, 7), (-2.5, 30))
            want = cap_probe(x, n)
            a = wasm_run(uncapped, "cap_probe", x, n; rettype=Float64)
            b = wasm_run(capped, "cap_probe", x, n; rettype=Float64)
            @test a === b
            @test a === want
        end
    end
end
