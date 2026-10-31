# `@invokelatest` of a constant global (trim/wasm-invokelatest.jl): a direct call, so it compiles
# with trim = :safe; with keyword arguments too.

il_target(x::Int) = 2x + 1
il_target_kw(x::Int; k::Int = 0) = x * 10 + k
il_call(n::Int) = Base.@invokelatest il_target(n)
il_call_kw(n::Int) = Base.@invokelatest(il_target_kw(n; k = 3)) + Base.@invokelatest(il_target_kw(n))

@testset "@invokelatest of constant globals" begin
    @test il_call(4) == 9  # (natively, through Base's or the patch's: the same)
    @wtest il_call(4)
    @wtest il_call_kw(5)
end
