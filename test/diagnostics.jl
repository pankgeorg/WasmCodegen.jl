# Diagnostics of unsupported constructs stay bounded when the code has values and types of
# deeply nested parametric types: recording them and printing the report are cut off.
module BoundedDiagnostics
struct W{A,B} end
nest(T, k) = k == 0 ? T : (S = nest(T, k - 1); W{S,S})
big() = nest(Int, 18)   # printed in full: 2.6 MB (no const binding: not printed as an alias)
const WRAP = Ref{Any}(W)   # a wrapper not known at compile time: `apply_type` stays unsupported
apply_dynamic(x) = WRAP[]{typeof(x), 1}
id(x) = x
wherearg(x::T) where T = x
loop(n::Int) = (s = 0; for k in 1:n; s += k; end; s)
import WasmCodegen
# the allocations of `f(args...)` in the world the code generator runs in (juliac's patches,
# which print a type by rendering it whole, are after it)
function allocated(f, args...)
    run() = Base.invoke_in_world(WasmCodegen.COMPILER_WORLD[], f, args...)
    run()
    return @allocated run()
end
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

    # method and code instances in a statement: printed as `show` prints them, rendering no more
    # of their signatures than is printed
    B.id(1)
    small = instance(B.id, Int)
    m = only(methods(B.wherearg))
    unspecialized = Base.specialize_method(m, m.sig, Core.svec())
    @test WasmCodegen.diagnostic_string(unspecialized) == sprint(show, unspecialized) ==
          "MethodInstance for $(B).wherearg(::T) where T"
    for x in (small, small.cache, unspecialized)
        stmt = Expr(:invoke, x, Core.Argument(2))
        @test WasmCodegen.diagnostic_statement(stmt, Int) == sprint(show, stmt) * "::Int64"
        # (and quoted, a constant operand)
        stmt = Expr(:call, Core.Argument(1), QuoteNode(x))
        @test WasmCodegen.diagnostic_statement(stmt, Int) == sprint(show, stmt) * "::Int64"
    end
    # the work of rendering, as allocations: `show` of the statement renders the whole 2.6 MB
    # signature in a buffer first; its diagnostic, no more than it prints
    stmt = Expr(:invoke, instance(B.id, B.big()), Core.Argument(2))
    @test B.allocated(WasmCodegen.limited_sprint, show, stmt) > 2_000_000
    @test B.allocated(WasmCodegen.diagnostic_statement, stmt, Int) < 200_000
    @test B.allocated(WasmCodegen.diagnostic_string, instance(B.id, B.big())) < 200_000
    stmt = Expr(:call, Core.Argument(1), QuoteNode(instance(B.id, B.big())))
    @test B.allocated(WasmCodegen.limited_sprint, show, stmt) > 2_000_000
    @test B.allocated(WasmCodegen.diagnostic_statement, stmt, Int) < 200_000

    # an error of the structurizer
    ir = Base.code_ircode(B.loop, (Int,))[1][1]
    k = findfirst(x -> x isa Core.GotoNode, ir.stmts.stmt)
    ir.stmts.stmt[k] = Core.GotoNode(999)
    err = try WasmCodegen.structurize_or_unsupported(ir) catch e; e end
    @test err isa WasmCodegen.Unsupported
    @test startswith(sprint(showerror, err), "WasmCodegen: unsupported: structurizing the IR: BoundsError")

    # the result of a statement that cannot be converted to its type, in a statement with an
    # instance of a huge signature
    c = WasmCodegen.compile(B.loop, (Int,); config = test_config(optimize = nothing))
    info = c.cgm.funcs[instance(B.loop, Int)]
    fc = WasmCodegen.FnCtx(c.cgm, info, nothing, WasmBuilder.Builder(c.cgm.mod, info.func))
    stmt = Expr(:invoke, instance(B.id, B.big()), Core.Argument(2))
    err = try
        WasmCodegen.convert_result(fc, WasmCodegen.ghost(Tuple{Nothing}, (nothing,)), stmt, Tuple{Union{Nothing,Int}})
    catch e
        e
    end
    @test err isa WasmCodegen.Unsupported
    msg = sprint(showerror, err)
    @test occursin("a conversion from Tuple{Nothing} to Tuple{Union{Nothing, Int64}}", msg)
    @test occursin("in the result of :(\$(Expr(:invoke, MethodInstance for ", msg) && occursin("id(::", msg)
    @test sizeof(msg) < 3maxlen
end
