# The build's root task in the image, and large sparse memories of references.
#
# A value of the image may refer to the build process's root task: the key of a per-task cache
# (a `WeakKeyDict{Task}` keyed by the task that filled it), a `WeakRef`. A native image refers
# to the loading process's root task there (src/staticdata.c, `TagRef` 0), without serializing
# the build's task or its task-local storage; so does the module: to its own root task.
#
# A memory of references larger than `MAX_FIXED_ELEMENTS` is filled by the start function: only
# its non-null slots (a hash table's unused slots are null).

module RootTaskImage
    # a per-task cache, as a struct holds it, keyed by the root task: only `k` is read
    struct Model
        k::Float64
        cache::WeakKeyDict{Task,Vector{Int}}
    end
    const M = Model(2.0, WeakKeyDict{Task,Vector{Int}}())
    M.cache[Base.roottask] = [1, 2, 3]
    # the root task's task-local storage, at build time: a large table, mostly unused, which
    # the program never reads (natively, a package image does not carry it either)
    let t = Base.roottask
        t.storage === nothing && (t.storage = IdDict{Any,Any}())
        t.storage[:wasmcodegen_test_root_task] = sizehint!(Dict{Symbol,Any}(), 2^17)
    end
    const W = WeakRef(Base.roottask)
    # held as a mutable object holds it (an integrator its problem): serialized whole
    const R = Ref(M)
    run(x::Float64) = R[].k * x
    # the weak reference and the binding refer to one task, the module's root task
    weak(x::Float64) = W.value isa Task ? x : -x
    same(x::Float64) = W.value === Base.roottask ? x : -x
    keyed(x::Float64) = (ks = M.cache.ht.keys;
                         any(i -> isassigned(ks, i) && ks[i].value === Base.roottask, eachindex(ks))) ? x : -x
    # the module's code runs in its root task
    inroot(x::Float64) = (t = current_task(); t === Base.roottask && t === W.value) ? x : -x
end

module SparseImage
    # a large hash table with two entries (its slots: 2^17)
    const T = sizehint!(Dict{Symbol,Any}(), 2^17)
    T[:a] = 1.5
    T[:b] = "b"
    lookup(x::Float64) = T[:a]::Float64 * x + length(T[:b]::String)
    # a large memory of references, unassigned but for a few elements, one of them a cycle back
    # to it (set by the start function after the memory exists)
    mutable struct Node
        v::Vector{Any}
    end
    const V = Vector{Any}(undef, 20_000)
    V[7] = Node(V)
    V[19_999] = 2.5
    V[20_000] = nothing
    assigned(i::Int) = count(j -> isassigned(V, j), 1:length(V)) * 1000 + (isassigned(V, i) ? 1 : 0)
    cycle(i::Int) = ((V[7]::Node).v === V && V[20_000] === nothing) ? V[19_999]::Float64 * i : -1.0
    # elements of two references each (stride 2), a few set, one of them a cycle back to the memory
    mutable struct Pairs
        v::Vector{Tuple{Any,Any}}
    end
    const P = Vector{Tuple{Any,Any}}(undef, 20_000)
    P[3] = (Pairs(P), 1.5)
    P[19_000] = (:x, "y")
    pairs(i::Int) = ((P[3][1]::Pairs).v === P && P[19_000][1] === :x && (P[19_000][2]::String) == "y" && !isassigned(P, i)) ? (P[3][2]::Float64) * i : -1.0
end

module OtherTask
    # a task of the build other than its root task: natively, "Task cannot be serialized"
    const T = Task(() -> 1)
    held(x::Float64) = T.result === nothing ? x : -x
end

# the image of a compilation: its Tasks, and the start function's instructions
image_tasks(c) = count(o -> o isa Task, keys(c.cgm.image.globals)) + count(o -> o isa Task, keys(c.cgm.image.boxes))
start_insts(c) = c.cgm.mod.start === nothing ? 0 : length(c.cgm.mod.start.body)

# (before Julia 1.13, a WeakKeyDict's finalizer is a closure that captures it: a cycle through an
# immutable object, which only `shell_first_mutables` serializes)
const WKD_CONFIGS = VERSION >= v"1.13" ? (test_config(), test_config(; shell_first_mutables = true)) :
                                         (test_config(; shell_first_mutables = true),)

@testset "the build's root task in the image" begin
    @wtest RootTaskImage.weak(2.0)
    @wtest RootTaskImage.same(2.0)
    c = wcompile(RootTaskImage.inroot, (Float64,))
    @test wasm_run(c, "inroot", 2.0; rettype = Float64) == 2.0
    # the per-task cache, compared with native
    for f in (RootTaskImage.run, RootTaskImage.keyed), cfg in WKD_CONFIGS
        c = WasmCodegen.compile(f, (Float64,); config = cfg)
        @test wasm_run(c, string(nameof(f)), 1.5; rettype = Float64) == f(1.5)
    end
    # not serialized: the build's task, its task-local storage (2^18 slots at 4 instructions each)
    for (f, cfg) in ((RootTaskImage.run, last(WKD_CONFIGS)), (RootTaskImage.run, first(WKD_CONFIGS)),
                     (RootTaskImage.weak, test_config()),
                     (RootTaskImage.weak, test_config(; shell_first_mutables = true)))
        c = WasmCodegen.compile(f, (Float64,); config = cfg)
        @test image_tasks(c) == 0
        @test start_insts(c) < 10_000
        @test length(c.bytes) < 200_000
        @test wasm_run(c, string(nameof(f)), 1.5; rettype = Float64) == f(1.5)
    end
end

@testset "large sparse memories of references" begin
    @wtest SparseImage.lookup(2.0)
    @wtest SparseImage.assigned(7)
    @wtest SparseImage.assigned(8)
    @wtest SparseImage.cycle(3)
    c = wcompile(SparseImage.lookup, (Float64,))
    @test start_insts(c) < 10_000
    c = WasmCodegen.compile(SparseImage.cycle, (Int,); config = test_config(; shell_first_mutables = true))
    @test start_insts(c) < 10_000
    @test wasm_run(c, "cycle", 3; rettype = Float64) == SparseImage.cycle(3)
    @wtest SparseImage.pairs(4)
    c = WasmCodegen.compile(SparseImage.pairs, (Int,); config = test_config(; shell_first_mutables = true))
    @test start_insts(c) < 10_000
    @test wasm_run(c, "pairs", 4; rettype = Float64) == SparseImage.pairs(4)
end

@testset "a task of the build other than its root task" begin
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(OtherTask.held, (Float64,); config = test_config())
end

# (the build's root task's storage, as it was)
delete!(Base.roottask.storage::IdDict{Any,Any}, :wasmcodegen_test_root_task)
