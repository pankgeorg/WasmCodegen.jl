"""
Links a module compiled by WasmCodegen with the C library that provides its `c:<library>` imports,
into one module. WasmCodegen says what a module needs (`WasmCodegen.requirements`); this resolves
it against an explicit provider and a pinned toolchain, and writes what it did to `plan.toml`.

One provider at a time, of one library, with no C constructors. A requirement it cannot meet exactly
is a `LinkFailure`, naming the symbol.

Memory: a module for JavaScript has none, so C's is the only one. A module for WASI keeps its own,
which WASI reads, and C's is a second, since the module's is a 32-bit memory at fixed offsets and
WasmBuilder cannot import one. No value crosses between them while only numbers cross to C.
"""
module WasmCLink

using WasmCodegen
using WasmCodegen: requirements, CRequirement, import_module, WASM_FEATURES, Config, Compilation
using SHA, TOML
import Binaryen_jll, LLD_jll

export link, build, Provider, LinkFailure

struct LinkFailure <: Exception
    msg::String
end
Base.showerror(io::IO, e::LinkFailure) = print(io, "WasmCLink: ", e.msg)
fail(msg...) = throw(LinkFailure(string(msg...)))

const TOOLCHAIN = TOML.parsefile(joinpath(@__DIR__, "..", "toolchain.toml"))
const FEATURES = `$WASM_FEATURES --enable-memory64 --enable-multimemory`

binaryen_tool(name) = joinpath(dirname(Binaryen_jll.wasmopt_path), name)
wasm_ld() = `$(LLD_jll.lld()) -flavor wasm`

function tool_versions()
    b = match(r"version (\d+)", read(`$(binaryen_tool("wasm-merge")) --version`, String))
    l = match(r"LLD (\S+)", read(`$(wasm_ld()) --version`, String))
    return Dict("binaryen" => String(b[1]), "lld" => String(l[1]))
end

function check_toolchain(pin::AbstractDict)
    have = tool_versions()
    for (tool, version) in have
        version == pin[tool] || fail("the toolchain has ", tool, " ", version, ", and this linker is pinned to ", pin[tool])
    end
    return have
end

"""
    Provider(dir) or Provider(jll::Module)

What provides a C library: an artifact directory with a `share/wasm-provider.toml`, or the JLL
holding one.
"""
struct Provider
    dir::String
    manifest::Dict{String,Any}
end
function Provider(dir::AbstractString)
    file = joinpath(dir, "share", "wasm-provider.toml")
    isfile(file) || fail("no provider manifest at ", file)
    return Provider(String(dir), TOML.parsefile(file))
end
Provider(jll::Module) = Provider(jll.find_artifact_dir()::String)

# The archive of `lib` in the provider, checked against its manifest.
function provider_archive(p::Provider, lib::String)
    entry = p.manifest["libraries"][lib]
    isempty(entry["deps"]) || fail("library ", lib, " has dependencies, which this linker does not resolve")
    path = joinpath(p.dir, entry["archive"])
    isfile(path) || fail("the provider has no archive ", entry["archive"])
    bytes2hex(open(sha256, path)) == entry["sha256"] || fail("the archive of ", lib, " is not the one its manifest names")
    return path
end

function check_provider(reqs::Vector{CRequirement}, p::Provider, pin::AbstractDict)
    p.manifest["abi"] == pin["abi"] || fail("the provider's ABI is ", p.manifest["abi"], ", and this linker's is ", pin["abi"])
    native = p.manifest["native"]
    libs = unique(r.library for r in reqs)
    length(libs) == 1 || fail("the module needs libraries ", join(libs, ", "), ", and a link has one provider")
    for r in reqs
        haskey(p.manifest["libraries"], r.library) ||
            fail(r.symbol, " of ", r.library, ": this provider has no such library (it provides ",
                 join(sort!(collect(keys(p.manifest["libraries"]))), ", "), ")")
        r.package === nothing || string(r.package.uuid) == native["uuid"] ||
            fail(r.symbol, " of ", r.library, ": named through ", r.package.name, ", and this provider builds ", native["name"])
    end
    id = Base.PkgId(Base.UUID(native["uuid"]), native["name"])
    if haskey(Base.loaded_modules, id)
        v = pkgversion(Base.loaded_modules[id])
        v === nothing || string(VersionNumber(v.major, v.minor, v.patch)) == native["version"] ||
            fail("the program loads ", native["name"], " ", v, ", and this provider builds ", native["version"])
    end
end

## the Wasm binary format, as far as this needs it

function leb(b::Vector{UInt8}, i::Int)
    r, s = UInt64(0), 0
    while true
        x = b[i]; i += 1
        r |= UInt64(x & 0x7f) << s; s += 7
        x & 0x80 == 0 && return Int(r), i
    end
end

function sections(b::Vector{UInt8})
    out = Tuple{UInt8,Int,Int,Int}[]    # id, its first byte, the first of its contents, its last
    i = 9
    while i <= length(b)
        start, id = i, b[i]
        n, i = leb(b, i + 1)
        push!(out, (id, i, i + n - 1, start))
        i += n
    end
    return out
end

section(b, id) = (k = findfirst(s -> s[1] == id, sections(b)); k === nothing ? nothing : sections(b)[k])

function name_at(b, i)
    n, i = leb(b, i)
    return String(b[i:i+n-1]), i + n
end

"The exports of a module: `(name, kind, index, bytes)`, the last their encoding."
function exports(b::Vector{UInt8})
    s = section(b, 7)
    out = Tuple{String,UInt8,Int,Vector{UInt8}}[]
    s === nothing && return out
    n, i = leb(b, s[2])
    for _ in 1:n
        start = i
        name, i = name_at(b, i)
        kind = b[i]
        idx, i = leb(b, i + 1)
        push!(out, (name, kind, idx, b[start:i-1]))
    end
    return out
end

"The function signatures of a module whose types are all plain functions: its type section's, and the function's types."
function signatures(b::Vector{UInt8})
    s = section(b, 1)
    n, i = leb(b, s[2])
    valtype(x) = x == 0x7f ? :i32 : x == 0x7e ? :i64 : x == 0x7d ? :f32 : x == 0x7c ? :f64 : Symbol("t", x)
    types = Tuple{Vector{Symbol},Vector{Symbol}}[]
    for _ in 1:n
        b[i] == 0x60 || fail("a C module with a type that is not a function")
        np, i = leb(b, i + 1); ps = valtype.(b[i:i+np-1]); i += np
        nr, i = leb(b, i); rs = valtype.(b[i:i+nr-1]); i += nr
        push!(types, (ps, rs))
    end
    section(b, 2) === nothing || fail("the linked C library imports something; it must be freestanding: ", join(imports(b), ", "))
    f = section(b, 3)
    n, i = leb(b, f[2])
    funcs = Tuple{Vector{Symbol},Vector{Symbol}}[]
    for _ in 1:n
        t, i = leb(b, i)
        push!(funcs, types[t+1])
    end
    return funcs
end

function imports(b::Vector{UInt8})
    s = section(b, 2)
    out = String[]
    s === nothing && return out
    n, i = leb(b, s[2])
    for _ in 1:n
        m, i = name_at(b, i)
        name, i = name_at(b, i)
        push!(out, m * "." * name)
        kind = b[i]
        kind == 0x00 || fail("the import ", out[end], " is not a function")
        _, i = leb(b, i + 1)
    end
    return out
end

"The size in bytes of the body of the function `idx` of a module with no imports."
function body_size(b::Vector{UInt8}, idx::Int)
    s = section(b, 10)
    n, i = leb(b, s[2])
    for k in 0:n-1
        size, i = leb(b, i)
        k == idx && return size
        i += size
    end
    fail("no function ", idx)
end

function encode_leb(n::Int)
    out = UInt8[]
    while true
        x = UInt8(n & 0x7f); n >>= 7
        n == 0 ? (push!(out, x); return out) : push!(out, x | 0x80)
    end
end

"The module with only the exports named `keep`."
function keep_exports(b::Vector{UInt8}, keep::Set{String})
    s = section(b, 7)
    es = filter(e -> e[1] in keep, exports(b))
    contents = vcat(encode_leb(length(es)), (e[4] for e in es)...)
    return vcat(b[1:s[4]-1], UInt8[0x07], encode_leb(length(contents)), contents, b[s[3]+1:end])
end

## linking

const VALTYPE_NAMES = Dict{Any,Symbol}(Int32 => :i32, UInt32 => :i32, Int64 => :i64, UInt64 => :i64, Float32 => :f32, Float64 => :f64)

function c_module(reqs::Vector{CRequirement}, archive::String, dir::String)
    out = joinpath(dir, "c.wasm")
    syms = unique(r.symbol for r in reqs)
    log = joinpath(dir, "wasm-ld.log")
    cmd = `$(wasm_ld()) -mwasm64 --no-entry --fatal-warnings --stack-first -z stack-size=65536
           $(["--export-if-defined=" * s for s in syms]) --export-if-defined=__wasm_call_ctors $archive -o $out`
    success(pipeline(ignorestatus(cmd); stdout=log, stderr=log)) || fail("wasm-ld failed for ", join(syms, ", "), ":\n", read(log, String))
    return out
end

function check_c_module(reqs::Vector{CRequirement}, path::String)
    b = read(path)
    sigs = signatures(b)
    es = Dict(e[1] => e[3] for e in exports(b) if e[2] == 0x00)
    for r in reqs
        haskey(es, r.symbol) || fail(r.symbol, " of ", r.library, ": the provider does not define it")
        want = (Symbol[VALTYPE_NAMES[T] for T in r.argtypes], r.rettype === Cvoid ? Symbol[] : Symbol[VALTYPE_NAMES[r.rettype]])
        have = sigs[es[r.symbol]+1]
        have == want || fail(r.symbol, " of ", r.library, ": declared as ", want, ", and the provider's takes and returns ", have)
    end
    # (a body of nothing: no locals, `end`)
    !haskey(es, "__wasm_call_ctors") || body_size(b, es["__wasm_call_ctors"]) <= 2 ||
        fail("the C library has constructors, whose order against the module's initialization this linker does not define")
end

function write_records(dir, reqs, p, versions, inputs, outputs, memories)
    open(joinpath(dir, "requirements.toml"), "w") do io
        TOML.print(io, Dict("function" => [Dict("library" => r.library, "symbol" => r.symbol,
                                                "package" => r.package === nothing ? "" : string(r.package.uuid),
                                                "returns" => string(r.rettype), "takes" => string.(r.argtypes)) for r in reqs]))
    end
    open(joinpath(dir, "plan.toml"), "w") do io
        TOML.print(io, Dict("abi" => p.manifest["abi"], "tools" => versions, "provider" => p.manifest, "memories" => memories,
                            "inputs" => inputs, "outputs" => outputs); sorted=true)
    end
end

"""
    link(c::Compilation, dir; provider, optimize=`-O3`, toolchain=TOOLCHAIN) -> path of the linked module

The module of `c` with its C imports resolved by `provider`, in `dir`, with the `plan.toml` of how.
`optimize`: `wasm-opt`'s options, over the whole (`nothing`: none).
"""
function link(c::Compilation, dir::AbstractString; provider::Provider, optimize::Union{Nothing,Cmd}=`-O3`,
              toolchain::AbstractDict=TOOLCHAIN)
    dir = mkpath(String(dir))
    reqs = requirements(c)
    isempty(reqs) && fail("the module has no C imports, so nothing to link")
    versions = check_toolchain(toolchain)
    check_provider(reqs, provider, toolchain)
    archive = provider_archive(provider, reqs[1].library)
    clib = c_module(reqs, archive, dir)
    check_c_module(reqs, clib)
    jl = joinpath(dir, "julia.wasm")
    write(jl, c.bytes)
    merged = joinpath(dir, "merged.wasm")
    # (the module first, so that its memory, if it has one, stays the exported `memory`)
    run(`$(binaryen_tool("wasm-merge")) $jl julia $clib $(import_module(reqs[1])) --rename-export-conflicts $FEATURES -o $merged`)
    keep = Set(e[1] for e in exports(c.bytes))
    write(merged, keep_exports(read(merged), keep))
    out = joinpath(dir, "module.wasm")
    if optimize === nothing
        cp(merged, out; force=true)
    else
        run(`$(binaryen_tool("wasm-opt")) $optimize $FEATURES --closed-world --type-ssa --gufa $merged -o $out`)
    end
    left = filter(i -> startswith(i, "c:"), imports(read(out)))
    isempty(left) || fail("unresolved after linking: ", join(left, ", "))
    write_records(dir, reqs, provider, versions,
                  Dict("module" => bytes2hex(sha256(c.bytes)), "archive" => bytes2hex(open(sha256, archive))),
                  Dict("module" => bytes2hex(open(sha256, out)), "bytes" => filesize(out)),
                  any(e -> e[2] == 0x02, exports(c.bytes)) ? ["module", "c"] : ["c"])
    return out
end

"""
    build(entries, dir; provider, config=Config()) -> path of the linked module

`compile`, then `link`, optimizing once, after the C library is in.
"""
function build(entries, dir::AbstractString; provider::Provider, config::Config=Config(), toolchain::AbstractDict=TOOLCHAIN)
    raw = Config((f === :optimize ? nothing : getfield(config, f) for f in fieldnames(Config))...)
    return link(compile(entries; config=raw), dir; provider, optimize=config.optimize, toolchain)
end

end
