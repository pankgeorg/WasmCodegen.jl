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

# `IOStream`s, buffered as ios.c buffers them (32 KiB, writes held until a flush, a seek or a
# close): what a stream holds, reads and writes out, seen through other handles on the file

# write `b` at `pos` of `f`, through a handle of its own
poke(f::String, pos::Int, b::UInt8) = (open(h -> (seek(h, pos); write(h, b)), f, "r+"); nothing)

function ios_ops(k::Int, out::IO)
    dir = joinpath(ROOT, string("i", k))
    mkpath(dir)
    rec(xs...) = (print(out, xs...); println(out))
    attempt(f, what) = try
        rec(what, " => ", f())
    catch e
        rec(what, " !! ", err_text(e, dir))
    end
    # a byte changed behind the stream 40 000 bytes in (past what native buffers), read
    # after a skip or a `read!` from the first byte
    z = joinpath(dir, "z")
    write(z, zeros(UInt8, 100_000))
    open(z) do io
        read(io, UInt8)
        poke(z, 40_000, 0x7f)
        skip(io, 39_999)
        rec("skip ", read(io, UInt8), " ", position(io), " ", bytesavailable(io))
    end
    open(z) do io
        read(io, UInt8)
        poke(z, 40_001, 0x7e)
        read!(io, Vector{UInt8}(undef, 40_000))
        rec("read! ", read(io, UInt8), " ", position(io), " ", bytesavailable(io))
    end
    # a read of more than most of the buffer (read directly, nothing buffered), then a skip back
    open(z) do io
        b = read!(io, Vector{UInt8}(undef, 40_000))
        poke(z, 39_999, 0x55)
        rec("direct ", b[end], " ", bytesavailable(io))
        skip(io, -1)
        rec("skip back ", read(io, UInt8), " ", bytesavailable(io))
    end
    # reads of most of the buffer and across its end, then skips into what native holds and
    # past it
    write(z, zeros(UInt8, 100_000))
    open(z) do io
        read!(io, Vector{UInt8}(undef, 30_000))
        rec("most ", bytesavailable(io))
        foreach(p -> poke(z, p, 0x01), (29_999, 32_767, 32_768, 33_000))
        skip(io, -1)
        rec("back ", read(io, UInt8), " ", bytesavailable(io))
        skip(io, 2_767)
        rec("end ", read(io, UInt8), " ", read(io, UInt8), " ", bytesavailable(io))
        skip(io, -1_000)
        rec("again ", read(io, UInt8), " ", position(io))
        b = read!(io, Vector{UInt8}(undef, 2_000))
        rec("across ", sum(b), " ", bytesavailable(io), " ", position(io))
        foreach(p -> poke(z, p, 0x02), (33_500, 64_000, 66_000))
        skip(io, 33_500 - position(io))
        rec("held ", read(io, UInt8), " ", bytesavailable(io))
        skip(io, 64_000 - position(io))
        rec("far ", read(io, UInt8), " ", bytesavailable(io))
        skip(io, 66_000 - position(io))
        rec("past ", read(io, UInt8), " ", bytesavailable(io))
    end
    # integers across the buffer's end (the rest moved back, the buffer refilled)
    write(z, UInt8[i % UInt8 for i in 0:99_999])
    open(z) do io
        read(io, UInt8)
        skip(io, 32_765)
        rec("int ", read(io, Int32), " ", read(io, UInt16), " ", bytesavailable(io))
        poke(z, 65_000, 0xaa)
        poke(z, 65_600, 0xbb)
        skip(io, 65_000 - position(io))
        rec("moved ", read(io, UInt8), " ", bytesavailable(io))
        skip(io, 65_600 - position(io))
        rec("then ", read(io, UInt8), " ", read(io, Int64), " ", bytesavailable(io))
    end
    # one read call (`all=false`): directly when large
    open(z) do io
        b = UInt8[]
        rec("some ", readbytes!(io, b, 50_000; all=false), " ", bytesavailable(io))
        rec("some ", readbytes!(io, b, 100; all=false), " ", bytesavailable(io))
        rec("some ", readbytes!(io, b, 40_000; all=false), " ", bytesavailable(io), " ", position(io))
    end
    # writes, held until a flush or a close; past the buffer, what it holds goes first, then
    # a large write directly
    g = joinpath(dir, "g")
    open(g, "w") do io
        write(io, "hello")
        rec("unflushed ", repr(read(g, String)), " ", position(io), " ", filesize(io))
        flush(io)
        rec("flushed ", repr(read(g, String)), " ", position(io))
        write(io, " world")
        write(io, UInt8('!'))
        rec("again ", repr(read(g, String)), " ", position(io), " ", bytesavailable(io))
    end
    rec("closed ", repr(read(g, String)))
    open(g, "w") do io
        write(io, "abc")
        write(io, fill(UInt8('x'), 40_000))
        rec("large ", filesize(g), " ", position(io))
        write(io, fill(UInt8('y'), 30_000))
        rec("most ", filesize(g))
        write(io, fill(UInt8('z'), 5_000))
        rec("over ", filesize(g), " ", position(io))
        for _ in 1:30_000
            write(io, UInt8('w'))
        end
        rec("putc ", filesize(g), " ", position(io))
    end
    rec("all ", filesize(g))
    tp, tio = mktemp(dir)
    write(tio, "temp")
    rec("mktemp ", filesize(tp), " ", position(tio))
    close(tio)
    rec("mktemp closed ", filesize(tp))
    # a write then a read on one stream, and seeks, skips and positions around held writes
    h = joinpath(dir, "h")
    write(h, "abcdefghij")
    open(h, "r+") do io
        rec("r+ ", repr(String(read(io, 2))))
        write(io, "XY")
        rec("written ", repr(read(h, String)), " ", position(io), " ", bytesavailable(io))
        rec("read ", repr(String(read(io, 3))), " ", position(io), " ", repr(read(h, String)))
        seek(io, 0)
        write(io, "12345")
        skip(io, -3)
        write(io, "Z")
        rec("skips ", position(io), " ", bytesavailable(io), " ", repr(read(h, String)))
        skip(io, 1)
        write(io, "W")
        rec("skip in ", position(io), " ", repr(read(h, String)))
        flush(io)
        rec("flush ", position(io), " ", repr(read(h, String)))
        seek(io, 0)
        write(io, "l1\nl2\n")
        skip(io, -6)
        rec("lines ", repr(readline(io)), " ", repr(readline(io; keep=true)), " ", position(io), " ",
            repr(read(h, String)))
        write(io, "Q")
        rec("peek ", peek(io), " ", position(io), " ", repr(read(h, String)))
        seek(io, 14)
        write(io, "e")
        rec("end ", position(io), " ", filesize(io), " ", filesize(h))
    end
    rec("r+ closed ", repr(read(h, String)))
    # lines, delimiters, peek, eof, mark and reset; a line across the buffer's end
    t = joinpath(dir, "t")
    write(t, "one\r\ntwo\nthree,four;five\n", "y"^40_000, "\nlast")
    open(t) do io
        rec("readline ", repr(readline(io)), " ", repr(readline(io; keep=true)), " ", bytesavailable(io))
        rec("readuntil ", repr(String(readuntil(io, UInt8(',')))), " ", repr(String(readuntil(io, UInt8(';'); keep=true))))
        rec("peek ", peek(io), " ", position(io), " eof ", eof(io))
        mark(io)
        rec("marked ", repr(readline(io)), " ", position(io))
        reset(io)
        rec("reset ", position(io), " ", bytesavailable(io), " ", repr(readline(io)))
        rec("long ", length(readline(io)), " ", position(io), " ", bytesavailable(io))
        rec("last ", repr(readline(io)), " eof ", eof(io), " ", repr(readline(io)), " ", bytesavailable(io))
        attempt(() -> peek(io), "peek at the end")
        attempt(() -> read(io, UInt8), "read at the end")
    end
    open(t) do io
        rec("available ", length(readavailable(io)), " ", length(readavailable(io)), " ", bytesavailable(io))
        rec("rest ", length(read(io)), " eof ", eof(io))
        seek(io, 3)
        rec("from 3 ", length(read(io, String)))
    end
    # the end of the input stays until a seek, unless `eof` reads more
    s = joinpath(dir, "s")
    write(s, "ab")
    open(s) do io
        seekend(io)
        open(a -> write(a, "cd"), s, "a")
        attempt(() -> read(io, UInt8), "sticky")
        rec("eof ", eof(io), " ", bytesavailable(io))
        rec("then ", read(io, UInt8), " ", position(io))
        rec("rest ", repr(read(io, String)), " eof ", eof(io))
        open(a -> write(a, "e"), s, "a")
        attempt(() -> read(io, UInt8), "grown")
        rec("eof again ", eof(io))
        attempt(() -> read(io, UInt8), "read again")
    end
    # truncation, with held writes and with read data past the new end (below the position:
    # a negative count of bytes available, natively)
    u = joinpath(dir, "u")
    open(u, "w+") do io
        write(io, fill(UInt8('a'), 100))
        truncate(io, 50)
        rec("truncate ", position(io), " ", filesize(io), " ", filesize(u))
        write(io, "b")
        rec("after ", position(io), " ", filesize(u))
    end
    rec("truncated ", filesize(u), " ", count(==(0x00), read(u)))
    write(u, fill(UInt8('c'), 1_000))
    open(u, "r+") do io
        read(io, 10)
        truncate(io, 500)
        rec("read truncate ", position(io), " ", bytesavailable(io), " ", length(read(io)), " eof ", eof(io))
    end
    open(u, "r+") do io
        read(io, 10)
        truncate(io, 5)
        rec("below ", bytesavailable(io), " ", position(io), " ", filesize(io))
    end
    # a closed stream keeps its state: its cached position, its flags
    cio = open(h, "r+")
    seek(cio, 5)
    close(cio)
    rec("closed ", isopen(cio), " ", isreadable(cio), " ", iswritable(cio), " ", eof(cio), " ", bytesavailable(cio))
    attempt(() -> position(cio), "closed position")
    attempt(() -> write(cio, "x"), "closed write")
    attempt(() -> position(cio), "closed position after")
    attempt(() -> read(cio, UInt8), "closed read")
    attempt(() -> length(read(cio)), "closed read all")
    attempt(() -> (skip(cio, 0); 0), "closed skip 0")
    attempt(() -> (seek(cio, 0); 0), "closed seek")
    attempt(() -> (flush(cio); 0), "closed flush")
    attempt(() -> (close(cio); 0), "closed close")
    # errors
    open(h) do io
        attempt(() -> (seek(io, -1); position(io)), "seek -1")
        read(io, UInt8)
        attempt(() -> (skip(io, -5); position(io)), "skip before the start")
        rec("pos ", position(io), " ", bytesavailable(io))
        attempt(() -> write(io, "x"), "write read-only")
    end
    open(g, "w") do io
        attempt(() -> read(io, UInt8), "read write-only")
        rec("eof write-only ", eof(io))
    end
    rm(dir; recursive=true)
    return nothing
end
ios_ops(k::Int) = (out = IOBuffer(); ios_ops(k, out); String(take!(out)))
ios_print(k::Int) = (ios_ops(k, Core.stdout); Int32(0))

# `err_text`, with an `ArgumentError`'s message (the NULs')
function msg_text(e, dir::String)
    if e isa ArgumentError
        msg = e.msg
        msg isa String && return replace(msg, dir => "<dir>")
    end
    return err_text(e, dir)
end

# what lexical normalization would change (`.` and `..` after a symbolic link; `.` and `..`
# last, which are removed or renamed by no call), NULs in paths, `readdir`'s order, and
# descriptors: the results and errors of their writes and reads, their times
function fs_edges(k::Int, out::IO)
    dir = joinpath(ROOT, string("e", k))
    mkpath(dir)
    rec(xs...) = (print(out, xs...); println(out))
    attempt(f, what) = try
        rec(what, " => ", f())
    catch e
        rec(what, " !! ", msg_text(e, dir))
    end
    p(xs...) = joinpath(dir, xs...)
    foreach(mkdir, (p("e"), p("e2"), p("e4"), p("a"), p("a", "b")))
    write(p("a", "x"), "ax")
    write(p("x"), "top")
    symlink("a/b", p("link"))
    symlink("a", p("la"))
    attempt(() -> (rm(p("e", ".")); 0), "rm e/.")
    attempt(() -> (rm(p("e", "..")); 0), "rm e/..")
    attempt(() -> (rm(p("e", ".") * "/"); 0), "rm e/./")
    attempt(() -> cd(() -> (rm("."); 0), p("e4")), "rm . in e4")
    attempt(() -> ccall(:jl_fs_unlink, Int32, (Cstring,), p("e", ".")), "unlink e/.")
    attempt(() -> ccall(:jl_fs_unlink, Int32, (Cstring,), p("e", "..")), "unlink e/..")
    attempt(() -> ccall(:jl_fs_rename, Int32, (Cstring, Cstring), p("e2", "."), p("e3")), "rename e2/.")
    attempt(() -> ccall(:jl_fs_rename, Int32, (Cstring, Cstring), p("x"), p("e2", "..")), "rename to e2/..")
    rec("still ", isdir(p("e")), " ", isdir(p("e2")), " ", isdir(p("e4")), " ", isfile(p("x")))
    attempt(() -> read(p("link", "..", "x"), String), "read link/../x")
    attempt(() -> read(p("la", "..", "x"), String), "read la/../x")
    attempt(() -> islink(p("link", ".")), "islink link/.")
    attempt(() -> join(readdir(p("link", "..")), ","), "readdir link/..")
    attempt(() -> (rm(p("link", ".")); 0), "rm link/.")
    attempt(() -> cd(() -> read("../x", String), p("link")), "cd link, read ../x")
    rec("link ", islink(p("link")), " ", isdir(p("a", "b")))
    # (NULs: the error of their conversion to a C string, before any call)
    attempt(() -> readdir("a\0b"), "nul readdir")
    attempt(() -> readlink("a\0b"), "nul readlink")
    attempt(() -> realpath("a\0b"), "nul realpath")
    attempt(() -> (cd("a\0b"); 0), "nul cd")
    attempt(() -> cd(() -> 0, "a\0b"), "nul cd(f)")
    attempt(() -> mktempdir("a\0b"), "nul mktempdir")
    attempt(() -> (mktemp("a\0b"); 0), "nul mktemp")
    attempt(() -> mktempdir(dir; prefix="p\0"), "nul mktempdir prefix")
    # (in libuv's order, `strcmp`'s, unsorted by Base)
    mkdir(p("o"))
    for n in ("z", "a", "B", "_x", "Z1", "aa", "é", "0")
        write(p("o", n), "")
    end
    rec("readdir ", join(readdir(p("o"); sort=false), ","))
    # descriptors: what `jl_fs_write` returns; errors of a closed one
    w = p("w")
    f = Base.Filesystem.open(w, Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_CREAT, 0o644)
    b = Vector{UInt8}("abcdef")
    n1 = GC.@preserve b ccall(:jl_fs_write, Int32, (Base.OS_HANDLE, Ptr{UInt8}, Csize_t, Int64),
                              f.handle, pointer(b), 3, -1)
    n2 = GC.@preserve b ccall(:jl_fs_write, Int32, (Base.OS_HANDLE, Ptr{UInt8}, Csize_t, Int64),
                              f.handle, pointer(b), 2, 10)
    rec("jl_fs_write ", n1, " ", n2, " ", position(f), " ", repr(read(w, String)))
    # (whole seconds: Node's WASI sets no fraction)
    attempt(() -> (Base.Filesystem.futime(f, 100.0, 200.0); mtime(w)), "futime")
    attempt(() -> (Base.Filesystem.futime(f, NaN, NaN); mtime(w)), "futime NaN")
    attempt(() -> (Base.Filesystem.futime(f, Inf, 1.0); mtime(w)), "futime Inf")
    close(f)
    g = Base.Filesystem.open(w, Base.Filesystem.JL_O_RDONLY)
    ccall(:jl_fs_close, Int32, (Base.OS_HANDLE,), g.handle)
    attempt(() -> read(g, UInt8), "read closed fd")
    attempt(() -> write(g, 0x01), "write closed fd")
    attempt(() -> (close(g); 0), "close closed fd")
    rm(dir; recursive=true)
    return nothing
end
fs_edges(k::Int) = (out = IOBuffer(); fs_edges(k, out); String(take!(out)))
edges_print(k::Int) = (fs_edges(k, Core.stdout); Int32(0))

# a time before 1970: natively set, over WASI (unsigned times) EINVAL
function before_epoch(k::Int)
    f = joinpath(ROOT, string("t", k))
    write(f, "")
    h = Base.Filesystem.open(f, Base.Filesystem.JL_O_RDWR)
    r = try
        Base.Filesystem.futime(h, -1.5, -1.5)
        Int32(0)
    catch e
        e isa Base.IOError ? (print(Core.stdout, e.msg); e.code) : Int32(1)
    end
    close(h)
    rm(f)
    return r
end

# the modes of new files and directories, asked of a host with modes: natively those they
# get; in Wasm those a host gets through the chmod seam (`FS.path_chmod`), which then tells
# them (`FS.path_mode`; no mode of other paths)
const SET_MODES = Dict{String,Int32}()
function rec_chmod(path::UInt32, len::UInt32, mode::Int32)
    SET_MODES[WasmCodegen.Runtime.FS.get_raw(path, len)] = mode
    return Int32(0)
end
function rec_mode(path::UInt32, len::UInt32, follow::Int32)
    F = WasmCodegen.Runtime.FS
    m = get(SET_MODES, F.get_raw(path, len), Int32(-1))
    ft = F.filetype(F.get_raw(path, len), follow != 0)
    (m < 0 || ft isa Int32) && return -F.NO_MODES
    return Int32(F.type_bits(ft)) | m
end
function created_modes(k::Int)
    dir = joinpath(ROOT, string("c", k))
    mkpath(dir)
    mode(f) = string(filemode(f) & 0o777; base=8)
    tp, tio = mktemp(dir)
    close(tio)
    td = mktempdir(dir)
    mkdir(joinpath(dir, "m"); mode=0o751)
    close(Base.Filesystem.open(joinpath(dir, "o"), Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_WRONLY, 0o640))
    r = string(mode(tp), " ", mode(td), " ", mode(joinpath(dir, "m")), " ", mode(joinpath(dir, "o")))
    rm(dir; recursive=true)
    return r
end
modes_print(k::Int) = (print(Core.stdout, created_modes(k)); Int32(0))

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
# (an `IOStream` writes out at a flush, as ios.c: after a short write the rest, again after
# an interruption, a host not ready (EAGAIN) or no progress; an error is the flush's, after
# the bytes written before it)
function retry_write(k::Int)
    p = joinpath(ROOT, string("retry", k))
    io = open(p, "w")
    code = try
        write(io, "abcdef")
        flush(io)
        Int32(0)
    catch e
        e isa SystemError ? Int32(e.errnum) : e isa Base.IOError ? e.code : Int32(1)
    end
    close(io)
    b = read(p, String)
    rm(p)
    # No whole-write retries: a committed prefix occurs exactly once.
    expected = k == 3 ? "ab" : "abcdef"
    error = k == 3 ? Int32(28) : Int32(0)   # (ENOSPC)
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
    # (a short write continued, as libuv's `uv__fs_write_all`; an error before any, the error)
    ok = position(f) == 5 && got == (k == 1 ? 3 : Base.UV_EIO)
    close(f)
    ok &= read(p, String) == (k == 1 ? "aXYZefgh" : "abcdefgh")
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
    # (an existing file, made without a query of its mode)
    probe = p * "-probe"
    close(open(probe, "w"))
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
    # The created object is removed (not left with another mode); use readdir to avoid the
    # failing mode provider.
    removed = !(basename(p) in readdir(ROOT))
    # A leaked file descriptor would occupy the next slot. Opening an existing file gets the
    # same slot as a normal closed File open (fd 4 with one preopen).
    fdok = true
    if k == 2
        f = Base.Filesystem.open(probe, Base.Filesystem.JL_O_RDONLY)
        fdok = reinterpret(Int32, f.handle) == 4
        close(f)
    end
    return Int32(code == Base.UV_EIO && removed && fdok)
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
    # (in `strcmp`'s order, as libuv's `uv_fs_scandir` gives them: the shorter name first)
    return Int32(length(es) == 2 && ncodeunits(es[1]) == 20 && ncodeunits(es[2]) == k)
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
            # (a seek of the host: a skip past the buffer; `position` is ios.c's cached one)
            k == 3 ? truncate(io, 2) : skip(io, 100)
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
    # (and without them, the defaults again: the code inferred with them is not reused)
    @test run_fs(fs_modes, 1) == 15
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
    # (a method of `WASM_METHODS` for this test only; a deleted method stays visible, so the
    # methods before it are taken again)
    before_query = methods_of(WasmCodegen.Runtime.WASM_METHODS)
    @eval WasmCodegen.Runtime.@wasm_method $F.path_mode(path::UInt32, len::UInt32, follow::Int32) =
        $query_error(path, len, follow)
    try
        @test run_fs(mode_query_fault, 1) == 1
        @test run_fs(mode_query_fault, 2) == 1
    finally
        foreach(Base.delete_method, setdiff(methods_of(WasmCodegen.Runtime.WASM_METHODS), before_query))
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
    native_text = WasmCodegen.Runtime.original(Base.Libc.strerror, Int32(13))
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

@testset "IOStream buffering over WASI" begin
    expected = ios_ops(1)
    @test run_fs(ios_print, 2) == 0
    @test LAST_OUTPUT[] == expected
    # (the records that differ)
    for (n, w) in zip(split(expected, '\n'), split(LAST_OUTPUT[], '\n'))
        n == w || println(Core.stdout, "IOStream: native ", repr(n), "\n wasm ", repr(w))
    end
end

@testset "paths and descriptors over WASI, as natively" begin
    expected = fs_edges(1)
    @test run_fs(edges_print, 2) == 0
    @test LAST_OUTPUT[] == expected
    for (n, w) in zip(split(expected, '\n'), split(LAST_OUTPUT[], '\n'))
        n == w || println(Core.stdout, "paths: native ", repr(n), "\n wasm ", repr(w))
    end
    # (a time before 1970: EINVAL, where natively it is set)
    @test run_fs(before_epoch, 1) == Base.UV_EINVAL
    @test LAST_OUTPUT[] == "futime: invalid argument (EINVAL)"
    # the modes asked of a host with modes (seams, for this test only), as natively given
    expected = created_modes(1)
    F = WasmCodegen.Runtime.FS
    methods_of(mt) = (ms = Method[]; Base.visit(m -> push!(ms, m), mt); ms)
    before = methods_of(WasmCodegen.Runtime.WASM_METHODS)
    @eval WasmCodegen.Runtime.@wasm_method $F.path_mode(path::UInt32, len::UInt32, follow::Int32) =
        $rec_mode(path, len, follow)
    @eval WasmCodegen.Runtime.@wasm_method $F.path_chmod(path::UInt32, len::UInt32, mode::Int32) =
        $rec_chmod(path, len, mode)
    try
        @test run_fs(modes_print, 2) == 0
        @test LAST_OUTPUT[] == expected
    finally
        foreach(Base.delete_method, setdiff(methods_of(WasmCodegen.Runtime.WASM_METHODS), before))
    end
end

end
