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
    # Terminal syntax must survive resolution, including on mutation failures.
    d = joinpath(dir, "empty")
    mkdir(d)
    for tail in ("/.", "/..", "/.//")
        attempt(() -> rm(d * tail), "rm directory" * tail)
        rec("directory survives ", isdir(d))
        attempt(() -> Base.rename(d * tail, joinpath(dir, "renamed")), "rename source" * tail)
        attempt(() -> Base.rename(d, d * tail), "rename destination" * tail)
        rec("rename survives ", isdir(d))
    end
    dst = joinpath(dir, "destination")
    attempt(() -> Base.rename(joinpath(dir, "f"), dst * "/"), "rename file to missing/")
    rec("source survives ", read(joinpath(dir, "f"), String))
    attempt(() -> symlink("f", dst * "/"), "symlink missing/")
    attempt(() -> hardlink(joinpath(dir, "f"), dst * "/"), "hardlink missing/")
    mkdir(dst * "/")
    rec("mkdir slash ", isdir(dst))
    attempt(() -> Base.rename(joinpath(dir, "f"), dst * "/"), "rename file to directory/")
    attempt(() -> symlink("f", dst * "/"), "symlink directory/")
    attempt(() -> hardlink(joinpath(dir, "f"), dst * "/"), "hardlink directory/")
    rm(dst)
    Base.rename(d, dst * "/")
    rec("rename directory to missing/ ", isdir(dst), " ", !ispath(d))
    symlink("destination", d)
    attempt(() -> Base.rename(joinpath(dir, "f"), d * "/"), "rename file to link/")
    rec("unchanged ", islink(d), " ", isdir(dst), " ", isfile(joinpath(dir, "f")))
    ds = joinpath(dir, "directory-source")
    mkdir(ds)
    attempt(() -> Base.rename(ds, d * "/"), "rename directory to link/")
    rec("directory/link survive ", isdir(ds), " ", islink(d), " ", isdir(dst))
    plain = joinpath(dir, "plain")
    write(plain, "destination")
    attempt(() -> Base.rename(joinpath(dir, "f"), plain * "/"), "rename file to file/")
    attempt(() -> Base.rename(ds, plain * "/"), "rename directory to file/")
    attempt(() -> symlink("f", plain * "/"), "symlink file/")
    attempt(() -> hardlink(joinpath(dir, "f"), plain * "/"), "hardlink file/")
    rec("plain survives ", read(plain, String), " ", isdir(ds))
    target = joinpath(dir, "replace-directory")
    mkdir(target)
    Base.rename(ds, target * "/")
    rec("replace directory/ ", !ispath(ds), " ", isdir(target))

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
@noinline fake_mode(path::UInt32, len::UInt32, follow::Int32) = Int32(0o100640)
@noinline fake_chmod(path::UInt32, len::UInt32, mode::Int32) = Int32(2)   # (WASI EACCES)
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

# The raw descriptor ABI: counts, short reads, errors, and positional isolation.
function raw_io(k::Int)
    path = joinpath(ROOT, string("raw", k))
    dst = path * "-copy"
    write(path, "abcdefgh")
    f = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
    d = Base.Filesystem.open(dst, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR, 0o644)
    b = UInt8[0x58, 0x59, 0x5a]
    seek(f, 5)
    w = GC.@preserve b ccall(:jl_fs_write, Int32,
        (RawFD, Ptr{UInt8}, Csize_t, Int64), f.handle, b, 3, 1)
    ok = w == 3 && position(f) == 5
    seekstart(f)
    got = GC.@preserve b ccall(:jl_fs_read, Int32,
        (RawFD, Ptr{Cvoid}, Csize_t), f.handle, b, 3)
    ok &= got == 3 && b == UInt8[0x61, 0x58, 0x59]
    seek(f, 6)
    got = GC.@preserve b ccall(:jl_fs_read, Int32,
        (RawFD, Ptr{Cvoid}, Csize_t), f.handle, b, 3)
    ok &= got == 2 && b[1:2] == UInt8[0x67, 0x68]
    seek(f, 4)
    sent = ccall(:jl_fs_sendfile, Int32, (RawFD, RawFD, Int64, Csize_t), f.handle, d.handle, 1, 3)
    ok &= sent == 3 && position(f) == 4
    # Errors return a negative code rather than throwing through the raw ABI.
    bad = GC.@preserve b ccall(:jl_fs_read, Int32,
        (RawFD, Ptr{Cvoid}, Csize_t), RawFD(-1), b, 3)
    ok &= bad == Base.UV_EBADF
    close(d)
    bad = ccall(:jl_fs_sendfile, Int32, (RawFD, RawFD, Int64, Csize_t), f.handle, RawFD(-1), 1, 3)
    ok &= bad == Base.UV_EBADF && position(f) == 4
    close(f)
    ro = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDONLY)
    seek(ro, 2)
    bad = GC.@preserve b ccall(:jl_fs_write, Int32,
        (RawFD, Ptr{UInt8}, Csize_t, Int64), ro.handle, b, 3, 1)
    # WASI represents the missing write right as ENOTCAPABLE -> EACCES; native
    # access-mode rejection is EBADF. Both must remain errors and preserve position.
    ok &= (bad == Base.UV_EBADF || bad == Base.UV_EACCES) && position(ro) == 2
    close(ro)
    ok &= read(dst, String) == "XYZ"
    rm(path); rm(dst)
    return Int32(ok)
end

# Fault tests supplement the native comparison with deterministic host failures.
function reconcile_fault(k::Int)
    p = joinpath(ROOT, string("rewind", k))
    write(p, "abcdef")
    io = open(p, "r+")
    read(io, UInt8)
    code = try
        k == 3 ? truncate(io, 2) : k == 2 ? write(io, UInt8('X')) : k == 5 ? write(io, "X") : write(io, "XX")
        0
    catch e
        e isa SystemError ? -Int32(e.errnum) : e isa Base.IOError ? e.code : Int32(1)
    end
    # The next byte must still come from the preserved buffer after the failed rewind.
    kept = read(io, UInt8) == UInt8('b')
    close(io)
    unchanged = read(p, String) == "abcdef"
    rm(p)
    return Int32(code == (k == 4 ? Base.UV_EACCES : Base.UV_EIO) && kept && unchanged)
end

function retry_write(k::Int)
    p = joinpath(ROOT, string("retry", k))
    io = open(p, "w")
    code = try
        write(io, "abcdef")
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
    close(io)
    b = read(p, String)
    rm(p)
    # No whole-write retries: a committed prefix occurs exactly once.
    expected = k == 1 ? "abcdef" : "ab"
    error = k == 1 ? Int32(0) : k == 2 ? Base.UV_EIO : k == 3 ? Base.UV_ENOSPC : Base.UV_EAGAIN
    return Int32(code == error && b == expected)
end

function positional_fault(k::Int)
    p = joinpath(ROOT, string("positional", k))
    write(p, "abcdefgh")
    f = Base.Filesystem.open(p, Base.Filesystem.JL_O_RDWR)
    seek(f, 5)
    b = UInt8[0x58, 0x59, 0x5a]
    got = GC.@preserve b ccall(:jl_fs_write, Int32,
        (RawFD, Ptr{UInt8}, Csize_t, Int64), f.handle, b, 3, 1)
    ok = position(f) == 5 && got == (k == 1 ? 2 : Base.UV_EIO)
    close(f)
    ok &= read(p, String) == (k == 1 ? "aXYdefgh" : "abcdefgh")
    rm(p)
    return Int32(ok)
end

function short_read(k::Int)
    p = joinpath(ROOT, string("short", k))
    write(p, "abcdef")
    f = Base.Filesystem.open(p, Base.Filesystem.JL_O_RDONLY)
    b = fill(UInt8(0xa5), 6)
    got = GC.@preserve b ccall(:jl_fs_read, Int32,
        (RawFD, Ptr{Cvoid}, Csize_t), f.handle, b, 6)
    close(f); rm(p)
    return Int32(got == 2 && b == UInt8[0x61, 0x62, 0xa5, 0xa5, 0xa5, 0xa5])
end

function file_wrappers(k::Int)
    p = joinpath(ROOT, string("file-wrappers", k))
    b = UInt8[i % 251 for i in 0:1_048_592]
    f = Base.Filesystem.open(p, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR, 0o644)
    seek(f, 7)
    n = GC.@preserve b unsafe_write(f, pointer(b), UInt(length(b)), Int64(3))
    ok = n == length(b) && position(f) == 7
    seek(f, 3)
    out = similar(b)
    read!(f, out)
    ok &= out == b
    truncate(f, 0); seekstart(f)
    n = GC.@preserve b unsafe_write(f, pointer(b), UInt(length(b)), Int64(-2))
    ok &= n == length(b) && position(f) == length(b)
    seekstart(f); read!(f, out)
    ok &= out == b
    close(f); rm(p)
    return Int32(ok)
end

function sendfile_fault(k::Int)
    p = joinpath(ROOT, string("sendfile", k))
    q = p * "-copy"
    write(p, "abcdefgh")
    s = Base.Filesystem.open(p, Base.Filesystem.JL_O_RDONLY)
    d = Base.Filesystem.open(q, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR, 0o644)
    seek(s, 5)
    got = ccall(:jl_fs_sendfile, Int32, (RawFD, RawFD, Int64, Csize_t), s.handle, d.handle, 1, 3)
    expected = k == 1 ? 2 : k == 2 ? 1 : k == 3 ? Base.UV_EIO : Base.UV_ENOSPC
    ok = got == expected && position(s) == 5
    close(s); close(d)
    ok &= read(q, String) == (k == 1 ? "bc" : k == 2 ? "b" : "")
    rm(p); rm(q)
    return Int32(ok)
end

@noinline query_error(path::UInt32, len::UInt32, follow::Int32) = Int32(-29) # WASI EIO
function mode_query_fault(k::Int)
    p = joinpath(ROOT, string("mode-query", k))
    code = try
        if k == 1
            mkdir(p; mode=0o700)
        else
            f = Base.Filesystem.open(p, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_RDWR, 0o600)
            close(f)
        end
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
    # The created object remains; use readdir to avoid the failing mode provider.
    exists = basename(p) in readdir(ROOT)
    # A leaked file descriptor would occupy the next slot. Opening this existing file
    # gets the same slot as a normal closed File open (fd 4 with one preopen).
    fdok = true
    if k == 2
        f = Base.Filesystem.open(p, Base.Filesystem.JL_O_RDONLY)
        fdok = reinterpret(Int32, f.handle) == 4
        close(f)
    end
    return Int32(code == Base.UV_EIO && exists && fdok)
end

function preopen_retry(k::Int)
    code = try
        WasmCodegen.Runtime.FS.preopens()
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
    unpublished = !WasmCodegen.Runtime.FS.PREOPENS_READ[] && isempty(WasmCodegen.Runtime.FS.PREOPENS[])
    ps = WasmCodegen.Runtime.FS.preopens()
    return Int32(code == Base.UV_EIO && unpublished && length(ps) == 2 &&
        WasmCodegen.Runtime.FS.resolve(ROOT)[1] != WasmCodegen.Runtime.FS.resolve(ROOT * "/nested")[1] &&
        WasmCodegen.Runtime.FS.resolve(ROOT * "-near-miss")[1] == -1)
end

function realpath_root(k::Int)
    try
        realpath(ROOT) == ROOT ? Int32(0) : Int32(1)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
end

function large_dirent(k::Int)
    es = readdir(ROOT; sort=false)
    return Int32(length(es) == 1 && ncodeunits(es[1]) == k)
end
function dirent_error(k::Int)
    try
        readdir(ROOT)
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
end
function large_link(k::Int)
    target = readlink(joinpath(ROOT, "synthetic-link"))
    return Int32(ncodeunits(target) == k && all(==('a'), target))
end
function link_error(k::Int)
    try
        readlink(joinpath(ROOT, "synthetic-link"))
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
end
function directory_batch(k::Int)
    es = readdir(ROOT; sort=false)
    return Int32(length(es) == 2 && ncodeunits(es[1]) == k && ncodeunits(es[2]) == 20)
end
preopen_empty(k::Int) = Int32(isempty(WasmCodegen.Runtime.FS.preopens()))
function preopen_relative(k::Int)
    try
        WasmCodegen.Runtime.FS.preopens()
        Int32(0)
    catch e
        e isa Base.IOError ? e.code : Int32(1)
    end
end


# Check both WASI -> libc (even without a libuv equivalent) and UV -> libc paths.
function errno_maps(k::Int)
    F = WasmCodegen.Runtime.FS
    return Int32(F.libc_errno(62) == 130 && F.libc_errno(76) == 13 &&
        F.libc_errno(999) == 5 && F.libc_from_uv(Base.UV_EACCES) == 13 &&
        F.libc_from_uv(Base.UV_ENOTDIR) == 20 && F.libc_from_uv(-9999) == 5)
end
function errno_fault(k::Int)
    p = joinpath(ROOT, string("errno", k))
    write(p, "abcdef")
    code = Int32(0)
    if k == 2 || k == 5
        try
            io = open(k == 5 ? p * "/" : p)
            close(io)
        catch e
            code = e isa SystemError ? Int32(e.errnum) : Int32(-1)
        end
    elseif k == 4
        f = Base.Filesystem.open(p, Base.Filesystem.JL_O_RDONLY)
        try
            seek(f, 2)
        catch e
            code = e isa SystemError ? Int32(e.errnum) : Int32(-1)
        end
        close(f)
    else
        io = open(p, "r+")
        k == 7 && read(io, UInt8)
        try
            k == 3 || k == 7 ? truncate(io, 2) : position(io)
        catch e
            code = e isa SystemError ? Int32(e.errnum) : Int32(-1)
        end
        close(io)
    end
    rm(p)
    return code
end

function public_file_errors(k::Int, out::IO)
    for reading in (false, true)
        # An invalid descriptor exercises the same raw error on both hosts; a missing
        # WASI right can deliberately be EACCES where a native access mode is EBADF.
        f = Base.Filesystem.File(RawFD(-1))
        try
            reading ? read(f, UInt8) : write(f, UInt8('y'))
            println(out, "unexpected success")
        catch e
            println(out, err_text(e, "/unused-test-path"))
        end
        f.open = false
    end
    return nothing
end
public_file_errors(k::Int) = (out = IOBuffer(); public_file_errors(k, out); String(take!(out)))
public_file_errors_print(k::Int) = (public_file_errors(k, Core.stdout); Int32(0))
strerror_sum(k::Int) = Int32(sum(codeunits(Base.Libc.strerror(k))))

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
    F = WasmCodegen.Runtime.FS
    WasmCodegen.Runtime.WASM_IMPLS[F.path_mode] = fake_mode
    WasmCodegen.Runtime.WASM_IMPLS[F.path_chmod] = fake_chmod
    try
        mkpath(joinpath(ROOT, "s1")); write(joinpath(ROOT, "s1", "f"), "x")
        @test run_fs(seam_ops, 1) == 7
    finally
        delete!(WasmCodegen.Runtime.WASM_IMPLS, F.path_mode)
        delete!(WasmCodegen.Runtime.WASM_IMPLS, F.path_chmod)
    end
    @test file_wrappers(1) == 1
    @test run_fs(file_wrappers, 2) == 1
    @test retry_write(1) == 1
    @test raw_io(1) == 1
    @test run_fs(raw_io, 2) == 1
    fault_compilations = IdDict{Any,Any}()
    fault_run(f, k, faults) = wasm_run(get!(fault_compilations, f) do
        WasmCodegen.compile(f, (Int,); config=cfg)
    end, string(nameof(f)), k;
        rettype=Int32, preopens=Dict(ROOT => ROOT), wasi_faults=faults)
    for k in 1:5
        errno = k == 4 ? 76 : 29 # denied seek rights and injected EIO
        @test fault_run(reconcile_fault, k, [Dict("call" => "fd_seek", "negativeSeek" => true,
            "at" => 1, "errno" => errno)]) == 1
    end
    for k in 1:4
        faults = [Dict("call" => "fd_write", "at" => 1, "maxBytes" => 2),
                  Dict("call" => "fd_write", "at" => 2, "errno" => (k == 1 ? 27 : k == 2 ? 0 : k == 3 ? 51 : 6))]
        # Zero progress is a successful write returning zero bytes.
        k == 2 && (faults[2] = Dict("call" => "fd_write", "at" => 2, "maxBytes" => 0))
        @test fault_run(retry_write, k, faults) == 1
    end
    for k in 1:2
        rule = k == 1 ? Dict("call" => "fd_pwrite", "at" => 1, "maxBytes" => 2) :
                        Dict("call" => "fd_pwrite", "at" => 1, "errno" => 29)
        @test fault_run(positional_fault, k, [rule]) == 1
    end
    @test fault_run(short_read, 1, [Dict("call" => "fd_read", "at" => 1, "maxBytes" => 2)]) == 1
    @test fault_run(file_wrappers, 3, [Dict("call" => "fd_pwrite", "at" => 1, "maxBytes" => 2),
        Dict("call" => "fd_pwrite", "at" => 2, "errno" => 27)]) == 1
    for (k, rule) in enumerate([
        Dict("call" => "fd_pread", "at" => 1, "maxBytes" => 2),
        Dict("call" => "fd_write", "at" => 2, "maxBytes" => 1),
        Dict("call" => "fd_pread", "at" => 1, "errno" => 29),
        Dict("call" => "fd_write", "at" => 2, "errno" => 51)])
        @test fault_run(sendfile_fault, k, [rule]) == 1
    end
    # Discovery failures must neither publish partial state nor prevent a retry.
    nested = Dict(ROOT => ROOT, ROOT * "/nested" => ROOT)
    for call in ("fd_prestat_get", "fd_prestat_dir_name")
        c = WasmCodegen.compile(preopen_retry, (Int,); config=cfg)
        @test wasm_run(c, "preopen_retry", 1; rettype=Int32, preopens=nested,
            wasi_faults=[Dict("call" => call, "at" => 2, "errno" => 29)]) == 1
    end
    c = WasmCodegen.compile(preopen_empty, (Int,); config=cfg)
    @test wasm_run(c, "preopen_empty", 1; rettype=Int32, preopens=Dict{String,String}()) == 1
    c = WasmCodegen.compile(preopen_relative, (Int,); config=cfg)
    @test wasm_run(c, "preopen_relative", 1; rettype=Int32, preopens=Dict("relative" => ROOT)) == Base.UV_EINVAL
    @test realpath_root(1) == 0
    @test run_fs(realpath_root, 2) == 0
    @test fault_run(realpath_root, 1, [Dict("call" => "path_filestat_get", "at" => 1, "errno" => 29)]) == Base.UV_EIO
    WasmCodegen.Runtime.WASM_IMPLS[F.path_mode] = query_error
    try
        @test run_fs(mode_query_fault, 1) == 1
        @test run_fs(mode_query_fault, 2) == 1
    finally
        delete!(WasmCodegen.Runtime.WASM_IMPLS, F.path_mode)
    end
    # An entry larger than the initial buffer must grow rather than repeat forever.
    entry = [Dict("length" => 70_000, "next" => 917)]
    @test fault_run(large_dirent, 70_000, [Dict("call" => "fd_readdir", "at" => 1,
        "repeat" => true, "cookie" => 0, "dirents" => entry)]) == 1
    # An exactly full result needs another host call at the supplied (non-arithmetic) cookie.
    @test fault_run(large_dirent, 65_512, [
        Dict("call" => "fd_readdir", "at" => 1, "cookie" => 0,
            "dirents" => [Dict("length" => 65_512, "next" => 991)]),
        Dict("call" => "fd_readdir", "at" => 2, "cookie" => 991, "dirents" => [])]) == 1
    for first in (65_502, 65_482) # truncated header, truncated name
        @test fault_run(directory_batch, first, [
            Dict("call" => "fd_readdir", "at" => 1, "cookie" => 0,
                "dirents" => [Dict("length" => first, "next" => 53), Dict("length" => 20, "next" => 919)]),
            Dict("call" => "fd_readdir", "at" => 2, "cookie" => 53,
                "dirents" => [Dict("length" => 20, "next" => 919)])]) == 1
    end
    @test fault_run(dirent_error, 1, [Dict("call" => "fd_readdir", "at" => 1,
        "repeat" => true, "cookie" => 0,
        "dirents" => [Dict("length" => 1_048_576, "next" => 23)])]) == Base.UV_ENAMETOOLONG
    symlink("irrelevant", joinpath(ROOT, "synthetic-link"))
    for length in (4096, 4097)
        @test fault_run(large_link, length, [Dict("call" => "path_readlink", "at" => 1,
            "repeat" => true, "linkLength" => length)]) == 1
    end
    @test fault_run(link_error, 1, [Dict("call" => "path_readlink", "at" => 1,
        "repeat" => true, "linkLength" => 1_048_576)]) == Base.UV_ENAMETOOLONG
    @test errno_maps(1) == 1
    @test run_fs(errno_maps, 2) == 1
    @test errno_fault(5) == 20
    @test run_fs(errno_fault, 5) == 20
    for (k, call, at, errno, expected) in ((1, "fd_seek", 1, 62, 130),
            (2, "path_open", 2, 62, 130), (3, "fd_filestat_set_size", 1, 62, 130),
            (4, "fd_seek", 1, 62, 130), (7, "fd_seek", 1, 76, 13))
        @test fault_run(errno_fault, k, [Dict("call" => call, "at" => at, "errno" => errno)]) == expected
    end
    expected_errors = public_file_errors(1)
    @test run_fs(public_file_errors_print, 2) == 0
    @test LAST_OUTPUT[] == expected_errors
    # Simulate a platform where the host's libc text differs from the guest table.
    E = WasmCodegen.Runtime.Errno
    native_text = WasmCodegen.Runtime.Twins.original(Base.Libc.strerror, Int32(13))
    old_text = E.STRERROR[14]
    try
        E.STRERROR[14] = "guest error text"
        @test Base.Libc.strerror(13) == native_text
        c = WasmCodegen.compile(strerror_sum, (Int,); config=cfg)
        @test wasm_run(c, "strerror_sum", 13; rettype=Int32, preopens=Dict(ROOT => ROOT)) ==
            Int32(sum(codeunits("guest error text")))
    finally
        E.STRERROR[14] = old_text
    end
    # (for JavaScript, unsupported)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(fs_print, (Int,))
end

end
