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


# seeks and skips of an `IOStream` relative to its 64 KiB read buffer (inside it, before and
# after it, at and after the end), with writes between them, and reads into byte arrays,
# arrays of other types and views; paths not in normal form
function io_seeks(k::Int, out::IO)
    dir = joinpath(ROOT, string("io", k))
    rec(xs...) = (print(out, xs...); println(out))
    attempt(f, what) = try
        rec(what, " => ", f())
    catch e
        rec(what, " !! ", err_text(e, dir))
    end
    mkpath(dir)
    n = 150_000   # (three buffers)
    f = joinpath(dir, "data.bin")
    write(f, UInt8[i % 251 for i in 0:n-1])
    at(io) = (position(io), eof(io))
    open(f) do io
        rec("start ", read(io, UInt8), " ", at(io))
        seek(io, 1000); rec("in fwd ", read(io, UInt8), " ", at(io))
        seek(io, 10); rec("in back ", read(io, UInt8), " ", at(io))
        seek(io, 0); rec("buffer start ", read(io, UInt8), " ", at(io))
        seek(io, 65535); rec("buffer last ", read(io, UInt8), " ", at(io))
        seek(io, 65536); rec("buffer end ", read(io, UInt8), " ", at(io))
        seek(io, 140_000); rec("after ", read(io, UInt8), " ", at(io))
        seek(io, 5); rec("before ", read(io, UInt8), " ", at(io))
        skip(io, 100); rec("skip in ", read(io, UInt8), " ", at(io))
        skip(io, -50); rec("skip back ", read(io, UInt8), " ", at(io))
        skip(io, 100_000); rec("skip after ", read(io, UInt8), " ", at(io))
        skip(io, -100_000); rec("skip before ", read(io, UInt8), " ", at(io))
        attempt(() -> skip(io, -10_000), "skip before 0")
        rec("after failed skip ", at(io))
        mark(io); skip(io, 30); reset(io); rec("mark/reset ", read(io, UInt8), " ", at(io))
        # at and after the end
        seekend(io); rec("seekend ", at(io))
        seek(io, n - 3); rec("tail ", read(io, 3), " ", at(io))
        seek(io, n - 2); rec("in after eof ", read(io, UInt8), " ", at(io))
        seek(io, n); rec("at end ", at(io))
        attempt(() -> read(io, UInt8), "read at end")
        seek(io, n + 10); rec("past end ", at(io))
        attempt(() -> read(io, UInt8), "read past end")
        seek(io, n - 1); rec("back from past end ", read(io, UInt8), " ", at(io))
        attempt(() -> seek(io, -1), "seek before 0")
        # reads into a byte array, a view, an array of other bytes; spanning buffers
        seek(io, 65_000)
        b = Vector{UInt8}(undef, 2000); read!(io, b)
        rec("bytes ", sum(b), " ", b[1], " ", b[end], " ", at(io))
        skip(io, -1500)
        v = zeros(UInt8, 300); read!(io, view(v, 101:200))
        rec("view ", sum(v), " ", v[100], " ", v[101], " ", v[200], " ", v[201], " ", at(io))
        u = Vector{UInt32}(undef, 40); read!(io, u)
        rec("uint32 ", sum(u), " ", u[1], " ", at(io))
        r = Ref{UInt64}(0); unsafe_read(io, r, 8)
        rec("ref ", r[], " ", at(io))
        rec("readbytes ", readbytes!(io, b, 70_000), " ", length(b), " ", sum(b), " ", at(io))
        seek(io, n - 100); rec("readbytes at end ", readbytes!(io, b, 500), " ", at(io))
        # scalars across the end of a full buffer (its compaction), then back by a seek and a skip
        seek(io, 0); read(io, UInt8); skip(io, 65_533)
        rec("scalar across ", read(io, UInt64), " ", at(io))
        seek(io, 65_534); rec("scalar again ", read(io, UInt64), " ", at(io))
        skip(io, -8); rec("scalar skip back ", read(io, UInt32), " ", at(io))
        # the rest, with bytes buffered (its compaction)
        seek(io, 70_000); read(io, UInt8); x = read(io)
        rec("read rest ", length(x), " ", sum(x), " ", at(io))
        # into the bytes of a String (not a memory of bytes)
        seek(io, 7)
        s = Base._string_n(4)
        got = GC.@preserve s ccall(:ios_readall, Csize_t, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, pointer(s), 4)
        rec("string ", Int(got), " ", Vector{UInt8}(codeunits(s)), " ", at(io))
    end
    # writes and reads mixed, on a read/write stream
    open(f, "r+") do io
        rec("rw read ", read(io, 100) == UInt8[i % 251 for i in 0:99], " ", at(io))
        seek(io, 50); write(io, "XYZ"); rec("rw write in buffer ", at(io))
        rec("rw read after write ", read(io, UInt8), " ", at(io))
        seek(io, 45); rec("rw read back ", String(read(io, 10)), " ", at(io))
        skip(io, -5); write(io, 0xee); rec("rw skip write ", at(io))
        seek(io, 40); rec("rw again ", read(io, 20), " ", at(io))
        seek(io, 70_000); write(io, "far"); seek(io, 69_998); rec("rw far ", read(io, 7), " ", at(io))
        seekend(io); write(io, "tail"); rec("rw append ", at(io))
        seek(io, n - 2); rec("rw end ", read(io), " ", at(io))
        seek(io, n + 4 + 3); write(io, 0x01); rec("rw hole ", at(io), " ", filesize(io))
        seek(io, n); rec("rw hole read ", read(io), " ", at(io))
    end
    rec("file ", filesize(f), " ", sum(read(f)))
    # another handle changes buffered bytes: a seek reads them again, a skip keeps the buffer
    open(f) do io
        read(io, UInt8)
        open(w -> (seek(w, 1); write(w, 0x5a)), f, "r+")
        seek(io, 1); rec("seek after change ", read(io, UInt8), " ", at(io))
        open(w -> (seek(w, 3); write(w, 0x5b)), f, "r+")
        skip(io, 1); rec("skip after change ", read(io, UInt8), " ", at(io))
    end
    # paths not in normal form
    p = string(dir, "/./sub//x/../")
    mkpath(joinpath(dir, "sub", "x"))
    rec("paths ", isdir(p), " ", isfile(string(dir, "//data.bin")), " ", isfile(string(dir, "/sub/../data.bin")),
        " ", filesize(string(dir, "/.//data.bin")), " ", isdir(string(dir, "/sub/.")), " ", ispath(string(dir, "/sub/x/../../nope")))
    rm(dir; recursive=true)
    return nothing
end
io_seeks(k::Int) = (out = IOBuffer(); io_seeks(k, out); String(take!(out)))
io_seeks_print(k::Int) = (io_seeks(k, Core.stdout); Int32(0))

@testset "IOStream seeks and the read buffer" begin
    expected = io_seeks(1)
    @test run_fs(io_seeks_print, 2) == 0
    @test LAST_OUTPUT[] == expected
    LAST_OUTPUT[] == expected || println(Core.stdout, "seeks: native ", repr(expected), "\n wasm ", repr(LAST_OUTPUT[]))
end

# `normalize` returns a path in normal form as it is, and normalizes the others as before
function normalize_lexical(p::String)
    parts = String[]
    for c in eachsplit(p, '/')
        (isempty(c) || c == ".") && continue
        c == ".." ? (isempty(parts) || pop!(parts)) : push!(parts, String(c))
    end
    return "/" * join(parts, "/")
end
@testset "normalize" begin
    FS = WasmCodegen.Runtime.FS
    comps = ["", ".", "..", "...", ".a", "..a", "a.", "a..", "a", "bc", "ü", "."^4]
    bad, n = String[], 0
    for len in 0:4, _ in 1:2000
        p = "/" * join(rand(comps, len), "/")
        rand(Bool) && (p *= "/")
        q = normalize_lexical(p)
        (FS.normalize(p) == q && FS.is_normal(p) == (q == p)) || push!(bad, p)
        n += FS.is_normal(p)
    end
    @test isempty(bad)
    @test n > 0
    @test FS.is_normal("/") && FS.is_normal("/a/b.c/..d") && !FS.is_normal("a") && !FS.is_normal("")
    @test !FS.is_normal("//") && !FS.is_normal("/a/") && !FS.is_normal("/a/./b") && !FS.is_normal("/..")
end
function all_false_once(k::Int)
    p = joinpath(ROOT, string("all-false", k))
    write(p, UInt8[i % 251 for i in 0:149_999])
    io = open(p)
    b = fill(UInt8(0xa5), 100_000)
    n = readbytes!(io, b, 100_000; all=false)
    ok = 0 < n <= 100_000 && position(io) == n &&
        all(i -> b[i] == UInt8((i - 1) % 251), 1:n) && all(==(0xa5), b[n+1:end])
    close(io); rm(p)
    return Int32(ok)
end

# An all=false read may return a different positive short count on each host.
# Every returned byte and the logical position must agree with that count.
function byte_offsets(k::Int)
    p = joinpath(ROOT, string("byte-offsets", k))
    write(p, UInt8[i % 251 for i in 0:149_999])
    io = open(p)
    b = fill(UInt8(0xa5), 100_020)
    n = readbytes!(io, b, 100_000; all=false)
    ok = 0 < n <= 100_000 && position(io) == n
    ok &= all(i -> b[i] == UInt8((i - 1) % 251), 1:n)
    ok &= all(==(0xa5), b[n+1:end])
    seekstart(io)
    c = fill(UInt8(0xa5), 48)
    got = GC.@preserve c ccall(:ios_readall, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{Cvoid}(pointer(c) + 7), 20)
    ok &= got == 20 && c[8:27] == UInt8.(0:19)
    ok &= all(==(0xa5), c[1:7]) && all(==(0xa5), c[28:end])
    before = copy(c)
    zero = GC.@preserve c ccall(:ios_read, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{Cvoid}(pointer(c) + 11), 0)
    ok &= zero == 0 && c == before && position(io) == 20
    # Keep byte-memory provenance through a non-byte pointer cast in this function.
    got = GC.@preserve c ccall(:ios_read, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{UInt32}(pointer(c) + 3), 9)
    ok &= got == 9 && c[4:12] == UInt8.(20:28)
    ok &= c[1:3] == before[1:3] && c[13:end] == before[13:end]
    # popfirst! can shift an Array's storage start within its Memory.
    shifted = fill(UInt8(0xa5), 80)
    for _ in 1:17
        popfirst!(shifted)
    end
    ok &= Core.memoryrefoffset(shifted.ref) > 1
    seekstart(io)
    got = GC.@preserve shifted ccall(:ios_readall, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{Cvoid}(pointer(shifted) + 5), 13)
    ok &= got == 13 && shifted[6:18] == UInt8.(0:12)
    ok &= all(==(0xa5), shifted[1:5]) && all(==(0xa5), shifted[19:end])
    # A byte pointer cast over word storage must retain the pointer fallback.
    words = fill(UInt32(0xa5a5a5a5), 10)
    seekstart(io)
    got = GC.@preserve words ccall(:ios_readall, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{UInt8}(pointer(words)) + 5, 7)
    ok &= got == 7 && words[1] == 0xa5a5a5a5 && words[2] == 0x020100a5 && words[3] == 0x06050403
    ok &= all(==(0xa5a5a5a5), words[4:end])
    close(io); rm(p)
    return Int32(ok)
end

# Keep the direct call small enough to inspect the selected IO helper in the output.
function direct_byte_read(k::Int)
    io = open(joinpath(ROOT, "direct-bytes"))
    b = fill(UInt8(0xa5), 32)
    got = GC.@preserve b ccall(:ios_readall, Csize_t,
        (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), io.ios, Ptr{Cvoid}(pointer(b) + 7), 10)
    close(io)
    return Int32(got == 10 && b[8:17] == UInt8.(0:9) &&
        all(==(0xa5), b[1:7]) && all(==(0xa5), b[18:end]))
end

@testset "short byte reads and explicit offsets" begin
    @test all_false_once(1) == 1
    short = WasmCodegen.compile(all_false_once, (Int,); config=cfg)
    @test wasm_run(short, "all_false_once", 2; rettype=Int32, preopens=Dict(ROOT => ROOT),
        wasi_faults=[Dict("call" => "fd_read", "at" => 2, "trap" => "all=false read twice")]) == 1
    @test any(mi -> mi.def isa Method && mi.def.module === WasmCodegen.Runtime.FS && mi.def.name === :ios_read &&
        MemoryRef{UInt8} in mi.specTypes.parameters, keys(short.cgm.funcs))
    @test byte_offsets(1) == 1
    @test run_fs(byte_offsets, 2) == 1
    write(joinpath(ROOT, "direct-bytes"), UInt8.(0:31))
    @test direct_byte_read(1) == 1
    c = WasmCodegen.compile(direct_byte_read, (Int,); config=cfg)
    @test wasm_run(c, "direct_byte_read", 2; rettype=Int32, preopens=Dict(ROOT => ROOT)) == 1
    @test any(mi -> mi.def isa Method && mi.def.module === WasmCodegen.Runtime.FS && mi.def.name === :ios_readall &&
        MemoryRef{UInt8} in mi.specTypes.parameters, keys(c.cgm.funcs))
    @test occursin("array.copy", sprint(WasmCodegen.WasmBuilder.print_wat, c.cgm.mod))
end

@testset "normalize fixed inputs" begin
    F = WasmCodegen.Runtime.FS
    saved = F.CWD[]
    F.CWD[] = ROOT
    try
        for (path, expected) in (("", ROOT), (".", ROOT), ("a/../b", ROOT * "/b"),
                ("α/.", ROOT * "/α"), (String(UInt8[0x2f, 0xff]), String(UInt8[0x2f, 0xff])),
                (String(UInt8[0x2f, 0xff, 0x2f, 0x2e]), String(UInt8[0x2f, 0xff])), ("/a\0", "/a\0"))
            @test F.normalize(path) == expected
            @test F.is_normal(path) == (path == expected)
        end
    finally
        F.CWD[] = saved
    end
end

end
