# The host's events (`runtime/event.jl`, the `julia_io` imports of `js/julia_io.mjs`, for
# `Config(host = :wasi, host_extensions = [:julia_io])`): `sleep`, waits on handles, the text
# of caught exceptions, and the host's file modes in the filesystem. What runs natively too is
# compared with native Julia.

module EventTests

using Test
using ..Main: wasm_run, LAST_OUTPUT, WasmCodegen
const R = WasmCodegen.Runtime
const H = R.Host
const IO_ = R.JuliaIO
const S = R.Staging

errno_of(e) = e isa H.HostCallError ? e.errno : Int32(-1)
ms_since(t0::UInt64) = Int64((time_ns() - t0) ÷ 1_000_000)

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
                   ArgumentError("bad"), KeyError(:k), KeyError("k"), KeyError(3), EOFError(),
                   Base.IOError("read: connection reset by peer (ECONNRESET)", -104), DivideError()]
function error_texts()::Int32
    for e in ERRORS
        println(Core.stdout, H.error_text(e))
    end
    println(Core.stdout, H.error_text(H.HostCallError(Int32(14), "refused")))
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
