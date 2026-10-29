# The filesystem over WASI (`runtime/fs.jl`, `Config(host = :wasi)`): the same operations
# natively and in Wasm, in a directory the test runner preopens at the same path, compared by
# a summary of what they did; and the defaults of a host without file modes.

module FSTests

using Test
using ..Main: wasm_run, WasmCodegen, LAST_OUTPUT

const ROOT = realpath(mktempdir(; cleanup=true))
cfg = WasmCodegen.Config(host=:wasi)
run_fs(f, k) = wasm_run(WasmCodegen.compile(f, (Int,); config=cfg), string(nameof(f)), k;
                        rettype=Int32, preopens=Dict(ROOT => ROOT))

# the error, without the directory of the run
function err_text(e, dir::String)
    e isa Base.IOError && return string("IOError(", e.code, ", ", replace(e.msg, dir => "<dir>"), ")")
    e isa SystemError && return string("SystemError(", e.errnum, ")")
    e isa ArgumentError && return "ArgumentError"
    e isa EOFError && return "EOFError"
    return "another error"
end

function fs_ops(k::Int, out::IO)
    dir = joinpath(ROOT, string("r", k))
    rec(xs...) = (print(out, xs...); println(out))
    attempt(f, what) = try
        rec(what, " => ", f())
    catch e
        rec(what, " !! ", err_text(e, dir))
    end
    mkpath(joinpath(dir, "a", "b"))
    rec("isdir ", isdir(joinpath(dir, "a", "b")), " isfile ", isfile(joinpath(dir, "a")))
    f = joinpath(dir, "a", "x.txt")
    write(f, "hello\nworld\n")
    rec("size ", filesize(f), " read ", repr(read(f, String)), " lines ", join(split(read(f, String), '\n'; keepempty=false), ","))
    open(f, "a") do io
        write(io, "more")
    end
    open(f) do io
        seek(io, 6)
        rec("seek ", repr(readline(io)), " pos ", position(io), " eof ", eof(io))
        rec("rest ", repr(read(io, String)), " eof ", eof(io))
    end
    rec("readdir ", join(readdir(joinpath(dir, "a")), ","), " join ", readdir(joinpath(dir, "a"); join=true) == [joinpath(dir, "a", "b"), f])
    g = joinpath(dir, "a", "y.txt")
    mv(f, g)
    rec("moved ", isfile(f), " ", isfile(g))
    cp(g, f)
    rec("copied ", read(f, String) == read(g, String))
    symlink("y.txt", joinpath(dir, "a", "l"))
    rec("link ", islink(joinpath(dir, "a", "l")), " ", readlink(joinpath(dir, "a", "l")), " ", isfile(joinpath(dir, "a", "l")))
    rec("realpath ", realpath(joinpath(dir, "a", "l")) == g)
    for (r, ds, fs) in walkdir(dir)
        rec("walk ", r[ncodeunits(dir)+1:end], " ", join(ds, ","), " ", join(fs, ","))
    end
    t = mktempdir(dir)
    rec("tempdir ", isdir(t), " ", startswith(t, dir))
    cd(joinpath(dir, "a")) do
        rec("cd ", pwd() == joinpath(dir, "a"), " ", isfile("y.txt"))
    end
    attempt(() -> read(joinpath(dir, "missing"), String), "missing")
    attempt(() -> mkdir(joinpath(dir, "a")), "mkdir existing")
    attempt(() -> rm(joinpath(dir, "a")), "rm non-empty")
    rm(joinpath(dir, "a"); recursive=true)
    rec("removed ", ispath(joinpath(dir, "a")))
    attempt(() -> isfile("/definitely-outside-the-preopens"), "outside")
    # `.` and `..` after a file or a missing name, as natively
    write(joinpath(dir, "f"), "kept")
    attempt(() -> stat(joinpath(dir, "f", ".")).size, "stat file/.")
    attempt(() -> rm(joinpath(dir, "f", ".")), "rm file/.")
    rec("survives ", isfile(joinpath(dir, "f")))
    attempt(() -> read(joinpath(dir, "missing", "..", "f"), String), "read missing/../f")
    attempt(() -> read(joinpath(dir, "f", "..", "f"), String), "read f/../f")
    rm(dir; recursive=true)
    return nothing
end
fs_ops(k::Int) = (out = IOBuffer(); fs_ops(k, out); String(take!(out)))
# (in Wasm, each record written out at once)
fs_print(k::Int) = (fs_ops(k, Core.stdout); Int32(0))

# a host without file modes: files 0o644, directories 0o755, chmod is ENOTSUP
function fs_modes(k::Int)
    dir = joinpath(ROOT, string("m", k))
    mkpath(dir)
    f = joinpath(dir, "f")
    write(f, "x")
    mf, md = filemode(f) & 0o777, filemode(dir) & 0o777
    e = try
        chmod(f, 0o600)
        0
    catch err
        err isa Base.IOError ? Int(err.code) : 1
    end
    x = Sys.isexecutable(f)
    rm(dir; recursive=true)
    return Int32(mf == 0o644) + Int32(md == 0o755) * 2 + Int32(e == Base.UV_ENOTSUP) * 4 + Int32(!x) * 8
end

# `tempdir`/`homedir` of the environment, with a trailing separator after a multibyte name
dirs(k::Int) = Int32(sizeof(tempdir()) * 100 + sizeof(homedir()))

# the seams for a host with file modes: replacements are called (a mode, and a chmod that
# fails, also when a new file is to get its mode)
# (read from globals, as a host's answers are read: a method of `WASM_METHODS` is no more
# `:consistent` than the native one, see `@wasm_method`)
const FAKE_MODE = Ref(Int32(0o100640))
const FAKE_CHMOD = Ref(Int32(2))   # (WASI EACCES)
fake_mode(path::UInt32, len::UInt32, follow::Int32) = FAKE_MODE[]
fake_chmod(path::UInt32, len::UInt32, mode::Int32) = FAKE_CHMOD[]
# (the directory and the file made natively before)
function seam_ops(k::Int)
    dir = joinpath(ROOT, string("s", k))
    f = joinpath(dir, "f")
    m = filemode(f) & 0o777
    e = try
        chmod(f, 0o600)
        0
    catch err
        err isa Base.IOError ? Int(err.code) : 1
    end
    t = try
        mktemp(dir)
        0
    catch err
        # (mktemp's error is a SystemError, as natively)
        err isa SystemError ? -Int(err.errnum) : err isa Base.IOError ? Int(err.code) : 1
    end
    return Int32(m == 0o640) + Int32(e == Base.UV_EACCES) * 2 + Int32(t == Base.UV_EACCES) * 4
end

@testset "filesystem over WASI" begin
    expected = fs_ops(1)
    @test run_fs(fs_print, 2) == 0
    @test LAST_OUTPUT[] == replace(expected, "r1" => "r2")
    LAST_OUTPUT[] == replace(expected, "r1" => "r2") ||
        println(Core.stdout, "filesystem: native ", repr(expected), "\n wasm ", repr(LAST_OUTPUT[]))
    @test run_fs(fs_modes, 1) == 15
    # (the environment of the native run, the module's host's)
    env = Dict("TMPDIR" => "/α/", "HOME" => "/home/β/")
    native = withenv(() -> dirs(1), env...)
    c = WasmCodegen.compile(dirs, (Int,); config=cfg)
    @test wasm_run(c, "dirs", 1; rettype=Int32, wasi_env=env) == native
    # the seams of a host with file modes: methods of `WASM_METHODS`, for this test only
    F = WasmCodegen.Runtime.FS
    methods_of(mt) = (ms = Method[]; Base.visit(m -> push!(ms, m), mt); ms)
    before = methods_of(WasmCodegen.Runtime.WASM_METHODS)
    @eval WasmCodegen.Runtime.@wasm_method $F.path_mode(path::UInt32, len::UInt32, follow::Int32) =
        $fake_mode(path, len, follow)
    @eval WasmCodegen.Runtime.@wasm_method $F.path_chmod(path::UInt32, len::UInt32, mode::Int32) =
        $fake_chmod(path, len, mode)
    try
        mkpath(joinpath(ROOT, "s1")); write(joinpath(ROOT, "s1", "f"), "x")
        @test run_fs(seam_ops, 1) == 7
    finally
        foreach(Base.delete_method, setdiff(methods_of(WasmCodegen.Runtime.WASM_METHODS), before))
    end
    @test methods_of(WasmCodegen.Runtime.WASM_METHODS) == before
    # (for JavaScript, unsupported)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(fs_print, (Int,))
end

end
