# The bundled trim patch overrides `throw_eachindex_mismatch_indices` with Julia 1.13's
# signature `(indices_str, inds...)` too, so multi-array `eachindex` passes strict verification.
function sum4(n::Int)
    a = collect(1.0:n); b = 2a; c = 3a; d = 4a
    s = 0.0
    @inbounds for i in eachindex(a, b, c, d)
        s += a[i] * b[i] + c[i] - d[i]
    end
    return s
end

@testset "eachindex mismatch thrower under the trim patches" begin
    WasmCodegen.with_trim_patches() do _, w
        @test hasmethod(Base.throw_eachindex_mismatch_indices, Tuple{String, Base.OneTo{Int}, Base.OneTo{Int}}; world = w)
        msg = sprint(showerror, try
            Base.invoke_in_world(w, Base.throw_eachindex_mismatch_indices, "indices", 1:2, 1:3, 1:4)
        catch e
            e
        end)
        @test occursin("all inputs to eachindex must have the same indices", msg)
        c = WasmCodegen.compile(sum4, (Int,); world = w, config = WasmCodegen.Config(verify = :error))
        @test wasm_run(c, "sum4", 10; rettype = Float64) === sum4(10)
    end
end
