# Object graphs in the image: runtime objects held but not read.

# a CodeInstance kept next to compiled code in a mutable build record, never read; and its
# MethodInstance and Method, held the same way
module HoldsCodeInstance
    g(x) = x + 1
    g(1)
    const MI = first(Base.method_instances(g, Tuple{Int}, Base.get_world_counter()))
    const CI0 = MI.cache
    mutable struct Record
        ci::Any
        k::Float64
    end
    const REC = Record(CI0, 2.0)
    run(x::Float64) = x * REC.k
    same(x::Float64) = REC.ci === CI0 ? x : -x
    probe(x::Float64) = isdefined(REC.ci::Core.CodeInstance, :inferred) ? x : -x
    const M = MI.def
    mutable struct Defs
        mi::Any
        m::Any
    end
    const DEFS = Defs(MI, M)
    defs(x::Float64) = DEFS.mi === MI && DEFS.m === M ? x : -x
    kinds(x::Float64) = typeof(DEFS.mi) === Core.MethodInstance && typeof(DEFS.m) === Method &&
                        typeof(REC.ci) === Core.CodeInstance ? x : -x
    probe_mi(x::Float64) = isdefined(DEFS.mi::Core.MethodInstance, :cache) ? x : -x
end

@testset "runtime objects held by the image" begin
    @wtest HoldsCodeInstance.run(1.5)
    @wtest HoldsCodeInstance.same(2.0)
    @wtest HoldsCodeInstance.defs(3.0)
    @wtest HoldsCodeInstance.kinds(4.0)
    # no fields are serialized, so their definedness is not known
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(HoldsCodeInstance.probe, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(HoldsCodeInstance.probe_mi, (Float64,); config = WasmCodegen.Config(verify = :off))
end
