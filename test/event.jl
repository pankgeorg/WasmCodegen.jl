# The host's events (`runtime/event.jl`, the `julia_io` imports of `js/julia_io.mjs`, for
# `Config(host = :wasi, host_extensions = [:julia_io])`): `sleep`, waits on handles, the text
# of caught exceptions, and the host's file modes in the filesystem. What runs natively too is
# compared with native Julia: Base's functions before the session's patches
# (`Runtime.original`), not the patched ones the module is compiled from.

module EventTests

using Test
using ..Main: wasm_run, LAST_OUTPUT, WasmCodegen
const R = WasmCodegen.Runtime
const H = R.Host
const IO_ = R.JuliaIO
const S = R.Staging

errno_of(e) = e isa H.HostCallError ? e.errno : Int32(-1)
ms_since(t0::UInt64) = Int64((time_ns() - t0) ÷ 1_000_000)

"Base's function `f` natively: as it is before the session's patches."
native(f) = (args...) -> R.original(f, args...)

## sleep and waits (through the test runner; natively too where it applies)

function sleep_ms(ms::Int32)::Int64
    t0 = time_ns()
    sleep(ms / 1000)
    return ms_since(t0)
end

# what `sleep` (`sleep_f`) does with each of these: their milliseconds overflow, or do not
# convert to `UInt64` (`Timer`'s conversion), or are negative; `2^62` seconds wrap around to
# 1 ms natively
const SLEEP_ARGS = (-1.0, NaN, -Inf, Inf, 1e17, 0.0, -0.0, -1, typemax(Int), typemax(Int) ÷ 1000 + 1, 2^62, 0)
function sleep_outcomes(io, sleep_f)
    for sec in SLEEP_ARGS
        try
            sleep_f(sec)
            print(io, "slept")
        catch e
            if e isa ArgumentError
                m = (e::ArgumentError).msg
                print(io, "ArgumentError: ", m isa String ? m : "?")
            elseif e isa InexactError
                # (of Base's conversion, the same code natively)
                print(io, "InexactError: ", (e::InexactError).func)
            else
                print(io, "another error")
            end
        end
        println(io)
    end
end
sleep_errors() = (sleep_outcomes(Core.stdout, sleep); Int32(0))

# a host timer of 10 ms, polled without waiting between `sleep(0)`s: it fires, as `sleep(0)`
# lets the host's event loop run (as libuv's runs in it natively); the `sleep(0)`s before
# (-1: it did not fire within 2 s)
function sleep_zero_yields()::Int64
    h = IO_.timer_start(Int64(10_000_000))
    try
        t0 = time_ns()
        n = 0
        while time_ns() - t0 < 2_000_000_000
            polled(h) && return n
            sleep(0)
            n += 1
        end
        return Int64(-1)
    finally
        IO_.close(h)
    end
end
# whether the handle `h` is ready: a `poll` that does not wait
polled(h::Int32) = S.with_scope() do
    interest = S.alloc_record(4)
    out = S.alloc_record(4)
    S.store32(interest, h % UInt32)
    IO_.poll(interest, Int32(1), Int64(0), out, Int32(1)) == 1
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
        H.close(h)
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
                   SystemError("reading", 5, 7), ArgumentError("bad"), AssertionError("x > 0"),
                   OverflowError("too big"), DimensionMismatch("1 ≠ 2"), ErrorException(SubString("plain text", 1, 5)),
                   ConcurrencyViolationError("lock"), KeyError(:k), KeyError(Symbol("a b")), KeyError(:+),
                   KeyError("k"), KeyError(3), KeyError('c'), KeyError(1.5), KeyError(nothing), EOFError(),
                   UndefRefError(), Base.IOError("read: connection reset by peer (ECONNRESET)", -104),
                   DivideError(), H.HostCallError(Int32(14), "refused")]
function error_texts()::Int32
    for e in ERRORS
        println(Core.stdout, H.error_text(e))
    end
    return Int32(0)
end

## the host's file modes and symbolic links (`FS.path_mode`, `FS.path_chmod`,
## `FS.path_symlink_io`): the host's with the extension, the defaults without

# the filesystem's functions of Base: the module's, and those of native Julia
const BASE_FS = (; filemode, chmod, symlink, readlink, islink)
const NATIVE_FS = (; filemode=native(filemode), chmod=native(chmod), symlink=native(symlink),
                   readlink=native(readlink), islink=native(islink))

ioerror(err) = err isa Base.IOError ? string("IOError ", err.code) : "another error"

# the mode of `dir/f` (made 0o640 natively), then `chmod` to 0o604, and a link to an
# absolute target out of the preopen
function modes(io, dir::String, fs=BASE_FS)
    f = joinpath(dir, "f")
    print(io, "mode ", string(fs.filemode(f) & 0o777; base=8), ";")
    e = try
        fs.chmod(f, 0o604)
        "ok"
    catch err
        ioerror(err)
    end
    print(io, "chmod ", e, ";")
    e = try
        fs.symlink("/nonexistent/target", joinpath(dir, "abs"))
        string("ok ", fs.readlink(joinpath(dir, "abs")))
    catch err
        ioerror(err)
    end
    print(io, "symlink ", e, ";")
end

# the same of a file and a link whose names are not UTF-8 (`\xff`, made 0o640 natively)
function raw_names(io, dir::String, fs=BASE_FS)
    f = joinpath(dir, "\xff")
    print(io, "mode ", string(fs.filemode(f) & 0o777; base=8), ";")
    fs.chmod(f, 0o604)
    print(io, "chmod ", string(fs.filemode(f) & 0o777; base=8), ";")
    l = joinpath(dir, "l\xfe")
    fs.symlink("t\xfd", l)
    print(io, "link ", fs.islink(l), " ", fs.readlink(l) == "t\xfd", ";")
end

# `chmod` through links that do not resolve, and of paths whose lookup fails (made natively
# in `dir`): the lookup's errors
const LOOKUPS = ("dangling", "dangling-abs", "loop", "f/x", "missing/x")
function lookups(io, dir::String, fs=BASE_FS)
    for name in LOOKUPS
        e = try
            fs.chmod(joinpath(dir, name), 0o600)
            "ok"
        catch err
            ioerror(err)
        end
        print(io, name, " ", e, ";")
    end
end

# `chmod` through links out of the preopen (to a file there, to none, by `..`): not permitted
# in the module (EACCES), whether or not the target exists
const ESCAPES = ("out", "out-missing", "out-up")
function escapes(io, dir::String)
    for name in ESCAPES
        e = try
            chmod(joinpath(dir, name), 0o600)
            "ok"
        catch err
            ioerror(err)
        end
        print(io, name, " ", e, ";")
    end
end

event_dir(k::Int) = string(ENV["EVENT_DIR"], "/m", k)
modes_print(k::Int) = (modes(Core.stdout, event_dir(k)); Int32(0))
raw_names_print(k::Int) = (raw_names(Core.stdout, event_dir(k)); Int32(0))
lookups_print(k::Int) = (lookups(Core.stdout, event_dir(k)); Int32(0))
escapes_print(k::Int) = (escapes(Core.stdout, event_dir(k)); Int32(0))

end # EventTests

using .EventTests: EventTests as EV

@testset "host events: julia_io (sleep, waits)" begin
    cfg = WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io])
    wc(f, at) = WasmCodegen.compile(f, at; config=cfg)
    dir = realpath(mktempdir())
    pre = Dict(dir => dir)
    run_ev(f, args...; rettype) = wasm_run(wc(f, map(typeof, args)), string(nameof(f)), args...; rettype,
                                           preopens=pre, wasi_env=Dict("EVENT_DIR" => dir))
    # sleep: as natively, and the host's event loop runs meanwhile
    t0 = time_ns()
    EV.native(sleep)(0.03)
    @test EV.ms_since(t0) >= 30
    @test run_ev(EV.sleep_ms, Int32(30); rettype=Int64) >= 30
    # its checks and conversion, as natively, for durations of floats and integers
    native = sprint(io -> EV.sleep_outcomes(io, EV.native(sleep)))
    @test count("InexactError", native) == 4 && count("ArgumentError", native) == 4
    @test run_ev(EV.sleep_errors; rettype=Int32) == 0
    @test LAST_OUTPUT[] == native
    # `sleep(0)` lets the host's events progress: a timer fires between them, as natively
    t = Timer(0.01)
    n, t0 = 0, time_ns()
    while !t.set && time_ns() - t0 < 2_000_000_000
        EV.native(sleep)(0)
        n += 1
    end
    @test t.set
    close(t)
    @test run_ev(EV.sleep_zero_yields; rettype=Int64) > 0
    @test run_ev(EV.await_before; rettype=Int64) < 10_000
    @test run_ev(EV.await_unrelated; rettype=Int64) >= 30
    @test run_ev(EV.close_twice; rettype=Int32) == 8
    @test run_ev(EV.bad_handle; rettype=Int32) == 8
    @test run_ev(EV.arenas_restored; rettype=Int32) == 1
    # the module imports the events, and `poll` (whose calls suspend)
    c = wc(EV.sleep_ms, (Int32,))
    imports = Set(f.imported for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test ("julia_io", "timer_start") in imports && ("julia_io", "poll") in imports
    # the text of caught exceptions: as `showerror` shows them natively
    @test run_ev(EV.error_texts; rettype=Int32) == 0
    @test LAST_OUTPUT[] == join([EV.native(sprint)(showerror, e) * "\n" for e in EV.ERRORS])

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
    outside = realpath(mktempdir())
    write(joinpath(outside, "g"), "x")
    chmod(joinpath(outside, "g"), 0o640)
    function setup(k)
        d = joinpath(dir, string("m", k))
        mkpath(d)
        for name in ("f", "\xff")
            write(joinpath(d, name), "x")
            chmod(joinpath(d, name), 0o640)
        end
        symlink("missing", joinpath(d, "dangling"))
        symlink(joinpath(d, "missing"), joinpath(d, "dangling-abs"))
        symlink("loop2", joinpath(d, "loop"))
        symlink("loop", joinpath(d, "loop2"))
        symlink(joinpath(outside, "g"), joinpath(d, "out"))
        symlink(joinpath(outside, "missing"), joinpath(d, "out-missing"))
        symlink(joinpath("..", "..", basename(outside), "g"), joinpath(d, "out-up"))
        return d
    end
    run_print(f, cfg, k) = wasm_run(WasmCodegen.compile(f, (Int,); config=cfg), string(nameof(f)), k;
                                    rettype=Int32, preopens=pre, wasi_env=Dict("EVENT_DIR" => dir))
    nfs = EV.NATIVE_FS
    # natively
    d1 = setup(1)
    native = sprint(io -> EV.modes(io, d1, nfs))
    @test native == "mode 640;chmod ok;symlink ok /nonexistent/target;"
    @test nfs.filemode(joinpath(d1, "f")) & 0o777 == 0o604
    native_raw = sprint(io -> EV.raw_names(io, d1, nfs))
    @test native_raw == "mode 640;chmod 604;link true true;"
    native_lookups = sprint(io -> EV.lookups(io, d1, nfs))
    @test native_lookups == string("dangling IOError ", Base.UV_ENOENT, ";dangling-abs IOError ", Base.UV_ENOENT,
                                   ";loop IOError ", Base.UV_ELOOP, ";f/x IOError ", Base.UV_ENOTDIR,
                                   ";missing/x IOError ", Base.UV_ENOENT, ";")
    # the seams: the methods of the extension's table with it, the defaults without it
    F = WasmCodegen.Runtime.FS
    sig = (UInt32, UInt32, Int32)
    @test WasmCodegen.entry_instance(F.path_mode, sig; extensions=[:julia_io]).def.external_mt ===
          WasmCodegen.Runtime.JuliaIO.METHODS
    @test !isdefined(WasmCodegen.entry_instance(F.path_mode, sig).def, :external_mt)
    # with the extension: the host's modes, as natively (and no events: no JSPI)
    cfg = WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io])
    c = WasmCodegen.compile(EV.modes_print, (Int,); config=cfg)
    imports = Set(f.imported for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test ("julia_io", "path_mode") in imports && ("julia_io", "path_chmod") in imports
    @test !(("julia_io", "poll") in imports)
    d2 = setup(2)
    @test run_print(EV.modes_print, cfg, 2) == 0
    @test LAST_OUTPUT[] == native
    @test nfs.filemode(joinpath(d2, "f")) & 0o777 == 0o604
    @test nfs.readlink(joinpath(d2, "abs")) == "/nonexistent/target"
    # names that are not UTF-8: their bytes, as natively
    @test run_print(EV.raw_names_print, cfg, 2) == 0
    @test LAST_OUTPUT[] == native_raw
    @test nfs.filemode(joinpath(d2, "\xff")) & 0o777 == 0o604
    @test nfs.readlink(joinpath(d2, "l\xfe")) == "t\xfd"
    # the lookup's errors, as natively; out of the preopen, not permitted, and nothing changed
    @test run_print(EV.lookups_print, cfg, 2) == 0
    @test LAST_OUTPUT[] == native_lookups
    @test run_print(EV.escapes_print, cfg, 2) == 0
    @test LAST_OUTPUT[] == join((string(name, " IOError ", Base.UV_EACCES, ";") for name in EV.ESCAPES))
    @test nfs.filemode(joinpath(outside, "g")) & 0o777 == 0o640
    # without it: the defaults of a host without modes (0o644, chmod ENOTSUP, WASI's links)
    d3 = setup(3)
    c = WasmCodegen.compile(EV.modes_print, (Int,); config=WasmCodegen.Config(host=:wasi))
    @test !any(f -> f.imported !== nothing && f.imported[1] == "julia_io", c.cgm.mod.funcs)
    @test run_print(EV.modes_print, WasmCodegen.Config(host=:wasi), 3) == 0
    @test startswith(LAST_OUTPUT[], string("mode 644;chmod IOError ", Base.UV_ENOTSUP, ";symlink IOError "))
    @test nfs.filemode(joinpath(d3, "f")) & 0o777 == 0o640
    @test !nfs.islink(joinpath(d3, "abs"))
end
