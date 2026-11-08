# `install_trim_patches!`: the patches installed once, for the process's life. A compilation
# after it defines no method, and compiles the module a session of its own compiles; the
# process itself keeps Base's printing, package loading and `invokelatest`. (In a worker of its
# own: the installation is not undone.)

module ResidentTarget
struct Point
    x::Float64
    y::Float64
end
norm2(p::Point) = sqrt(p.x^2 + p.y^2)
digest(s::String) = (sizeof(s), hash(s))
described(n::Int) = digest(string("n = ", n, ", ", norm2(Point(n, 2n)), ", ", [n, n + 1]))
type_named(n::Int) = digest(string(n > 0 ? Int : Float64, " ", Vector{Pair{Base.PkgId,Int}}))
@enum Fruit apple banana
fruit_named(n::Int) = digest(string(n == 1 ? apple : banana))
bottom_named(n::Int) = digest(string(n > 0 ? Union{} : Int))
@enum Shade light dark
@noinline Base.show(io::IO, s::Shade) = print(io, s === light ? "a light shade" : "a dark shade")
shade_shown(n::Int) = digest(sprint(show, n == 1 ? light : dark))
shade_invoked(n::Int) = digest(sprint((io, s) -> invoke(show, Tuple{IO,Shade}, io, s), n == 1 ? light : dark))
@enum Tone high low
Base.show(io::IO, t::Tone) = (print(io, t === high ? "high" : "low"); 17)
tone_returned(n::Int) = show(IOBuffer(), n == 1 ? high : low)
latest_target(x::Int) = 2x + 1
kw_target(x::Int; k::Int=0) = 10x + k
latest_called(n::Int) = Base.@invokelatest(latest_target(n)) + Base.invokelatest(latest_target, n)
latest_splat(n::Int) = Base.invokelatest(latest_target, ntuple(_ -> n, Val(1))...)
latest_kw(n::Int) = Base.invokelatest(kw_target, n; k=3) + Base.@invokelatest(kw_target(n; k=4))
latest_nested(n::Int) = Base.invokelatest(Base.invokelatest, latest_target, n)
const SINK = Ref{Any}(1)
dynamic(n::Int) = SINK[] + n
end

session_worlds(compiler_world, program_world) = (compiler_world, program_world)

# the sections of a module: id => contents, in order
function wasm_sections(bytes::Vector{UInt8})
    sections = Pair{UInt8,Vector{UInt8}}[]
    i = 9
    while i <= length(bytes)
        id = bytes[i]
        i += 1
        n, shift = 0, 0
        while true
            b = bytes[i]
            i += 1
            n |= Int(b & 0x7f) << shift
            shift += 7
            b < 0x80 && break
        end
        push!(sections, id => bytes[i:i+n-1])
        i += n
    end
    return sections
end

@testset "resident trim patches" begin
    T = WasmCodegen.Runtime
    R = ResidentTarget
    programs = [(R.described, 3, Tuple{Int,UInt}), (R.type_named, 1, Tuple{Int,UInt}),
                (R.fruit_named, 2, Tuple{Int,UInt}), (R.bottom_named, 1, Tuple{Int,UInt}),
                (R.shade_shown, 1, Tuple{Int,UInt}), (R.shade_invoked, 2, Tuple{Int,UInt}),
                (R.tone_returned, 1, Int), (R.latest_called, 4, Int), (R.latest_splat, 4, Int),
                (R.latest_kw, 4, Int), (R.latest_nested, 4, Int), (R.dynamic, 5, Int)]
    config = test_config(trim=:unsafe)
    compiled(f) = WasmCodegen.compile(f, (Int,); config)
    diagnostics(c) = [(sprint(show, mi), sprint(showerror, e)) for (mi, e) in c.cgm.diagnostics]
    result(c, f, n, rettype) = wasm_run(c, string(nameof(f)), n; rettype)
    # (Base's, before the installation)
    pkg = Base.PkgId(Base.UUID("a6a1e1a2-3b4c-4d5e-8f90-0a1b2c3d4e5f"), "ResidentProbe")
    natively() = [repr(pkg => "path"), repr([pkg]), sprint(show, Vector{Pair{Base.PkgId,Int}}), repr(R.apple),
                  sprint(show, R.norm2), sprint(show, Base.Order.Forward), Base.active_project(), pwd(), readdir(@__DIR__)]
    native = natively()
    # each in a session of its own
    stock = [compiled(f) for (f, _, _) in programs]
    # the methods defined since world `w`
    defined_since(w) = (ms = Method[]; Base.visit(m -> m.primary_world > w && push!(ms, m), Core.methodtable); ms)

    w0 = Base.get_world_counter()
    @test WasmCodegen.install_trim_patches!() === nothing
    w1 = Base.get_world_counter()
    @test w1 > w0 && T.PRE_PATCH_WORLD[] == w0

    @testset "installing again" begin
        w = Base.get_world_counter()
        @test WasmCodegen.install_trim_patches!() === nothing
        @test isempty(defined_since(w))
        # (other patches, or the tasks', are another session)
        extra = joinpath(@__DIR__, "patches", "greeting.jl")
        @test_throws ErrorException WasmCodegen.install_trim_patches!(patches=[WasmCodegen.TRIM_PATCHES; extra])
        @test_throws ErrorException WasmCodegen.install_trim_patches!(patches=[WasmCodegen.TRIM_PATCHES; WasmCodegen.TASK_PATCHES])
        @test_throws ErrorException WasmCodegen.with_trim_patches(() -> nothing; patches=[extra])
        w = Base.get_world_counter()
        @test WasmCodegen.with_trim_patches(session_worlds) == (WasmCodegen.COMPILER_WORLD[], w)
        @test isempty(defined_since(w))
    end

    @testset "compilations: no new world, the same module" begin
        for ((f, n, rettype), s) in zip(programs, stock)
            w = Base.get_world_counter()
            c = compiled(f)
            @test isempty(defined_since(w))
            cs, ss = wasm_sections(c.bytes), wasm_sections(s.bytes)
            @test first.(cs) == first.(ss)
            # (the code, types, imports and exports; data and globals hold addresses and unused
            # capacity of the build process's objects)
            for id in (0x01, 0x02, 0x03, 0x07, 0x0a)
                @test filter(p -> p.first == id, cs) == filter(p -> p.first == id, ss)
            end
            @test diagnostics(c) == diagnostics(s)
            @test result(c, f, n, rettype) == result(s, f, n, rettype)
        end
        @test !isempty(diagnostics(stock[end]))
        # (and what native Julia computes, but for the names of types and enums, which juliac's
        # patches print their own way)
        for ((f, n, rettype), s) in zip(programs, stock)
            f in (R.type_named, R.fruit_named, R.bottom_named, R.dynamic) && continue
            @test result(s, f, n, rettype) == f(n)
        end
    end

    @testset "the process keeps Base's behavior" begin
        @test natively() == native
        # (the method a runtime function calls natively: the one before the installation)
        @test T.original(pwd) == pwd() == native[8]
        @test Base.invoke_in_world(w0, which, pwd, Tuple{}).module === Base.Filesystem
        @test which(pwd, Tuple{}).primary_world > w0
        @test Base.invokelatest(Base.PCRE.get_local_match_context) != C_NULL && occursin(r"a+b", "caab")
        # (a module's initializer, which a system image calls at startup, still has its method:
        # also one a session left without it)
        for M in Base.loaded_modules_array()
            isdefined(M, :__init__) || continue
            init = Base.invokelatest(getglobal, M, :__init__)
            init isa Function && @test Base.invokelatest(hasmethod, init, Tuple{})
        end
    end

    @testset "invokelatest of methods defined after the installation" begin
        Core.eval(R, :(defined_later(x::Int) = 10x))
        @test Base.@invokelatest(R.defined_later(4)) == 40
        @test Base.invokelatest(getglobal(R, :defined_later), 5) == 50
        Core.eval(R, :(latest_target(x::Int) = 3x))
        @test Base.@invokelatest(R.latest_target(2)) == 6
    end

    # (the patches as a new process installs them: where a function an overlay attaches to is
    # not native, not left behind by a session that deleted its method)
    @testset "installing in a new process" begin
        code = "using WasmCodegen; install_trim_patches!(); install_trim_patches!(); " *
               "print(repr(Base.PkgId(Base.UUID(1), \"X\") => 1), ' ', sprint(show, Vector{Union{}}))"
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
        @test read(cmd, String) == string(repr(Base.PkgId(Base.UUID(1), "X") => 1), ' ', sprint(show, Vector{Union{}}))
    end

    @testset "precompiling a package" begin
        mktempdir() do dir
            pkgdir = joinpath(dir, "ResidentProbe")
            mkpath(joinpath(pkgdir, "src"))
            write(joinpath(pkgdir, "Project.toml"), "name = \"ResidentProbe\"\nuuid = \"$(pkg.uuid)\"\n")
            write(joinpath(pkgdir, "src", "ResidentProbe.jl"),
                  "module ResidentProbe\n@enum Shade light dark\nprobe() = (Shade, Pair{Base.PkgId,Int})\nend\n")
            depot = joinpath(dir, "depot")
            pushfirst!(LOAD_PATH, dir)
            pushfirst!(DEPOT_PATH, depot)
            try
                cache = Base.compilecache(pkg)
                @test (cache isa Tuple ? cache[1] : cache) isa String
                M = Base.require(pkg)
                @test Base.invokelatest(getglobal(M, :probe)) == (getglobal(M, :Shade), Pair{Base.PkgId,Int})
            finally
                popfirst!(LOAD_PATH)
                popfirst!(DEPOT_PATH)
            end
        end
    end
end
