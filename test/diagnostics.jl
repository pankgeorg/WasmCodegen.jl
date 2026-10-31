# Diagnostics of unsupported constructs stay bounded when the code has values and types of
# deeply nested parametric types: recording them and printing the report are cut off.
module BoundedDiagnostics
struct W{A,B} end
nest(T, k) = k == 0 ? T : (S = nest(T, k - 1); W{S,S})
big() = nest(Int, 18)   # printed in full: 2.6 MB (no const binding: not printed as an alias)
const SINK = Ref{Any}(1)
apply_dynamic(x) = W{typeof(x), SINK[]}
end

@testset "bounded diagnostics" begin
    B = BoundedDiagnostics
    maxlen = WasmCodegen.DIAGNOSTIC_MAXLEN
    @test WasmCodegen.limited_sprint(print, "abc") == "abc"
    s = WasmCodegen.limited_sprint(show, B.big())
    @test occursin("W{W{W{", s) && endswith(s, "…") && sizeof(s) <= maxlen + sizeof("…")
    @test WasmCodegen.limited_sprint(print, "αβγ"; maxlen = 3) == "α…"
    instance(f, argtypes...) = Base.specialize_method(which(f, argtypes), Tuple{typeof(f), argtypes...}, Core.svec())
    s = WasmCodegen.diagnostic_string("in ", instance(B.apply_dynamic, B.big()))
    @test startswith(s, "in MethodInstance for ") && occursin("apply_dynamic(::", s)
    @test endswith(s, "…") && sizeof(s) <= maxlen + sizeof("…")
    # printed as `show` prints them
    for mi in (instance(B.nest, Type{Int}, Int), instance(sum, Vector{Int}), instance(Iterators.reverse, Vector{Int}))
        @test WasmCodegen.diagnostic_string(mi) == sprint(show, mi)
    end

    c = WasmCodegen.compile(B.apply_dynamic, (B.big(),); config = test_config(trim = :unsafe, optimize = nothing))
    @test length(c.cgm.diagnostics) == 1
    err = only(c.cgm.diagnostics).second
    @test all(x -> !(x isa AbstractString) || sizeof(x) < 3maxlen, err.context)
    msg = sprint(showerror, err)
    @test occursin("apply_type of types not known", msg) && occursin("the statement", msg)
    @test sizeof(msg) < 10maxlen

    report = try
        WasmCodegen.compile(B.apply_dynamic, (B.big(),); config = test_config(optimize = nothing))
        ""
    catch e
        e isa WasmCodegen.UnsupportedConstructs || rethrow()
        sprint(showerror, e)
    end
    @test startswith(report, "1 unsupported constructs (1 distinct):")
    @test occursin("apply_type of types not known", report) &&
          occursin(r"in MethodInstance for \S*apply_dynamic\(::", report)
    @test sizeof(report) < 10maxlen
end
