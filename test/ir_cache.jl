# The structured-IR cache (`Config(ir_cache = true)`): the same module with and without it, the second
# compilation served from the cache, and the module still correct.
cache_prog(x::Float64) = sum(sin(x + i) * cos(i * x) for i in 1:5) + (x > 1 ? x^2 : -x)

@testset "structured-IR cache" begin
    WasmCodegen.empty_ir_cache!()
    cfg(c) = WasmCodegen.Config(optimize = nothing, ir_cache = c)
    plain = WasmCodegen.compile(cache_prog, (Float64,); config = cfg(false))
    @test WasmCodegen.ir_cache_stats().entries == 0          # off: nothing kept
    filled = WasmCodegen.compile(cache_prog, (Float64,); config = cfg(true))
    s1 = WasmCodegen.ir_cache_stats()
    @test s1.misses > 0 && s1.hits == 0 && s1.entries == s1.misses
    reused = WasmCodegen.compile(cache_prog, (Float64,); config = cfg(true))
    s2 = WasmCodegen.ir_cache_stats()
    @test s2.hits == s1.misses && s2.misses == s1.misses       # every function from the cache
    @test filled.bytes == plain.bytes && reused.bytes == plain.bytes
    for x in (0.5, 2.0)
        @test wasm_run(reused, "cache_prog", x; rettype = Float64) === cache_prog(x)
    end
    WasmCodegen.empty_ir_cache!()
    @test WasmCodegen.ir_cache_stats().entries == 0 && WasmCodegen.ir_cache_stats().hits == 0
end
