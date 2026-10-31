# The C runtime's and the C library's functions the runtime answers (`runtime_ccalls.jl`),
# through the Base APIs that reach them: CRC-32C, byte search from the end, Symbol
# comparison, gensym, Libc.rand, the GC's controls and statistics, threads, the floating-point
# environment, JLOptions, fields set by index (deepcopy).

# CRC-32C (`jl_crc32c`): of strings, byte vectors, integers (by reference), IO; Pkg's slugs
rt_crc_string(k::Int) = (s = ("hello, wasm", "a", "Pkg slug ✓")[k];
                          (Base._crc32c(s), Base._crc32c(SubString(s, 2)), Base._crc32c(s, 0x12345678)))
rt_crc_bytes(n::Int) = (v = UInt8[(i * 37) % 256 for i in 1:n]; (Base._crc32c(v), Base._crc32c(view(v, 3:n))))
rt_crc_ints(x::UInt64) = (Base._crc32c(x), Base._crc32c(x % UInt32), Base._crc32c(UInt128(x) << 3), Base._crc32c(x % UInt8))
rt_crc_io(n::Int) = (io = IOBuffer(); for i in 1:n; write(io, UInt8(i % 251)); end; seekstart(io); Base._crc32c(io))
rt_slug(x::UInt64) = Base.version_slug(Base.UUID(UInt128(x) * 0x9e3779b97f4a7c15), Base.SHA1(UInt8[(i * x) % 256 for i in 1:20]))
rt_slug_len(x::UInt64) = (s = rt_slug(x); (length(s), codeunit(s, 1), codeunit(s, 5), hash(s)))

# memrchr: search for a byte or an ASCII character from the end
rt_findlast(n::Int) = (s = repeat("ab/cd", n); (something(findlast('/', s), -1), something(findprev('/', s, 7), -1),
                                                 something(findlast(==(0x62), codeunits(s)), -1),
                                                 first(something(findlast("b/", s), 0:0)), something(findlast('x', s), -1)))
rt_findprev_bytes(n::Int) = (v = UInt8[i % 10 for i in 1:n]; (something(findprev(==(0x00), v, n), -1),
                             something(findlast(iszero, v), -1), something(findprev(isequal(0x03), v, 2), -1)))

# strcmp: comparison and sorting of symbols
rt_symcmp(n::Int) = (cmp(:abc, :abd), cmp(:b, :a), cmp(:same, :same), isless(:a, :ab),
                     hash(sort([Symbol("s", i % 7, "_", i) for i in 1:n])))

# gensym: `##n` and `##tag#n`, distinct (the counter's value differs from native)
function rt_gensym(n::Int)
    a, b, t, u = gensym(), gensym(), gensym("tag"), gensym(:sym)
    sa, st, su = String(a), String(t), String(u)
    return (a !== b, startswith(sa, "##"), all(isdigit, sa[3:end]), startswith(st, "##tag#"),
            all(isdigit, st[7:end]), startswith(su, "##sym#"), length(unique([gensym() for _ in 1:n])))
end

# gensyms of the build process held by the image are never repeated by the module's
const RT_IMAGE_GENSYMS = [gensym("rt"), gensym("rt"), gensym(), gensym()]
function rt_gensym_image(n::Int)
    clash = false
    for _ in 1:n
        a, b = gensym("rt"), gensym()
        clash |= any(s -> s === a || s === b, RT_IMAGE_GENSYMS)
    end
    return clash
end

# a gensym made while compiling (a generated function's, inferred in the compilation)
@generated rt_late_gensym_gen(x) = QuoteNode(gensym("late"))
rt_gensym_late(n::Int) = (s = rt_late_gensym_gen(n); any(_ -> gensym("late") === s, 1:n))

# jl_set_nth_field out of range: a BoundsError, as natively
mutable struct RTR4; x::Int; y::String; end
rt_set_nth(i::UInt) = (r = RTR4(1, "a"); ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), r, i, 7); r.x)
mutable struct RTEmpty; end
function rt_set_nth_caught(i::UInt, empty::Bool)
    try
        if empty
            ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), RTEmpty(), i, 7)
        else
            ccall(:jl_set_nth_field, Cvoid, (Any, Csize_t, Any), RTR4(1, "a"), i, 7)
        end
        return (false, -100)
    catch e
        return (e isa BoundsError, e isa BoundsError ? (e.i::Int) : -1)
    end
end

# the scheduler's random state round-trips, and its draws advance it
function rt_ptls_rng(seed::UInt64)
    old = Base.Partr.get_ptls_rng()
    Base.Partr.set_ptls_rng(seed)
    g = Base.Partr.get_ptls_rng()
    d = (Base.Partr.cong(UInt32(1000)), Base.Partr.cong(UInt32(1000)), Base.Partr.cong(UInt32(1000)))
    after = Base.Partr.get_ptls_rng()
    Base.Partr.set_ptls_rng(old)
    return (g, d, after)
end

# GC logging: the flag is kept
function rt_gc_logging(x::Int)
    a = GC.logging_enabled()
    GC.enable_logging(true); b = GC.logging_enabled()
    GC.enable_logging(false); c = GC.logging_enabled()
    return (a, b, c, x)
end

# GC.enable: the requested state, kept as natively (WasmGC collects regardless)
function rt_gc_enable(x::Int)
    a = GC.enable(false); b = GC.enable(false); c = GC.enable(true); d = GC.enable(true)
    e = ccall(:jl_gc_enable, Int32, (Int32,), Int32(0)); f = ccall(:jl_gc_enable, Int32, (Int32,), Int32(-3))
    g = ccall(:jl_gc_enable, Int32, (Int32,), Int32(1))
    return (a, b, c, d, e, f, g, x)
end

# Libc.rand (`jl_rand`, `jl_srand`): the C runtime's generator, the same stream as natively
rt_libc_rand(seed::UInt64) = (Libc.srand(seed); (Libc.rand(), Libc.rand(), Libc.rand(Float64), Libc.rand(UInt32)))

# unseeded, both generators start from the host's entropy, as natively from the system's:
# not the streams of seed 0 (whose first `Libc.rand()` is 362437)
rt_rand_seeded(x::Int) = (Libc.rand() != UInt32(362437), Base.Partr.get_ptls_rng() != 0, x)

# the GC: collection and finalizers are no-ops, weak references hold
mutable struct RTBox; x::Int; end
function rt_gc(x::Int)
    b = RTBox(x)
    finalizer(o -> nothing, b)
    w = WeakRef(b)
    GC.gc(); GC.gc(false)
    GC.safepoint()
    return (w.value === b, b.x)
end
# statistics are 0 (WasmGC has none): not compared with native, which has some
rt_gc_stats() = (Base.gc_live_bytes(), Base.gc_bytes(), Base.gc_num().allocd, Base.gc_num().total_time,
                 Base.cumulative_compile_time_ns(), Base.gc_total_bytes(Base.gc_num()))
# (`jl_gc_sync_total_bytes(offset)`: the bytes allocated since, an Int64)
rt_gc_sync(x::Int64) = ccall(:jl_gc_sync_total_bytes, Int64, (Int64,), x) + x
# the CPU and thread queries, as natively with `-t 1` on one CPU (not compared with native)
rt_cpu() = (ccall(:jl_cpu_threads, Cint, ()), ccall(:jl_effective_threads, Cint, ()), Threads.threadpool() === :default)

# threads, as natively with `-t 1` (not compared with the test process, which has more)
rt_threads() = (Threads.nthreads(), Threads.maxthreadid(), Threads.nthreadpools(), Threads.threadid(),
                Threads.threadpool() === :default, Threads.threadpoolsize(:interactive),
                Threads.threadpoolsize(:default), Threads.ngcthreads(), Threads.nthreads(:default))
rt_sys(x::Int) = (Sys.CPU_THREADS + x, Sys.WORD_SIZE, Sys.KERNEL === :Linux, Sys.ARCH === :aarch64, Sys.islinux(), Sys.iswindows())
rt_lock(x::Int) = (l = ReentrantLock(); lock(l); y = x + islocked(l); unlock(l); (y, islocked(l)))

# the floating-point environment: round to nearest, subnormals kept
rt_fenv(x::Float64) = (rounding(Float64) === RoundNearest, rounding(Float32) === RoundNearest,
                       get_zero_subnormals(), set_zero_subnormals(false), x / 3)
# setting the rounding mode: to nearest succeeds (natively too); another mode is an error here
rt_setround(x::Float64) = (Base.Rounding.setrounding_raw(Float64, Base.Rounding.to_fenv(RoundNearest)), x / 3)
function rt_setround_up(x::Float64)
    try
        Base.Rounding.setrounding_raw(Float64, Base.Rounding.to_fenv(RoundUp))
        return 0
    catch e
        return e isa ArgumentError ? 1 : 2
    end
end

# JLOptions: the options of the process that built the module (here, the test process)
rt_jloptions() = (isinteractive(), Base.JLOptions().check_bounds, Base.JLOptions().depwarn,
                  Base.JLOptions().color, Base.JLOptions().startupfile, Base.JLOptions().fast_math,
                  Base.JLOptions().code_coverage, Base.JLOptions().opt_level)

# deepcopy of mutable structs (`jl_set_nth_field`), as Pkg copies its Project and Manifest
mutable struct RTProj
    name::Union{Nothing,String}
    const uuid::UInt128
    deps::Dict{String,Int}
    vers::Vector{String}
    other::Tuple{Vector{Int},Vector{Int}}
    count::Int
end
function rt_deepcopy(n::Int)
    shared = [1, 2, 3]
    p = RTProj(n > 0 ? "P$n" : nothing, UInt128(n) << 70, Dict("a" => n, "b" => 2n),
               [string("v1.", i) for i in 1:n], (shared, shared), n)
    q = deepcopy(p)
    q.deps["c"] = 3; push!(q.vers, "v9"); q.count += 1
    t = q.other
    return (q.name == p.name, q.uuid == p.uuid, length(p.deps), length(q.deps), length(p.vers),
            length(q.vers), q.count, t[1] === t[2], t[1] !== shared, t[1] == shared)
end

# calls that cannot run in a closed world: the diagnostic names the Julia API that reaches them
rt_eval(x::Int) = Core.eval(Main, :RT_EVAL_NAME)::Int + x
rt_dlopen(x::Int) = (Libc.Libdl.dlopen("libm"); x)
rt_typeintersect(x::Int) = (typeintersect(x > 0 ? Vector{Int} : Vector, AbstractVector{Int}) === Vector{Int}; x)

@testset "runtime: C runtime and C library calls" begin
    @testset "rt_gensym_image" begin @wtest rt_gensym_image(50) end
    @testset "rt_set_nth" begin
        @wtest rt_set_nth(UInt(0)); @wtest rt_set_nth(UInt(2)); @wtest rt_set_nth(typemax(UInt))
        for (i, empty) in ((UInt(2), false), (UInt(0), true), (typemax(UInt), false), (UInt(typemax(Int)) + 1, false))
            @wtest rt_set_nth_caught(i, empty)
        end
    end
    @testset "rt_gensym_late" begin
        # (compiled before it runs natively: the generated function first runs in the compilation)
        got = wasm_run(wcompile(rt_gensym_late, (Int,)), "rt_gensym_late", 200; rettype=Bool)
        @test got === false
    end
    @testset "rt_ptls_rng" begin @wtest rt_ptls_rng(UInt64(42)) end
    @testset "rt_gc_logging" begin @wtest rt_gc_logging(1) end
    @testset "rt_gc_enable" begin @wtest rt_gc_enable(1) end
    @testset "rt_deepcopy" begin @wtest rt_deepcopy(3) end
    @testset "rt_deepcopy" begin @wtest rt_deepcopy(0) end
    @testset "rt_crc_string" begin @wtest rt_crc_string(1) end
    @testset "rt_crc_string" begin @wtest rt_crc_string(2) end
    @testset "rt_crc_string" begin @wtest rt_crc_string(3) end
    @testset "rt_crc_bytes" begin @wtest rt_crc_bytes(100) end
    @testset "rt_crc_ints" begin @wtest rt_crc_ints(0x0123456789abcdef) end
    @testset "rt_crc_io" begin @wtest rt_crc_io(300) end
    @testset "rt_slug_len" begin @wtest rt_slug_len(0x00000000deadbeef) end
    @testset "rt_findlast" begin @wtest rt_findlast(4) end
    @testset "rt_findprev_bytes" begin @wtest rt_findprev_bytes(35) end
    @testset "rt_symcmp" begin @wtest rt_symcmp(50) end
    @testset "rt_gensym" begin @wtest rt_gensym(20) end
    @testset "rt_libc_rand" begin @wtest rt_libc_rand(0x000000000000002a) end
    @testset "rt_libc_rand" begin @wtest rt_libc_rand(0xffffffffffffffff) end
    @testset "rt_rand_seeded" begin @wtest rt_rand_seeded(1) end
    @testset "rt_gc" begin @wtest rt_gc(7) end
    @testset "rt_sys" begin @wtest rt_sys(1) end
    @testset "rt_lock" begin @wtest rt_lock(3) end
    @testset "rt_fenv" begin @wtest rt_fenv(1.0) end
    @testset "rt_jloptions" begin @wtest rt_jloptions() end
    @testset "rt_setround" begin @wtest rt_setround(1.0) end
    @test wasm_run(wcompile(rt_setround_up, (Float64,)), "rt_setround_up", 1.0; rettype=Int) == 1
    @test wasm_run(wcompile(rt_gc_sync, (Int64,)), "rt_gc_sync", Int64(5); rettype=Int64) == 5
    # not compared with native (documented constants)
    for (f, expected) in ((rt_gc_stats, (0, 0, 0, 0, (0, 0), 0)), (rt_cpu, (Cint(1), Cint(1), true)),
                          (rt_threads, (1, 1, 2, 1, true, 0, 1, 1, 1)))
        got = wasm_run(wcompile(f, ()), string(nameof(f)); rettype=Base.return_types(f, ())[1])
        @test got == expected
        got == expected || @info "mismatch" f expected got
    end
    for (f, api) in ((rt_eval, "Core.eval"), (rt_dlopen, "Libdl.dlopen"))
        err = try
            WasmCodegen.compile(f, (Int,))
            nothing
        catch e
            e
        end
        msg = err === nothing ? "" : sprint(showerror, err)
        @test err isa WasmCodegen.UnsupportedConstructs && occursin(api, msg)
        occursin(api, msg) || @info "diagnostic" f msg
    end
end
