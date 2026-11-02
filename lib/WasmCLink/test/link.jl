# End to end, with the provider and the toolchain as they are pinned: the consumer natively against
# the linked module, bit for bit, on both hosts; and what the linker refuses.
using Test, WasmCodegen, WasmCLink, TOML, SHA, OpenLibm_jll, OpenLibm_wasm_jll
using WasmCodegen: Config, Entry
using WasmCLink: LinkFailure, TOOLCHAIN
import NodeJS_24_jll

include("consumer.jl")

const DIR = mktempdir()
const RUN = joinpath(@__DIR__, "run.mjs")
const P = Provider(OpenLibm_wasm_jll)
const NAMES = String.(nameof.(CONSUMERS))
const WANT = Dict(string(nameof(f)) => string(f()) for f in CONSUMERS)

function run_module(file, host, names=NAMES)
    out = read(`$(NodeJS_24_jll.node()) --disable-warning=ExperimentalWarning $RUN $(WasmCodegen.JS_HOST) $host $file $names`, String)
    return Dict(String(split(l, ' '; limit=2)[1]) => String(split(l, ' '; limit=2)[2]) for l in split(strip(out), '\n'))
end

# a provider like P with its manifest changed, and optionally another archive
function variant(f!; archive=nothing, lib="libopenlibm")
    d = mktempdir()
    mkpath(joinpath(d, "share")); mkpath(joinpath(d, "lib"))
    m = deepcopy(P.manifest)
    src = archive === nothing ? joinpath(P.dir, m["libraries"]["libopenlibm"]["archive"]) : archive
    cp(src, joinpath(d, "lib", "x.a"); force=true)
    e = m["libraries"]["libopenlibm"]
    delete!(m["libraries"], "libopenlibm")
    e["archive"] = "lib/x.a"; e["sha256"] = bytes2hex(open(sha256, src))
    m["libraries"][lib] = e
    f!(m)
    open(io -> TOML.print(io, m), joinpath(d, "share", "wasm-provider.toml"), "w")
    return Provider(d)
end

w_print() = (println(Core.stdout, "printed ", s_name()); UInt64(1))

const raw = Config(optimize=nothing)
good() = ccall((:sin, OpenLibm_jll.libopenlibm), Cdouble, (Cdouble,), 0.5)
function refused(pattern, c, provider; kw...)
    e = try
        link(c, mktempdir(); provider, kw...)
        nothing
    catch x
        x isa LinkFailure || rethrow()
        x
    end
    @test e !== nothing && occursin(pattern, sprint(showerror, e))
end
fixture(n) = joinpath(@__DIR__, "fixtures", n)

missing_sym() = ccall((:no_such_function, OpenLibm_jll.libopenlibm), Cdouble, (Cdouble,), 0.5)
# (in OpenLibm, and not in the file list of its wasm arch)
excluded() = ccall((:lround, OpenLibm_jll.libopenlibm), Clong, (Cdouble,), 0.5)
# integers, by a small library: OpenLibm has no function returning a `long`
n_lmul3() = ccall((:lmul3, "libopenlibm"), Clong, (Clong,), -Int64(0x0123456789ab)) % UInt64
n_ulhigh() = ccall((:ulhigh, "libopenlibm"), Culong, ())
n_ineg() = Int64(ccall((:ineg, "libopenlibm"), Cint, (Cint,), Cint(5))) % UInt64
n_uimax() = UInt64(ccall((:uimax, "libopenlibm"), Cuint, ()))
n_void() = (ccall((:nothing_here, "libopenlibm"), Cvoid, ()); UInt64(1))
const INTS = Pair{Function,UInt64}[n_lmul3 => (-3 * 0x0123456789ab) % UInt64, n_ulhigh => 0xfedcba9876543210, n_ineg => (-5) % UInt64,
                                   n_uimax => 0x00000000ffffffff, n_void => 0x0000000000000001]
wrong_sig() = ccall((:sin, OpenLibm_jll.libopenlibm), Cfloat, (Cfloat,), 0.5f0)
wrong_arity() = ccall((:sin, OpenLibm_jll.libopenlibm), Cdouble, (Cdouble, Cdouble), 0.5, 0.5)
other_lib() = ccall((:f, "libother.so"), Cdouble, (Cdouble,), 0.5)
two_libs() = good() + other_lib()
ctor() = ccall((:ctor_f, "libopenlibm"), Cdouble, (Cdouble,), 0.5)
undef() = ccall((:undef_f, "libopenlibm"), Cdouble, (Cdouble,), 0.5)
nolib() = 1.0

WasmCodegen.with_trim_patches() do _, _
global goodc = compile([(good, ())]; config=raw)

@testset "OpenLibm, $host" for host in (:js, :wasi)
    entries = Entry[Entry(f, ()) for f in CONSUMERS]
    host === :wasi && push!(entries, Entry(w_print, ()))
    file = build(entries, joinpath(DIR, string(host)); provider=P, config=Config(host=host, verify=:error))
    got = run_module(file, host, host === :wasi ? vcat(NAMES, "w_print") : NAMES)
    for n in NAMES
        @testset "$n" begin
            @test got[n] == WANT[n]
        end
    end
    # nothing of C's is left to resolve or exposed
    @test !occursin("c:", got["imports"])
    exported = Set(split(got["exports"]))
    if host === :wasi
        # C's memory is a second one; WASI reads the module's, which stays the exported one
        @test got["imports"] == "wasi_snapshot_preview1"
        @test got["printed"] == WANT["s_name"]
        @test issubset(exported, Set(vcat(NAMES, "w_print", "memory", "_initialize"))) && "memory" in exported
    else
        @test got["imports"] in ("julia", "-")
        @test exported == Set(NAMES)
    end
    plan = TOML.parsefile(joinpath(dirname(file), "plan.toml"))
    @test plan["abi"] == TOOLCHAIN["abi"]
    @test plan["memories"] == (host === :wasi ? ["module", "c"] : ["c"])
    @test plan["tools"]["lld"] == TOOLCHAIN["lld"] && plan["tools"]["binaryen"] == TOOLCHAIN["binaryen"]
    @test plan["outputs"]["module"] == bytes2hex(open(sha256, file))
    r = TOML.parsefile(joinpath(dirname(file), "requirements.toml"))["function"]
    @test "sin" in [x["symbol"] for x in r] && all(x -> x["library"] == "libopenlibm", r)
end

@testset "integers" begin
    file = build(Entry[Entry(first(p), ()) for p in INTS], joinpath(DIR, "ints"); provider=variant(identity; archive=fixture("libints.a")))
    got = run_module(file, :js, [string(nameof(first(p))) for p in INTS])
    for (f, want) in INTS
        @test got[string(nameof(f))] == string(want)
    end
end

@testset "refused" begin
    @testset "symbols" begin
        refused("lround of libopenlibm: the provider does not define it", compile([(excluded, ())]; config=raw), P)
        refused("no_such_function of libopenlibm: the provider does not define it", compile([(missing_sym, ())]; config=raw), P)
        refused("sin of libopenlibm: declared as", compile([(wrong_sig, ())]; config=raw), P)
        refused("sin of libopenlibm: declared as", compile([(wrong_arity, ())]; config=raw), P)
    end
    @testset "libraries" begin
        refused("f of libother: this provider has no such library", compile([(other_lib, ())]; config=raw), P)
        refused("a link has one provider", compile([(two_libs, ())]; config=raw), P)
        refused("no C imports", compile([(nolib, ())]; config=raw), P)
    end
    @testset "provider" begin
        refused("the provider's ABI is", goodc, variant(m -> m["abi"] = "wasm32-ilp32"))
        refused("named through OpenLibm_jll", goodc, variant(m -> m["native"]["uuid"] = "00000000-0000-0000-0000-000000000001"))
        refused("this provider builds 0.0.1", goodc, variant(m -> m["native"]["version"] = "0.0.1"))
        refused("is not the one its manifest names", goodc, variant(m -> m["libraries"]["libopenlibm"]["sha256"] = "00"))
        refused("has dependencies", goodc, variant(m -> m["libraries"]["libopenlibm"]["deps"] = ["libfoo"]))
        @test_throws LinkFailure Provider(mktempdir())
    end
    @testset "toolchain" begin
        refused("pinned to 0.0", goodc, P; toolchain=merge(TOOLCHAIN, Dict("lld" => "0.0")))
        refused("pinned to 1", goodc, P; toolchain=merge(TOOLCHAIN, Dict("binaryen" => "1")))
    end
    @testset "C code" begin
        refused("has constructors", compile([(ctor, ())]; config=raw), variant(identity; archive=fixture("libctor.a")))
        refused("wasm-ld failed", compile([(undef, ())]; config=raw), variant(identity; archive=fixture("libundef.a")))
    end
end
end
