# Packs the payload of build_openlibm.sh as the provider's artifact, with its provider manifest.
# usage: mk_openlibm_provider.jl <payload dir> <tarball dir> <url the tarball is served from>
using Pkg, Pkg.Artifacts, SHA, TOML
payload, tardir, url = ARGS
archive = joinpath(payload, "lib", "wasm64", "libopenlibm.a")
manifest = Dict(
    "format" => 1,
    "abi" => "wasm64-lp64-freestanding-v0",
    "native" => Dict("name" => "OpenLibm_jll", "uuid" => "05823500-19ac-5b8b-9628-191a04bc5112", "version" => "0.8.7"),
    "libraries" => Dict("libopenlibm" => Dict("archive" => "lib/wasm64/libopenlibm.a",
                                              "sha256" => bytes2hex(open(sha256, archive)),
                                              "deps" => String[])),
    "build" => Dict("source" => "https://github.com/JuliaMath/openlibm.git",
                    "commit" => "9fbeafcd4f1b6ef6aa3946c1c8faead50f38a94d",
                    "compiler" => "wasi-sdk 34.0 clang, sha256 b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4",
                    "script" => "lib/build_openlibm.sh"))
open(io -> TOML.print(io, manifest; sorted=true), joinpath(payload, "share", "wasm-provider.toml"), "w")
h = create_artifact() do d
    cp(joinpath(payload, "lib"), joinpath(d, "lib"))
    cp(joinpath(payload, "share"), joinpath(d, "share"))
end
mkpath(tardir)
tar = joinpath(tardir, "OpenLibm_wasm.v0.8.7.any.tar.gz")
sha = archive_artifact(h, tar)
toml = joinpath(@__DIR__, "OpenLibm_wasm_jll", "Artifacts.toml")
isfile(toml) && rm(toml)
bind_artifact!(toml, "OpenLibm_wasm", h; download_info=[(url, sha)], force=true)
print(read(toml, String))
