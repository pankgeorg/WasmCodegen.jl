# The host's events (`runtime/event.jl`, the `julia_io` imports of `js/julia_io.mjs`, for
# `Config(host = :wasi, host_extensions = [:julia_io])`): `sleep`, waits on handles, HTTP
# requests against a local server, a download to a file, decompression, the host's
# platform, the text of caught exceptions, and the host's file modes in the filesystem.
# What runs natively too is compared with native Julia; the rest with what the server
# sent (hashes computed natively) and the files the host has afterwards.

module EventTests

using Test, SHA
import JSON
using ..Main: wasm_run, LAST_OUTPUT, node_cmd, jspi_flags, WasmCodegen
const R = WasmCodegen.Runtime
const H = R.Host
const IO_ = R.JuliaIO
const S = R.Staging

errno_of(e) = e isa H.HostCallError ? e.errno : Int32(-1)
ms_since(t0::UInt64) = Int64((time_ns() - t0) ÷ 1_000_000)
url(port::Int32, p::String) = string("http://127.0.0.1:", port, p)
dir() = ENV["EVENT_DIR"]
const NOHEADERS = Pair{String,String}[]

## sleep and waits (through the test runner; natively too where it applies)

function sleep_ms(ms::Int32)::Int64
    t0 = time_ns()
    sleep(ms / 1000)
    return ms_since(t0)
end
function sleep_negative()::Int32
    try
        sleep(-1)
        return Int32(0)
    catch e
        return e isa ArgumentError ? Int32(1) : Int32(2)
    end
end
# a handle ready before the wait: the wait's µs
function await_before()::Int64
    h = IO_.timer_start(Int64(1_000_000))
    try
        sleep(0.02)
        t0 = time_ns()
        H.await_handle(h)
        return Int64((time_ns() - t0) ÷ 1000)
    finally
        IO_.close(h)
    end
end
# a timer that fired does not end the wait for another: its ms
function await_unrelated()::Int64
    a = IO_.timer_start(Int64(1_000_000))
    b = IO_.timer_start(Int64(40_000_000))
    try
        sleep(0.005)
        t0 = time_ns()
        H.await_handle(b)
        return ms_since(t0)
    finally
        IO_.close(a)
        IO_.close(b)
    end
end
# closing twice is an error (EBADF, 8)
function close_twice()::Int32
    h = IO_.timer_start(Int64(0))
    H.close(h)
    try
        H.close(h)
        return Int32(0)
    catch e
        return errno_of(e)
    end
end
# a handle that was never opened: ready for `poll`, EBADF for the call after it
function bad_handle()::Int32
    h = Int32(12345)
    try
        H.await_handle(h)
        H.http_head(h)
        return Int32(0)
    catch e
        return errno_of(e)
    end
end
# the arenas, as they were after the waits
function arenas_restored()::Int32
    r0, d0 = S.load32(S.RECORD_USED), S.load32(S.DATA_USED)
    for _ in 1:20
        sleep(0.0)
    end
    return S.load32(S.RECORD_USED) == r0 && S.load32(S.DATA_USED) == d0 ? Int32(1) : Int32(0)
end

## the text of caught exceptions (in a closed world, no `sprint(showerror, ::Any)`)

const ERRORS = Any[SystemError("opening file /tmp/missing", 2), ErrorException("plain"),
                   SystemError("opening", 2, "/tmp/missing"), SystemError("writing file /tmp/output", 28),
                   ArgumentError("bad"), KeyError(:k), KeyError("k"), KeyError(3), EOFError(),
                   Base.IOError("read: connection reset by peer (ECONNRESET)", -104), DivideError()]
function error_texts()::Int32
    for e in ERRORS
        println(Core.stdout, H.error_text(e))
    end
    println(Core.stdout, H.error_text(H.HostCallError(Int32(14), "refused")))
    return Int32(0)
end

## the host's platform

function platform_print()::Int32
    for (k, v) in H.host_platform()
        print(Core.stdout, k, '=', v, ';')
    end
    return Int32(0)
end

## the host's file modes and symbolic links (`FS.path_mode`, `FS.path_chmod`,
## `FS.path_symlink_io`): the host's with the extension, the defaults without

# the mode of `dir/f` (made 0o640 natively), then `chmod` to 0o604, and a link to an
# absolute target out of the preopen
function modes(dir::String)
    io = IOBuffer()
    f = joinpath(dir, "f")
    print(io, "mode ", string(filemode(f) & 0o777; base=8), ";")
    e = try
        chmod(f, 0o604)
        "ok"
    catch err
        err isa Base.IOError ? string("IOError ", err.code) : "other"
    end
    print(io, "chmod ", e, ";")
    e = try
        symlink("/nonexistent/target", joinpath(dir, "abs"))
        string("ok ", readlink(joinpath(dir, "abs")))
    catch err
        err isa Base.IOError ? string("IOError ", err.code) : "other"
    end
    print(io, "symlink ", e, ";")
    return String(take!(io))
end
modes_print(k::Int) = (print(Core.stdout, modes(string(ENV["EVENT_DIR"], "/m", k))); Int32(0))

## HTTP, downloads, decompression (through `event.mjs`: each export takes the server's port)

function fnv(h::UInt64, buf::Vector{UInt8}, n::Int)
    for i in 1:n
        h = (h ⊻ buf[i]) * 0x00000100000001b3
    end
    return h
end
const FNV0 = 0xcbf29ce484222325

# the body of `path`: (FNV-1a of the bytes) ⊻ length; -status for a status other than 200
function get_body(port::Int32, path::String)::Int64
    h = H.http_start("GET", url(port, path), NOHEADERS)
    try
        head = H.http_head(h)
        head.status == 200 || return Int64(-head.status)
        buf = Vector{UInt8}(undef, H.CHUNK)
        x, len = FNV0, 0
        while true
            n = H.http_read!(h, head, buf)
            n == 0 && break
            x = fnv(x, buf, n)
            len += n
        end
        return reinterpret(Int64, x ⊻ UInt64(len))
    finally
        IO_.close(h)
    end
end
body_small(port::Int32)::Int64 = get_body(port, "/small")
body_big(port::Int32)::Int64 = get_body(port, "/big")
body_delayed(port::Int32)::Int64 = get_body(port, "/delayed")
body_404(port::Int32)::Int64 = get_body(port, "/404")
function redirect_url(port::Int32)::Int32
    h = H.http_start("GET", url(port, "/redirect"), NOHEADERS)
    try
        head = H.http_head(h)
        return head.status == 200 && head.url == url(port, "/small") ? Int32(1) : Int32(0)
    finally
        IO_.close(h)
    end
end
# a header sent, and one received (as the server named it)
function headers(port::Int32)::Int32
    h = H.http_start("GET", url(port, "/headers"), ["X-Test" => "ünï"])
    try
        head = H.http_head(h)
        for (k, v) in head.headers
            k == "X-Echo" && return v == "ünï" ? Int32(1) : Int32(-1)
        end
        return Int32(0)
    finally
        IO_.close(h)
    end
end
# a connection refused: ECONNREFUSED (14), with the host's message
function refused(port::Int32)::Int32
    try
        get_body(Int32(1), "/")
        return Int32(0)
    catch e
        return errno_of(e) == 14 && !isempty((e::H.HostCallError).msg) ? Int32(14) : Int32(-2)
    end
end
function bad_scheme(port::Int32)::Int32
    try
        H.http_start("GET", "ftp://x/", NOHEADERS)
        return Int32(0)
    catch e
        return errno_of(e) == 58 && occursin("scheme", (e::H.HostCallError).msg) ? Int32(58) : Int32(-2)
    end
end
# the connection closed in the middle of the body: ECONNRESET (15)
function truncated(port::Int32)::Int32
    try
        get_body(port, "/trunc")
        return Int32(0)
    catch e
        return errno_of(e)
    end
end
# cancelled in the middle of the body: ECANCELED (11)
function cancel_mid(port::Int32)::Int32
    h = H.http_start("GET", url(port, "/slow"), NOHEADERS)
    try
        head = H.http_head(h)
        buf = Vector{UInt8}(undef, 4096)
        H.http_read!(h, head, buf) > 0 || return Int32(-3)
        IO_.cancel(h)
        H.http_read!(h, head, buf)
        return Int32(0)
    catch e
        return errno_of(e)
    finally
        IO_.close(h)
    end
end
# 10 bodies: the same hash each time, and the arenas restored after each
function repeat10(port::Int32)::Int64
    r0, d0 = S.load32(S.RECORD_USED), S.load32(S.DATA_USED)
    first = body_big(port)
    for i in 2:10
        body_big(port) == first || return Int64(-i)
        (S.load32(S.RECORD_USED) == r0 && S.load32(S.DATA_USED) == d0) || return Int64(-100 - i)
    end
    return first
end
# a download to `out`: its status (the driver hashes the file)
function download(port::Int32, which::Int32)::Int32
    p = which == 0 ? "/big" : which == 1 ? "/404" : "/trunc"
    try
        return Int32(H.http_download(url(port, p), string(dir(), "/out"), NOHEADERS).status)
    catch e
        return -errno_of(e)
    end
end
function decompress(port::Int32, which::Int32)::Int32
    src, dst = which == 0 ? ("a.gz", "out-gz") : which == 1 ? ("a.zst", "out-zst") :
               which == 2 ? ("plain", "out-plain") : which == 3 ? ("trunc.gz", "out-trunc") :
               which == 5 ? ("trunc.zst", "out-trunczst") : which == 6 ? ("a.gz", "out-rel") :
               which == 7 ? ("a.gz", "") : which == 8 ? ("", "out-empty") : ("../../etc/hostname", "out-escape")
    try
        # (6-8: relative and empty paths as given; the working directory is EVENT_DIR, the
        # host's PWD)
        which >= 6 ? H.decompress(src, dst) : H.decompress(string(dir(), "/", src), string(dir(), "/", dst))
        return Int32(0)
    catch e
        return errno_of(e)
    end
end
function platform_ok(port::Int32)::Int32
    want = ["arch" => "x86_64", "os" => "linux", "libc" => "musl", "libgfortran_version" => "5.0.0",
            "long" => repeat("x", 1100)]
    return H.host_platform() == want ? Int32(1) : Int32(0)
end

const CALLS = [(body_small, ()), (body_big, ()), (body_delayed, ()), (body_404, ()), (redirect_url, ()),
               (headers, ()), (refused, ()), (bad_scheme, ()), (truncated, ()), (cancel_mid, ()),
               (repeat10, ()), (download, (0,)), (download, (1,)), (download, (2,)),
               (decompress, (0,)), (decompress, (1,)), (decompress, (2,)), (decompress, (3,)),
               (decompress, (4,)), (platform_ok, ()), (decompress, (5,)), (decompress, (6,)),
               (decompress, (7,)), (decompress, (8,))]

end # EventTests

using .EventTests: EventTests as EV

@testset "host events: julia_io (sleep, waits, HTTP, downloads, decompression)" begin
    cfg = WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io])
    wc(f, at) = WasmCodegen.compile(f, at; config=cfg)
    dir = realpath(mktempdir())
    pre = Dict(dir => dir)
    run_ev(f, args...; rettype) = wasm_run(wc(f, map(typeof, args)), string(nameof(f)), args...; rettype,
                                           preopens=pre, wasi_env=Dict("EVENT_DIR" => dir))
    # sleep: as natively, and the host's event loop runs meanwhile
    @test EV.sleep_ms(Int32(30)) >= 30
    @test run_ev(EV.sleep_ms, Int32(30); rettype=Int64) >= 30
    @test EV.sleep_negative() == run_ev(EV.sleep_negative; rettype=Int32) == 1
    @test run_ev(EV.await_before; rettype=Int64) < 10_000
    @test run_ev(EV.await_unrelated; rettype=Int64) >= 30
    @test run_ev(EV.close_twice; rettype=Int32) == 8
    @test run_ev(EV.bad_handle; rettype=Int32) == 8
    @test run_ev(EV.arenas_restored; rettype=Int32) == 1
    # the module imports the events, and `poll` (whose calls suspend)
    c = wc(EV.sleep_ms, (Int32,))
    imports = Set(f.imported for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test ("julia_io", "timer_start") in imports && ("julia_io", "poll") in imports
    # the text of caught exceptions: as Base shows them
    @test run_ev(EV.error_texts; rettype=Int32) == 0
    @test LAST_OUTPUT[] == join([sprint(showerror, e) for e in EV.ERRORS], '\n') * "\nrefused (errno 14)\n"
    # the host's platform: the native one (the runner configures no tag)
    @test run_ev(EV.platform_print; rettype=Int32) == 0
    p = Base.BinaryPlatforms.HostPlatform()
    native = string("arch=", Base.BinaryPlatforms.arch(p), ";os=", Base.BinaryPlatforms.os(p), ";",
                    Sys.islinux() ? string("libc=", Base.BinaryPlatforms.libc(p), ";") : "")
    @test LAST_OUTPUT[] == native

    # HTTP, downloads and decompression: on the driver, against its server
    entries = unique(first.(EV.CALLS))
    c = WasmCodegen.compile([WasmCodegen.Entry(f, f === EV.download || f === EV.decompress ? (Int32, Int32) : (Int32,);
                                               name=string(nameof(f))) for f in entries];
                            config=WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io],
                                                      abi_version="event_abi_version" => Int32(1)))
    wasm = joinpath(mktempdir(), "event.wasm")
    write(wasm, c.bytes)
    calls = Any[Dict("fn" => string(nameof(f)), "args" => collect(args)) for (f, args) in EV.CALLS]
    calls[12]["files"] = ["out", "out.partial"]
    calls[13]["seed"] = Dict("out" => "old"); calls[13]["files"] = ["out"]
    calls[14]["seed"] = Dict("out" => "kept"); calls[14]["files"] = ["out", "out.partial"]
    calls[15]["files"] = ["out-gz"]; calls[16]["files"] = ["out-zst"]
    calls[17]["files"] = ["out-plain", "out-plain.partial"]; calls[18]["files"] = ["out-trunc", "out-trunc.partial"]
    calls[21]["seed"] = Dict("out-trunczst" => "kept"); calls[21]["files"] = ["out-trunczst", "out-trunczst.partial"]
    calls[22]["files"] = ["out-rel"]; calls[24]["files"] = ["out-empty"]
    out = IOBuffer(); err = IOBuffer()
    cmd = `$(node_cmd()) --disable-warning=ExperimentalWarning $(jspi_flags()) $(joinpath(@__DIR__, "event.mjs")) $wasm $dir $(JSON.json(calls))`
    proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    errs = String(take!(err))
    @test proc.exitcode == 0
    isempty(errs) || @info "event.mjs stderr" errs
    rs = [JSON.parse(l) for l in eachline(IOBuffer(take!(out)))]
    @test length(rs) == length(calls) + 1
    for r in rs
        haskey(r, "trap") && @error "$(r["fn"]) trapped: $(r["trap"])"
    end
    num(i) = (v = rs[i]["result"]; v isa AbstractString ? parse(Int64, v) : Int64(v))
    file(i, n) = rs[i]["files"][n]
    # the server's bodies, natively
    big = UInt8[(i * 31 + (i >> 8)) & 0xff for i in 0:6*1024*1024+122]
    expect(b) = reinterpret(Int64, EV.fnv(EV.FNV0, b, length(b)) ⊻ UInt64(length(b)))
    @test num(1) == expect(Vector{UInt8}("hello"))
    @test num(2) == expect(big)
    @test num(3) == expect(Vector{UInt8}("abc"))
    @test num(4) == -404
    @test num(5) == 1
    @test num(6) == 1
    @test num(7) == 14         # ECONNREFUSED
    @test num(8) == 58         # ENOTSUP: ftp
    @test num(9) == 15         # ECONNRESET
    @test num(10) == 11        # ECANCELED
    @test num(11) == expect(big)
    # downloads: the body in the file, published by a rename; on 404, the file removed; on a
    # failure, the previous file kept and no partial file
    @test num(12) == 200 && file(12, "out")["sha256"] == bytes2hex(sha256(big)) && file(12, "out.partial") === nothing
    @test num(13) == 404 && file(13, "out") === nothing
    @test num(14) == -15 && file(14, "out")["sha256"] == bytes2hex(sha256("kept")) && file(14, "out.partial") === nothing
    # decompression: gzip, zstd; not compressed (EILSEQ), truncated (EIO), outside the preopen
    # (ENOTCAPABLE), with no partial file left
    @test num(15) == 0 && file(15, "out-gz")["sha256"] == bytes2hex(sha256(big))
    @test num(16) == 0 && file(16, "out-zst")["sha256"] == bytes2hex(sha256("zstd!"))
    @test num(17) == 25 && file(17, "out-plain") === nothing && file(17, "out-plain.partial") === nothing
    @test num(18) == 29 && file(18, "out-trunc") === nothing && file(18, "out-trunc.partial") === nothing
    @test num(19) == 76
    # a truncated zstd frame (which Node may decode to nothing without an error): EIO, the
    # destination left as it was
    @test num(21) == 29 && file(21, "out-trunczst")["sha256"] == bytes2hex(sha256("kept")) &&
          file(21, "out-trunczst.partial") === nothing
    # relative paths: of the working directory, as natively; an empty path is not the working
    # directory but rejected (ENOTCAPABLE)
    @test num(22) == 0 && file(22, "out-rel")["sha256"] == bytes2hex(sha256(big))
    @test num(23) == 76
    @test num(24) == 76 && file(24, "out-empty") === nothing
    # the host's platform as the driver configures it (a record over 1 KiB: retried)
    @test num(20) == 1
    stats = rs[end]["result"]
    @test stats["open"] == 0
    @test stats["maxQueued"] <= 4 * 1024 * 1024

    # without the extension (and for JavaScript): unsupported, naming it
    for c in (WasmCodegen.Config(host=:wasi), WasmCodegen.Config())
        e = try
            WasmCodegen.compile(EV.sleep_ms, (Int32,); config=c)
            nothing
        catch e
            e
        end
        @test e isa WasmCodegen.UnsupportedConstructs && occursin("host_extensions = [:julia_io]", sprint(showerror, e))
    end
end

@testset "host file modes: julia_io (path_mode, path_chmod, path_symlink)" begin
    dir = realpath(mktempdir())
    pre = Dict(dir => dir)
    function setup(k)
        d = joinpath(dir, string("m", k))
        mkpath(d)
        write(joinpath(d, "f"), "x")
        chmod(joinpath(d, "f"), 0o640)
        return d
    end
    run_modes(cfg, k) = wasm_run(WasmCodegen.compile(EV.modes_print, (Int,); config=cfg), "modes_print", k;
                                 rettype=Int32, preopens=pre, wasi_env=Dict("EVENT_DIR" => dir))
    # natively
    d1 = setup(1)
    native = EV.modes(d1)
    @test native == "mode 640;chmod ok;symlink ok /nonexistent/target;"
    @test filemode(joinpath(d1, "f")) & 0o777 == 0o604
    # with the extension: the host's modes, as natively (and no events: no JSPI)
    cfg = WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io])
    c = WasmCodegen.compile(EV.modes_print, (Int,); config=cfg)
    imports = Set(f.imported for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test ("julia_io", "path_mode") in imports && ("julia_io", "path_chmod") in imports
    @test !(("julia_io", "poll") in imports)
    d2 = setup(2)
    @test run_modes(cfg, 2) == 0
    @test LAST_OUTPUT[] == native
    @test filemode(joinpath(d2, "f")) & 0o777 == 0o604
    @test readlink(joinpath(d2, "abs")) == "/nonexistent/target"
    # without it: the defaults of a host without modes (0o644, chmod ENOTSUP, WASI's links)
    d3 = setup(3)
    c = WasmCodegen.compile(EV.modes_print, (Int,); config=WasmCodegen.Config(host=:wasi))
    @test !any(f -> f.imported !== nothing && f.imported[1] == "julia_io", c.cgm.mod.funcs)
    @test run_modes(WasmCodegen.Config(host=:wasi), 3) == 0
    @test startswith(LAST_OUTPUT[], string("mode 644;chmod IOError ", Base.UV_ENOTSUP, ";symlink IOError "))
    @test filemode(joinpath(d3, "f")) & 0o777 == 0o640
    @test !islink(joinpath(d3, "abs"))
end

@testset "host events: records (natively)" begin
    # the request record of `http_start`, and the head and platform records decoded, on the
    # runtime's memory natively; every truncation of a record is rejected
    S, H = WasmCodegen.Runtime.Staging, WasmCodegen.Runtime.Host
    r0, d0 = S.load32(S.RECORD_USED), S.load32(S.DATA_USED)
    le(n) = reinterpret(UInt8, [htol(UInt32(n))])
    str(s) = vcat(le(sizeof(s)), Vector{UInt8}(s))
    S.with_scope() do
        off, n = H.put_spec("GET", "http://h/ü", ["A" => "", "Bé" => "v"], true)
        b = Vector{UInt8}(undef, n); S.copy_from_linear!(b, 1, off, Int(n))
        @test off % 4 == 0
        @test b == vcat(str("GET"), str("http://h/ü"), le(2), str("A"), str(""), str("Bé"), str("v"), le(1))
    end
    for (rec, dec, want) in ((vcat(le(301), str("http://x/"), le(1), str("Location"), str("/ü")),
                              (off, n) -> H.decode_head(off, n), H.Head(301, "http://x/", ["Location" => "/ü"])),
                             (vcat(le(2), str("arch"), str("x86_64"), str("os"), str("")),
                              (off, n) -> H.decode_platform(off, n), ["arch" => "x86_64", "os" => ""]))
        S.with_scope() do
            off = S.alloc_record(length(rec))
            S.copy_to_linear!(off, rec, 1, length(rec))
            got = dec(off, UInt32(length(rec)))
            @test got isa H.Head ? (got.status, got.url, got.headers) == (want.status, want.url, want.headers) : got == want
            @test all(k -> try dec(off, UInt32(k)); false catch e; e isa H.HostCallError end, 0:length(rec)-1)
        end
    end
    @test (S.load32(S.RECORD_USED), S.load32(S.DATA_USED)) == (r0, d0)
end
