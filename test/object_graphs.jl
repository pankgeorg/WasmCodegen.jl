# Object graphs in the image: runtime objects held but not read, and cycles through closures and
# immutable objects (`Config(shell_first_mutables = true)`). Each module is compiled before any native
# call mutates it, so a serialized copy instead of an alias returns the old value.

# a CodeInstance kept next to compiled code in a mutable build record, never read
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
end

@testset "runtime objects held by the image" begin
    @wtest HoldsCodeInstance.run(1.5)
    @wtest HoldsCodeInstance.same(2.0)
    # no fields are serialized, so their definedness is not known
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(HoldsCodeInstance.probe, (Float64,); config = WasmCodegen.Config(verify = :off))
end

# a mutable object reached again through a closure it holds (an integrator holding a callback whose
# closure captures the integrator)
module ClosureCycle
    mutable struct Integ
        t::Float64
        cb::Any
    end
    const I = let i = Integ(0.0, nothing)
        i.cb = () -> i.t + 1.0
        i
    end
    const CB = typeof(I.cb)
    run(x::Float64) = (I.t = x; (I.cb::CB)())
end

# the same cycle through an immutable callable struct
module StructCycle
    mutable struct Integ{F}
        t::Float64
        f::F
    end
    struct Step{T}
        i::T
    end
    (s::Step)() = s.i.t + 1.0
    const I = let i = Integ{Any}(0.0, nothing)
        i.f = Step(i)
        i
    end
    run(x::Float64) = (I.t = x; (I.f::Step{Integ{Any}})())
end

# a mutable object reached again through an inline value of several leaves held in one of its fields
# (the field is set leaf by leaf by the start function)
module InlineCycle
    mutable struct Ring
        w::Tuple{Ring, Float64}
        v::Float64
        Ring(v::Float64) = (r = new(); r.v = v; r)
    end
    const R = let r = Ring(2.5); r.w = (r, 4.0); r end
    read(x::Float64) = R.w[1].v + R.w[2] * x
    write(x::Float64) = (R.v = x; R.w[1].v)
end

# an immutable value reached only through deferred fields of a mutable object, hashed through the
# run-time `objectid` dispatch: its type is first seen while the deferred values are prepared, and
# still needs its objectid case
module DeferredHash
    struct Key
        a::Int
        b::Float64
    end
    mutable struct Box
        k1::Any
        k2::Any
        self::Any
    end
    const B = let b = Box(Key(3, 1.5), Key(3, 1.5), nothing); b.self = b; b end
    same(x::Float64) = objectid((B.self::Box).k1) === objectid(B.k2) ? x : -x
end

# a deferred field value that cannot be serialized (a `TypeVar`), directly and in a nested object
# reached through a deferred field, from a constant and from a global variable
module DeferredFailure
    mutable struct Rec
        p::Any
        k::Float64
        self::Any
    end
    const REC = let r = Rec(TypeVar(:T), 2.0, nothing); r.self = r; r end
    read(x::Float64) = x * (REC.self::Rec).k
    read2(x::Float64) = x + (REC.self::Rec).k
    const OUTER = let r = Rec(nothing, 3.0, nothing); r.self = Rec(TypeVar(:S), 0.5, r); r end
    nested(x::Float64) = x * OUTER.k
    VAR::Rec = Rec(TypeVar(:U), 4.0, nothing)
    fromvar(x::Float64) = x * VAR.k
    # such an object reached through a boxed tuple, and through a global variable, from two functions each
    const TUP = (Rec(TypeVar(:V), 5.0, nothing), 1.0)
    const SINK3 = Any[nothing]
    const SINK4 = Any[nothing]
    boxed3(x::Float64) = (SINK3[1] = TUP; x)
    boxed4(x::Float64) = (SINK4[1] = TUP; x)
    VAR2::Rec = Rec(TypeVar(:W), 6.0, nothing)
    var3(x::Float64) = x * VAR2.k
    var4(x::Float64) = x + VAR2.k
end

const SHELL_FIRST = WasmCodegen.Config(shell_first_mutables = true)

@testset "cycles through closures and immutable objects" begin
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(ClosureCycle.run, (Float64,); config = WasmCodegen.Config(verify = :off))
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(InlineCycle.read, (Float64,); config = WasmCodegen.Config(verify = :off))
    # compiled first: the serialized state is the initial one, so an alias is needed to see the new value
    cases = [(ClosureCycle.run, 1.5), (StructCycle.run, 2.5), (InlineCycle.read, 1.5), (InlineCycle.write, 7.0),
             (DeferredHash.same, 2.0)]
    compiled = [WasmCodegen.compile(f, (Float64,); config = SHELL_FIRST) for (f, _) in cases]
    for ((f, x), c) in zip(cases, compiled)
        got = wasm_run(c, string(nameof(f)), x; rettype = Float64)
        expected = Base.invokelatest(f, x)
        @test got === expected
    end
end

@testset "a deferred value that cannot be serialized" begin
    for f in (DeferredFailure.read, DeferredFailure.nested, DeferredFailure.fromvar)
        # an error of the function that reached the object
        @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(f, (Float64,);
            config = WasmCodegen.Config(shell_first_mutables = true, verify = :off))
        # with trim = :unsafe: that function's diagnostic, and the start function traps
        c = WasmCodegen.compile(f, (Float64,);
            config = WasmCodegen.Config(shell_first_mutables = true, trim = :unsafe, verify = :off))
        @test any(d -> d.first.def.name === nameof(f), c.cgm.diagnostics)
        err = try wasm_run(c, string(nameof(f)), 1.5; rettype = Float64); nothing catch e; e end
        @test err isa ErrorException && occursin("unreachable", err.msg)
    end
end

# a function emitted as an optional one (as the objectid cases are) that reaches the object first:
# only it traps, unless a program function reached the object too
@testset "a deferred value that an optional function reached" begin
    W = WasmCodegen
    config = W.Config(shell_first_mutables = true, trim = :unsafe, verify = :off)
    world = Base.get_world_counter()
    D = DeferredFailure
    # the second function reaches the object directly, through the cached box, or through the global variable
    for (fopt, fprog) in ((D.read, D.read2), (D.boxed3, D.boxed4), (D.var3, D.var4)), program_too in (false, true)
        mis = [W.entry_instance(f, (Float64,); world) for f in (fopt, fprog)]
        cgm = W.CGModule(W.collect_world(mis; world, verify = :off), config)
        cgm.image.optional_mode = true
        opt = W.get_function!(cgm, mis[1])
        W.process_worklist!(cgm)
        cgm.image.optional_mode = false
        program_too && W.get_function!(cgm, mis[2])
        W.process_worklist!(cgm)
        while W.prepare_image_patches!(cgm) || !isempty(cgm.worklist)
            W.process_worklist!(cgm)
        end
        @test opt in cgm.image.failed_owners
        @test cgm.image.failed == program_too
        @test any(d -> d.first === mis[2], cgm.diagnostics) == program_too
        @test !any(d -> d.first === mis[1], cgm.diagnostics)
    end
    # a function first needed while an optional function's values are serialized is optional too
    mis = [W.entry_instance(f, (Float64,); world) for f in (D.read, D.fromvar)]
    cgm = W.CGModule(W.collect_world(mis; world, verify = :off), config)
    cgm.image.optional_mode = true
    opt = W.get_function!(cgm, mis[1])
    W.process_worklist!(cgm)
    cgm.image.optional_mode = false
    queued = W.with_image_owner(() -> W.get_function!(cgm, mis[2]), cgm.image, opt)
    W.process_worklist!(cgm)
    while W.prepare_image_patches!(cgm) || !isempty(cgm.worklist)
        W.process_worklist!(cgm)
    end
    @test queued in cgm.image.optional
    @test queued in cgm.image.failed_owners
    @test !cgm.image.failed
    @test isempty(cgm.diagnostics)
end
