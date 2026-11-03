# The filesystem through the host, for `Config(host = :wasi)`: WASI preview 1 for files and
# directories, with paths resolved against the host's preopened directories and a virtual
# working directory. WASI has no permission bits: those come from three seams (`path_mode`,
# `path_chmod`, `path_symlink_io`, below), whose defaults say the host has none. The C
# functions Base calls (`jl_stat`, `uv_fs_mkdir`, `ios_file`, ...) are implemented here
# (`RUNTIME_CCALLS`, see `foreigncall.jl`); the Base functions that read C structures
# (`readdir`, `realpath`, `mktempdir`, ...) are patched to call these (`trim/wasm-fs.jl`).
# This code only runs in Wasm.

module FS

using ..Runtime: Staging, WASI, Errno, Env
import ..Runtime

## host functions

const SYMLINK_FOLLOW = UInt32(1)

# open flags (`oflags`) and rights
const O_CREAT = UInt32(1)
const O_DIRECTORY = UInt32(2)
const O_EXCL = UInt32(4)
const O_TRUNC = UInt32(8)
const RIGHTS_ALL = typemax(UInt64) >> 35   # the rights of WASI preview 1 (29 bits)
const FDFLAGS_APPEND = UInt32(1)
const FDFLAGS_DSYNC = UInt32(2)
const FDFLAGS_SYNC = UInt32(16)

# filetypes of WASI
const FT_UNKNOWN = 0x00
const FT_BLOCK = 0x01
const FT_CHAR = 0x02
const FT_DIR = 0x03
const FT_FILE = 0x04
const FT_DGRAM = 0x05
const FT_STREAM = 0x06
const FT_LINK = 0x07

fd_prestat_get(fd::Int32, buf::UInt32) =
    ccall((:fd_prestat_get, "wasi_snapshot_preview1"), Int32, (Int32, UInt32), fd, buf)
fd_prestat_dir_name(fd::Int32, path::UInt32, len::UInt32) =
    ccall((:fd_prestat_dir_name, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32), fd, path, len)
path_filestat_get(fd::Int32, flags::UInt32, path::UInt32, len::UInt32, buf::UInt32) =
    ccall((:path_filestat_get, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32, UInt32),
          fd, flags, path, len, buf)
fd_filestat_get(fd::Int32, buf::UInt32) =
    ccall((:fd_filestat_get, "wasi_snapshot_preview1"), Int32, (Int32, UInt32), fd, buf)
path_open(dirfd::Int32, dirflags::UInt32, path::UInt32, len::UInt32, oflags::UInt32, base::UInt64,
          inheriting::UInt64, fdflags::UInt32, fd::UInt32) =
    ccall((:path_open, "wasi_snapshot_preview1"), Int32,
          (Int32, UInt32, UInt32, UInt32, UInt32, UInt64, UInt64, UInt32, UInt32),
          dirfd, dirflags, path, len, oflags, base, inheriting, fdflags, fd)
fd_fdstat_get(fd::Int32, buf::UInt32) =
    ccall((:fd_fdstat_get, "wasi_snapshot_preview1"), Int32, (Int32, UInt32), fd, buf)
fd_close(fd::Int32) = ccall((:fd_close, "wasi_snapshot_preview1"), Int32, (Int32,), fd)
fd_read(fd::Int32, iovs::UInt32, n::UInt32, nread::UInt32) =
    ccall((:fd_read, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32), fd, iovs, n, nread)
fd_write(fd::Int32, iovs::UInt32, n::UInt32, nwritten::UInt32) =
    ccall((:fd_write, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32), fd, iovs, n, nwritten)
fd_pread(fd::Int32, iovs::UInt32, n::UInt32, offset::UInt64, nread::UInt32) =
    ccall((:fd_pread, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt64, UInt32), fd, iovs, n, offset, nread)
fd_pwrite(fd::Int32, iovs::UInt32, n::UInt32, offset::UInt64, nwritten::UInt32) =
    ccall((:fd_pwrite, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt64, UInt32), fd, iovs, n, offset, nwritten)
fd_seek(fd::Int32, offset::Int64, whence::UInt32, newoffset::UInt32) =
    ccall((:fd_seek, "wasi_snapshot_preview1"), Int32, (Int32, Int64, UInt32, UInt32), fd, offset, whence, newoffset)
fd_filestat_set_size(fd::Int32, size::UInt64) =
    ccall((:fd_filestat_set_size, "wasi_snapshot_preview1"), Int32, (Int32, UInt64), fd, size)
fd_filestat_set_times(fd::Int32, atim::UInt64, mtim::UInt64, flags::UInt32) =
    ccall((:fd_filestat_set_times, "wasi_snapshot_preview1"), Int32, (Int32, UInt64, UInt64, UInt32),
          fd, atim, mtim, flags)
fd_sync(fd::Int32) = ccall((:fd_sync, "wasi_snapshot_preview1"), Int32, (Int32,), fd)
fd_readdir(fd::Int32, buf::UInt32, len::UInt32, cookie::UInt64, used::UInt32) =
    ccall((:fd_readdir, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt64, UInt32),
          fd, buf, len, cookie, used)
path_create_directory(fd::Int32, path::UInt32, len::UInt32) =
    ccall((:path_create_directory, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32), fd, path, len)
path_remove_directory(fd::Int32, path::UInt32, len::UInt32) =
    ccall((:path_remove_directory, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32), fd, path, len)
path_unlink_file(fd::Int32, path::UInt32, len::UInt32) =
    ccall((:path_unlink_file, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32), fd, path, len)
path_rename(fd::Int32, old::UInt32, oldlen::UInt32, newfd::Int32, new::UInt32, newlen::UInt32) =
    ccall((:path_rename, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, Int32, UInt32, UInt32),
          fd, old, oldlen, newfd, new, newlen)
path_symlink(old::UInt32, oldlen::UInt32, fd::Int32, new::UInt32, newlen::UInt32) =
    ccall((:path_symlink, "wasi_snapshot_preview1"), Int32, (UInt32, UInt32, Int32, UInt32, UInt32),
          old, oldlen, fd, new, newlen)
path_readlink(fd::Int32, path::UInt32, len::UInt32, buf::UInt32, buflen::UInt32, used::UInt32) =
    ccall((:path_readlink, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32, UInt32, UInt32),
          fd, path, len, buf, buflen, used)
path_link(oldfd::Int32, flags::UInt32, old::UInt32, oldlen::UInt32, newfd::Int32, new::UInt32, newlen::UInt32) =
    ccall((:path_link, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32, Int32, UInt32, UInt32),
          oldfd, flags, old, oldlen, newfd, new, newlen)
## the host's file modes and symbolic links of any target: seams
#
# WASI preview 1 has no file modes, and its `path_symlink` refuses targets that are absolute
# or leave the preopen. These three functions are where a host with more (its own imports)
# plugs in, with methods the module compiles in place of these. They take an absolute,
# normalized path in the linear memory. Their defaults: no modes (`NO_MODES`), so files are
# 0o644, directories 0o755 and links 0o777 (`stat`), `chmod` fails with ENOTSUP and the modes
# of new files are the host's; symbolic links through WASI's `path_symlink`.

"The errno of a host without file modes (ENOSYS)."
const NO_MODES = Int32(52)
# (read through a global, so that inference does not fold the defaults' results into their
# callers: a replacement must still be called)
const NO_MODES_RESULT = Ref(NO_MODES)

"The mode at the absolute path (following a link if `follow`), or a negated WASI errno."
@noinline path_mode(path::UInt32, len::UInt32, follow::Int32) = -NO_MODES_RESULT[]
"Give the file at the absolute path the mode `mode`: 0, or a positive WASI errno."
@noinline path_chmod(path::UInt32, len::UInt32, mode::Int32) = NO_MODES_RESULT[]
"A link at the absolute path `link` to `target` (any string): 0, or a positive WASI errno."
@noinline path_symlink_io(target::UInt32, tlen::UInt32, link::UInt32, llen::UInt32) = NO_MODES_RESULT[]

"""
The rights a file opened in the directory `fd` can have: the directory's inheriting rights
(asking for more is ENOTCAPABLE on hosts that check them, as Node's does).
"""
function inheriting_rights(fd::Int32)
    fd_fdstat_get(fd, Staging.SCRATCH_OUT) == 0 || return RIGHTS_ALL
    return Staging.load64(Staging.SCRATCH_OUT + UInt32(16))
end

# the rights that make a host open a file for writing (fd_datasync, fd_write, fd_allocate,
# fd_filestat_set_size) and for reading (fd_read, fd_readdir)
const WRITE_RIGHTS = UInt64(1) << 0 | UInt64(1) << 6 | UInt64(1) << 8 | UInt64(1) << 22
const READ_RIGHTS = UInt64(1) << 1 | UInt64(1) << 14

"The rights to open a file in the directory `fd` with: for reading and/or writing only."
function open_rights(fd::Int32, read::Bool, write::Bool)
    r = inheriting_rights(fd)
    write || (r &= ~WRITE_RIGHTS)
    read || (r &= ~READ_RIGHTS)
    return r
end

"The platform libuv code of the WASI errno `e`."
uv(e::Integer) = Errno.uv_code(e)

# WASI and libuv results have distinct conversions to the fixed guest libc ABI.
libc_errno(e::Integer) = Errno.guest_errno(e)
libc_from_uv(code::Integer) = Errno.uv_to_guest_errno(code)

"The `n` bytes at `off` of the linear memory, as a string."
get_raw(off::UInt32, n::Integer) = String(get_bytes(off, Int(n)))
get_bytes(off::UInt32, n::Int) = (b = Vector{UInt8}(undef, n); Staging.copy_from_linear!(b, 1, off, n); b)
"The NUL-terminated string at `off`."
function get_cstring(off::UInt32)
    n = 0
    while Staging.load8(off + UInt32(n)) != 0x00
        n += 1
    end
    return get_raw(off, n)
end

## preopened directories and the working directory

"The preopened directories: (fd, absolute path), read from the host on first use."
const PREOPENS = Ref(Tuple{Int32,String}[])
const PREOPENS_READ = Ref(false)
"The working directory (absolute, normalized; empty: not set yet)."
const CWD = Ref("")

# Preview 1 hosts conventionally assign contiguous preopens starting at fd 3.
# EBADF ends that enumeration; other failures leave the previous table unpublished.
function preopens()
    PREOPENS_READ[] && return PREOPENS[]
    found = Tuple{Int32,String}[]
    fd = Int32(3)
    while true
        r = fd_prestat_get(fd, Staging.SCRATCH_OUT)
        r == 8 && break # EBADF
        Runtime.wasi_check(r, "fd_prestat_get")
        if Staging.load8(Staging.SCRATCH_OUT) == 0x00
            name = prestat_name(fd, Staging.load32(Staging.SCRATCH_OUT + UInt32(4)))
            startswith(name, '/') || throw(Base.IOError("preopen name must be absolute", Int32(Base.UV_EINVAL)))
            push!(found, (fd, normalize(name)))
        end
        fd += Int32(1)
    end
    PREOPENS[] = found
    PREOPENS_READ[] = true
    return found
end

prestat_name(fd::Int32, n::UInt32) = Staging.with_scope() do
    off = Staging.alloc_record(n; align=1)
    Runtime.wasi_check(fd_prestat_dir_name(fd, off, n), "fd_prestat_dir_name")
    get_raw(off, n)
end

"The value of the variable `name` of the environment (`ENV`, see `Env`), or `nothing`."
host_env(name::String) = Env.get(name)

"The working directory: `PWD` of the host's environment, else the first preopen, else `/`."
function cwd()
    if isempty(CWD[])
        pwd = host_env("PWD")
        CWD[] = pwd !== nothing && startswith(pwd, '/') ? normalize(pwd) :
                isempty(preopens()) ? "/" : preopens()[1][2]
    end
    return CWD[]
end

"""
    normalize(path) -> String

The absolute path of `path` (relative to the working directory), with `.`, `..` and repeated
separators removed lexically (as WASI resolves them), without a trailing separator (which
`check_path` checks).

This differs from native resolution after a symbolic link: natively `link/..` is the parent
of the link's target, here (and in WASI hosts) the directory of the link: a documented
divergence (Pkg and Tar do not form such paths).
"""
function normalize(path::String)
    p = String(path)
    startswith(p, '/') || (p = string(cwd(), "/", p))
    parts = String[]
    for c in eachsplit(p, '/')
        if isempty(c) || c == "."
            continue
        elseif c == ".."
            isempty(parts) || pop!(parts)
        else
            push!(parts, String(c))
        end
    end
    return "/" * join(parts, "/")
end

"""
    resolve(path) -> (fd, relative path), or (-1, "") outside every preopen

The preopened directory `path` is in (the longest prefix, on component boundaries) and the
path relative to it (`.` for the directory itself).
"""
function resolve(path::String)
    p = normalize(path)
    best, rel, len = Int32(-1), "", -1
    for (fd, dir) in preopens()
        n = ncodeunits(dir)
        inside = dir == "/" ? true :
                 p == dir || (startswith(p, dir) && codeunit(p, n + 1) == UInt8('/'))
        if inside && n > len
            r = dir == "/" ? String(SubString(p, 2)) : p == dir ? "" : String(SubString(p, n + 2))
            best, rel, len = fd, isempty(r) ? "." : r, n
        end
    end
    return (best, trailing_sep(path) ? rel * "/" : rel)
end

const UV_ENOENT = Int32(Base.UV_ENOENT)
const UV_ENOTDIR = Int32(Base.UV_ENOTDIR)

"""
    check_path(path) -> 0, or a libuv error code

What `normalize` loses of a path: an empty path does not exist (ENOENT); one ending with a
separator must be a directory, if it exists (ENOTDIR). And a path outside every preopen does
not exist (ENOENT).
"""
function check_path(path::String)
    isempty(path) && return UV_ENOENT
    fd, rel = resolve(path)
    fd < 0 && return UV_ENOENT
    # (`.` and `..` need what precedes them to be a directory, as a lookup of each component
    # checks natively: `file/.` is ENOTDIR, `missing/../file` ENOENT)
    if occursin("/.", path) || startswith(path, '.')
        c = check_dot_components(path)
        c == 0 || return c
    end
    if ncodeunits(path) > 1 && codeunit(path, ncodeunits(path)) == UInt8('/')
        r = Staging.with_scope() do
            off, len = Staging.raw_path(rel)
            path_filestat_get(fd, SYMLINK_FOLLOW, off, len, Staging.SCRATCH_OUT)
        end
        r == 0 && Staging.load8(Staging.SCRATCH_OUT + UInt32(16)) != FT_DIR && return UV_ENOTDIR
    end
    return Int32(0)
end

# the first prefix of `path` before a `.` or `..` component that is not a directory: its
# error (ENOENT, ENOTDIR, ...), or 0
function check_dot_components(path::String)
    p = startswith(path, '/') ? path : string(cwd(), '/', path)
    prefix = ""
    for c in eachsplit(p, '/'; keepempty=false)
        if (c == "." || c == "..") && !isempty(prefix)
            ft = filetype(prefix, true)
            ft isa Int32 && return ft
            ft == FT_DIR || return UV_ENOTDIR
        end
        prefix = string(prefix, '/', c)
    end
    return Int32(0)
end

"Whether `path` ends with a separator (and is not `/`): it names a directory, followed."
trailing_sep(path::String) = ncodeunits(path) > 1 && codeunit(path, ncodeunits(path)) == UInt8('/')

# the WASI filetype of `path` (resolved, followed or not), or the libuv error of its lookup
# (`UV_ENOENT`: it does not exist; ELOOP, ENOTDIR, ...)
function filetype(path::String, follow::Bool)
    fd, rel = resolve(path)
    fd < 0 && return UV_ENOENT
    r = Staging.with_scope() do
        off, len = Staging.raw_path(rel)
        path_filestat_get(fd, follow ? SYMLINK_FOLLOW : UInt32(0), off, len, Staging.SCRATCH_OUT)
    end
    return r == 0 ? Staging.load8(Staging.SCRATCH_OUT + UInt32(16)) : uv(r)
end

"""
    open_check(path, create, write) -> 0, or a libuv error code

What open(2) says of a path ending with a separator (a directory): absent, ENOENT, or EISDIR
when it would be created (a file cannot be); a directory opened for writing or with O_CREAT,
EISDIR; another failure of the lookup (ELOOP, ENOTDIR of a prefix), that failure.
"""
function open_check(path::String, create::Bool, write::Bool)
    trailing_sep(path) || return Int32(0)
    if create
        # (as Linux: with O_CREAT, a trailing separator is EISDIR once the parent is found)
        parent = dirname(rstrip(path, '/'))
        pft = filetype(isempty(parent) ? "." : parent, true)
        pft isa Int32 && return pft
        pft == FT_DIR || return UV_ENOTDIR
        return Int32(Base.UV_EISDIR)
    end
    ft = filetype(path, true)
    ft == UV_ENOENT && return create ? Int32(Base.UV_EISDIR) : UV_ENOENT
    ft isa Int32 && return ft
    ft == FT_DIR || return UV_ENOTDIR
    return write || create ? Int32(Base.UV_EISDIR) : Int32(0)
end

"""
    with_path(f, path) -> f(fd, off, len), or a libuv error code (`check_path`)

`f` of the preopen of `path` and its relative path in the record arena.
"""
function with_path(f::F, path::String) where {F}
    c = check_path(path)
    c == 0 || return c
    fd, rel = resolve(path)
    return Staging.with_scope() do
        off, len = Staging.raw_path(rel)
        f(fd, off, len)
    end
end

"""
    with_abspath(f, path) -> f(off, len), or nothing (`check_path` failed, with code `c`)

`f` of the absolute, normalized `path` in the record arena (the seams' paths), if the
path passes `check_path` (the host would refuse a path outside the preopens as not
permitted, where the program must see that it does not exist).
"""
function with_abspath(f::F, path::String) where {F}
    check_path(path) == 0 || return nothing
    return Staging.with_scope() do
        off, len = Staging.raw_path(normalize(path))
        f(off, len)
    end
end

## stat: a buffer of `SIZEOF_STAT` bytes, of this layout (little-endian)

# 0 dev u64 | 8 ino u64 | 16 mode u32 | 20 nlink u32 | 24 uid u32 | 28 gid u32 | 32 rdev u32
# 40 size u64 | 48 blksize u64 | 56 blocks u64 | 64 mtime f64 | 72 ctime f64
const SIZEOF_STAT = Int32(80)

# what WASI's filestat (64 bytes: dev, ino, filetype u8, nlink, size, atim, mtim, ctim) has
# not: synthesized. uid, gid: 0; rdev: 0; blksize: 4096; blocks: the size in 512-byte blocks
# (rounded up). mode: from `path_mode` for paths (see the seams); for an fd (`jl_fstat`), the type
# from WASI and permissions 0o644 (files) or 0o755 (directories), never those of a path.
const SYNTH_BLKSIZE = UInt64(4096)

"The permissions of a file of the WASI type `ft` on a host without modes."
default_perms(ft::UInt8) = ft == FT_DIR ? UInt32(0o755) : ft == FT_LINK ? UInt32(0o777) : UInt32(0o644)

function type_bits(ft::UInt8)
    ft == FT_DIR && return UInt32(0o040000)
    ft == FT_FILE && return UInt32(0o100000)
    ft == FT_LINK && return UInt32(0o120000)
    ft == FT_CHAR && return UInt32(0o020000)
    ft == FT_BLOCK && return UInt32(0o060000)
    ft == FT_STREAM && return UInt32(0o140000)   # socket
    return UInt32(0)
end

store_le!(p::Ptr{UInt8}, off::Int, v::UInt64, n::Int) =
    for k in 0:n-1
        unsafe_store!(p, (v >> (8k)) % UInt8, off + k + 1)
    end
load_le(p::Ptr{UInt8}, off::Int, n::Int) =
    foldl((acc, k) -> acc | UInt64(unsafe_load(p, off + k + 1)) << (8k), 0:n-1; init=UInt64(0))

# fill `buf` from the filestat at `fs` (in the linear memory) and the mode `mode`
function fill_stat!(buf::Ptr{UInt8}, fs::UInt32, mode::UInt32)
    L = Staging.load64
    size = L(fs + UInt32(32))
    store_le!(buf, 0, L(fs), 8)
    store_le!(buf, 8, L(fs + UInt32(8)), 8)
    store_le!(buf, 16, UInt64(mode), 4)
    store_le!(buf, 20, L(fs + UInt32(24)), 4)
    store_le!(buf, 24, UInt64(0), 4)
    store_le!(buf, 28, UInt64(0), 4)
    store_le!(buf, 32, UInt64(0), 4)
    store_le!(buf, 40, size, 8)
    store_le!(buf, 48, SYNTH_BLKSIZE, 8)
    store_le!(buf, 56, cld(size, UInt64(512)), 8)
    store_le!(buf, 64, reinterpret(UInt64, L(fs + UInt32(48)) / 1e9), 8)
    store_le!(buf, 72, reinterpret(UInt64, L(fs + UInt32(56)) / 1e9), 8)
    return nothing
end

function stat_path(path::String, buf::Ptr{UInt8}, follow::Bool)
    # (a trailing separator follows the last component, as stat(2) of `link/`)
    follow |= trailing_sep(path)
    # the mode first: `with_abspath` checks the path, which uses the scratch the filestat is in
    m = something(with_abspath((off, len) -> path_mode(off, len, Int32(follow)), path), -Int32(44))
    fs = Staging.SCRATCH_OUT
    r = with_path(path) do fd, off, len
        path_filestat_get(fd, follow ? SYMLINK_FOLLOW : UInt32(0), off, len, fs)
    end
    r == 0 || return r < 0 ? r : uv(r)
    # (the mode of the host; without modes, the type of WASI with default permissions; else
    # the type with no permission)
    ft = Staging.load8(fs + UInt32(16))
    mode = m >= 0 ? UInt32(m) : m == -NO_MODES ? type_bits(ft) | default_perms(ft) : type_bits(ft)
    m < 0 && m != -Int32(44) && m != -NO_MODES && return uv(-m)
    fill_stat!(buf, fs, mode)
    return Int32(0)
end

"`jl_stat(path, buf)`."
jl_stat(path::Cstring, buf::Ptr{UInt8}) = stat_path(unsafe_string(path), buf, true)
"`jl_lstat(path, buf)`."
jl_lstat(path::Cstring, buf::Ptr{UInt8}) = stat_path(unsafe_string(path), buf, false)
"`jl_fstat(fd, buf)`: the type from WASI, synthesized permissions (see above)."
function jl_fstat(fd::RawFD, buf::Ptr{UInt8})
    fs = Staging.SCRATCH_OUT
    r = fd_filestat_get(reinterpret(Int32, fd), fs)
    r == 0 || return uv(r)
    ft = Staging.load8(fs + UInt32(16))
    fill_stat!(buf, fs, type_bits(ft) | (ft == FT_DIR ? UInt32(0o755) : UInt32(0o644)))
    return Int32(0)
end
jl_sizeof_stat() = SIZEOF_STAT
stat_dev(b::Ptr{UInt8}) = load_le(b, 0, 8) % UInt32
stat_ino(b::Ptr{UInt8}) = load_le(b, 8, 8) % UInt32
stat_mode(b::Ptr{UInt8}) = load_le(b, 16, 4) % UInt32
stat_nlink(b::Ptr{UInt8}) = load_le(b, 20, 4) % UInt32
stat_uid(b::Ptr{UInt8}) = load_le(b, 24, 4) % UInt32
stat_gid(b::Ptr{UInt8}) = load_le(b, 28, 4) % UInt32
stat_rdev(b::Ptr{UInt8}) = load_le(b, 32, 4) % UInt32
stat_size(b::Ptr{UInt8}) = load_le(b, 40, 8)
stat_blksize(b::Ptr{UInt8}) = load_le(b, 48, 8)
stat_blocks(b::Ptr{UInt8}) = load_le(b, 56, 8)
stat_mtime(b::Ptr{UInt8}) = reinterpret(Float64, load_le(b, 64, 8))
stat_ctime(b::Ptr{UInt8}) = reinterpret(Float64, load_le(b, 72, 8))

## simple operations (libuv's synchronous requests: `loop` and `req` are not used)

"`malloc(n)`: `n` bytes of a new object (a pointer with an owner); `free` does nothing."
malloc(n::UInt) = Ptr{Cvoid}(pointer(Memory{UInt8}(undef, max(Int(n), 1))))
free(p::Ptr{Cvoid}) = nothing
req_cleanup(req::Ptr{Cvoid}) = nothing

# the permission bits (and setuid/setgid/sticky) of the absolute path `path` (that exists,
# followed), nothing without mode support, or a negative libuv error
function perm_bits(path::String)
    c = check_path(path)
    c == 0 || return c
    m = Staging.with_scope() do
        off, len = Staging.raw_path(normalize(path))
        path_mode(off, len, Int32(1))
    end
    m == -NO_MODES && return nothing
    m < 0 && return uv(-m)
    return UInt32(m) & UInt32(0o7777)
end

"""
    apply_mode!(path, mode, now; dir)

Give a file or directory the host just created (with the host's default `now`: 0o777, or
0o666 for a file, less what its umask or the parent's ACL removes) the mode `mode` as
mkdir(2) and open(2) would (`mode & ~umask`): the requested permission bits the host allows,
never more, and the requested setuid/setgid/sticky bits (which no umask removes); bits the
host set beyond the permissions (setgid inherited from the parent) are kept. A directory's
default tells all the permission bits allowed; a file's tells nothing of the execute bits:
for a file asking for some, what the host allows there is learnt from a directory created
(and removed) beside it (`host_allowed`), and without that no execute bit is added.
"""
function apply_mode!(path::String, mode::Integer, now::UInt32; dir::Bool)
    m = UInt32(mode)
    allowed = now & UInt32(0o777)
    if !dir && m & UInt32(0o111) != 0
        # (the read and write bits the host gave the file stand; the execute bits, those it
        # allows in the directory the file is in: the target's, through a link)
        real = Runtime.BaseFS.realpath_wasm_or_nothing(path)
        a = real === nothing ? nothing : host_allowed(dirname(real))
        a isa Int32 && return a
        allowed = (now & UInt32(0o666)) | (a === nothing ? UInt32(0) : a & UInt32(0o111))
    end
    want = (now & UInt32(0o7000)) | (m & UInt32(0o7000)) | (m & allowed)
    want == now && return Int32(0)
    r = with_abspath((off, len) -> path_chmod(off, len, Int32(want)), path)
    # (a host without modes: the host's)
    return r === nothing ? UV_ENOENT : r == 0 || r == NO_MODES ? Int32(0) : uv(r)
end

"""
The permission bits the host allows in the directory `dir` (0o777 less its umask, or as an
ACL of `dir` decides): of a directory created in it (with a new random name, retried on a
collision) and removed; `nothing` if that fails.
"""
function host_allowed(dir::String)
    for _ in 1:10
        probe = string(dir, "/.jl_mode_probe_", string(Runtime.entropy() % 1_000_000_000))
        r = with_path((fd, off, len) -> path_create_directory(fd, off, len), probe)
        r == 20 && continue          # (EEXIST: another name)
        r == 0 || return nothing
        m = perm_bits(probe)
        with_path((fd, off, len) -> path_remove_directory(fd, off, len), probe)
        return m
    end
    return nothing
end

uv_fs_mkdir(loop::Ptr{Cvoid}, req::Ptr{Cvoid}, path::Cstring, mode::Cint, cb::Ptr{Cvoid}) =
    mkdir_path(unsafe_string(path), mode)
function mkdir_path(path::String, mode::Integer)
    r = with_path(path) do fd, off, len
        path_create_directory(fd, off, len)
    end
    r == 0 || return r < 0 ? r : uv(r)
    # A mode failure leaves the created directory at its host mode.
    now = perm_bits(path)
    now === nothing && return Int32(0)
    now isa Int32 && return now
    return apply_mode!(path, mode, now; dir=true)
end
uv_fs_rmdir(loop::Ptr{Cvoid}, req::Ptr{Cvoid}, path::Cstring, cb::Ptr{Cvoid}) =
    simple(path_remove_directory, unsafe_string(path))
jl_fs_unlink(path::Cstring) = simple(path_unlink_file, unsafe_string(path))

# A final dot is meaningful to destructive operations, even though lookup normalizes it.
terminal_dot(path::String) = (c = basename(rstrip(path, '/')); c == "." || c == "..")

function simple(f::F, path::String) where {F}
    c = check_path(path)
    c == 0 || return c
    if terminal_dot(path)
        return f === path_remove_directory ? (basename(rstrip(path, '/')) == "." ? Int32(Base.UV_EINVAL) : Int32(Base.UV_ENOTEMPTY)) : Int32(Base.UV_EISDIR)
    end
    r = with_path((fd, off, len) -> f(fd, off, len), path)
    return r <= 0 ? r : uv(r)
end

function jl_fs_rename(old::Cstring, new::Cstring)
    o, n = unsafe_string(old), unsafe_string(new)
    c = check_path(o)
    c == 0 || return c
    c = check_path(n)
    c == 0 || return c
    (terminal_dot(o) || terminal_dot(n)) && return Int32(Base.UV_EBUSY) # EBUSY
    # A slash-terminated destination can name a new directory, but never a file.
    if trailing_sep(n)
        ft = filetype(o, false)
        ft isa Int32 && return ft
        ft == FT_DIR || return UV_ENOTDIR
        ft = filetype(String(rstrip(n, '/')), false)
        if ft isa Int32
            ft == UV_ENOENT || return ft
        else
            ft == FT_LINK && return UV_ENOTDIR
        end
    end
    ofd, orel = resolve(o)
    nfd, nrel = resolve(n)
    r = Staging.with_scope() do
        oldoff, ol = Staging.raw_path(orel)
        newoff, nl = Staging.raw_path(nrel)
        path_rename(ofd, oldoff, ol, nfd, newoff, nl)
    end
    return r == 0 ? Int32(0) : uv(r)
end

"""
`jl_fs_symlink(target, link, flags)`: by the host's `path_symlink_io` (a target is natively
any string, not resolved: WASI's `path_symlink` refuses targets that are absolute or leave
the preopen), else WASI's.
"""
function jl_fs_symlink(target::Cstring, link::Cstring, flags::Cint)
    t = unsafe_string(target)
    l = unsafe_string(link)
    if trailing_sep(l)
        ft = filetype(String(rstrip(l, '/')), false)
        return ft isa Int32 ? ft : Int32(Base.UV_EEXIST)
    end
    c = check_path(l)
    c == 0 || return c
    r = Staging.with_scope() do
        o, ol = Staging.raw_path(t)
        n, nl = Staging.raw_path(normalize(l))
        path_symlink_io(o, ol, n, nl)
    end
    if r == NO_MODES
        fd, rel = resolve(l)
        fd < 0 && return UV_ENOENT
        r = Staging.with_scope() do
            o, ol = Staging.raw_path(t)
            n, nl = Staging.raw_path(rel)
            path_symlink(o, ol, fd, n, nl)
        end
    end
    return r == 0 ? Int32(0) : uv(r)
end

function jl_fs_hardlink(src::Cstring, dst::Cstring)
    o, n = unsafe_string(src), unsafe_string(dst)
    c = check_path(o)
    c == 0 || return c
    if trailing_sep(n)
        ft = filetype(o, false)
        ft isa Int32 && return ft
        ft = filetype(String(rstrip(n, '/')), false)
        return ft isa Int32 ? ft : Int32(Base.UV_EEXIST)
    end
    c = check_path(n)
    c == 0 || return c
    ofd, orel = resolve(o)
    nfd, nrel = resolve(n)
    r = Staging.with_scope() do
        oldoff, ol = Staging.raw_path(orel)
        newoff, nl = Staging.raw_path(nrel)
        path_link(ofd, UInt32(0), oldoff, ol, nfd, newoff, nl)
    end
    return r == 0 ? Int32(0) : uv(r)
end

function jl_fs_chmod(path::Cstring, mode::Cint)
    p = unsafe_string(path)
    r = with_abspath((off, len) -> path_chmod(off, len, Int32(mode)), p)
    r === nothing && return check_path(p)
    # (a host without modes: ENOTSUP)
    r == NO_MODES && return uv(Int32(58))
    return r == 0 ? Int32(0) : uv(r)
end

"`jl_fs_access(path, mode)`: existence (F_OK), else the permission bits of the owner."
function jl_fs_access(path::Cstring, mode::Cint)
    p = unsafe_string(path)
    m = with_abspath((off, len) -> path_mode(off, len, Int32(1)), p)
    m === nothing && return check_path(p)
    if m == -NO_MODES
        # (a host without modes: the default permissions of the file's type)
        ft = filetype(p, true)
        ft isa Int32 && return ft
        m = Int32(default_perms(ft))
    end
    m < 0 && return uv(-m)
    # (R_OK 4, W_OK 2, X_OK 1: the owner's bits, as for the process's own files)
    want = UInt32(mode) & 0x7
    return (UInt32(m) >> 6) & want == want ? Int32(0) : Int32(Base.UV_EACCES)
end

"The target of the symbolic link `path`, or an error code (a negative `Int32`)."
function readlink_path(path::String)
    c = check_path(path)
    c == 0 || return c
    # (`link/` is what the link names, if it is a directory: not a link)
    if trailing_sep(path)
        ft = filetype(path, true)
        return ft isa Int32 ? ft : Int32(Base.UV_EINVAL)
    end
    fd, rel = resolve(path)
    cap = UInt32(4096)
    while true
        result = readlink_result(fd, rel, cap)
        result === nothing || return result
        # A full buffer is ambiguous even for an exactly-capacity target.
        cap == Staging.CHUNK && return uv(Int32(37)) # ENAMETOOLONG
        cap *= UInt32(2)
    end
end

# A separate call keeps each attempt's capacity concrete while the caller grows it.
readlink_result(fd::Int32, rel::String, cap::UInt32) = Staging.with_scope() do
    o, ol = Staging.raw_path(rel)
    buf = Staging.alloc_data(cap; align=1)
    r = path_readlink(fd, o, ol, buf, cap, Staging.SCRATCH_OUT)
    r == 0 || return uv(r)
    n = Staging.load32(Staging.SCRATCH_OUT)
    n < cap ? get_raw(buf, n) : nothing
end

"""
    readdir_entries(dir) -> Vector{Tuple{String,UInt8}}, or an error code

The entries of the directory `dir` (but `.` and `..`), with their WASI filetypes, in the
order of the host.
"""
function readdir_entries(dir::String)
    c = check_path(dir)
    c == 0 || return c
    fd, rel = resolve(dir)
    entries = Tuple{String,UInt8}[]
    r = read_dir!(entries, fd, rel)
    return r == 0 ? entries : uv(r)
end

read_dir!(entries::Vector{Tuple{String,UInt8}}, fd::Int32, rel::String) = Staging.with_scope() do
    o, ol = Staging.raw_path(rel)
    e = path_open(fd, SYMLINK_FOLLOW, o, ol, O_DIRECTORY, open_rights(fd, true, false), inheriting_rights(fd), UInt32(0), Staging.SCRATCH_OUT)
    e == 0 || return e
    dfd = reinterpret(Int32, Staging.load32(Staging.SCRATCH_OUT))
    try
        return read_dirents!(entries, dfd)
    finally
        fd_close(dfd)
    end
end

# the dirents of `dfd`: (d_next u64, d_ino u64, d_namlen u32, d_type u8) and the name
function read_dirents!(entries::Vector{Tuple{String,UInt8}}, dfd::Int32)
    cap = UInt32(64 * 1024)
    buf = Staging.alloc_data(cap)
    cookie = UInt64(0)
    while true
        r = fd_readdir(dfd, buf, cap, cookie, Staging.SCRATCH_OUT)
        r == 0 || return Int32(r)
        used = Staging.load32(Staging.SCRATCH_OUT)
        p = buf
        previous = cookie
        while p + UInt32(24) <= buf + used
            next = Staging.load64(p)
            n = Staging.load32(p + UInt32(16))
            typ = Staging.load8(p + UInt32(20))
            p + UInt32(24) + n > buf + used && break   # truncated: read again from `cookie`
            name = get_raw(p + UInt32(24), n)
            name == "." || name == ".." || push!(entries, (name, typ))
            cookie = next
            p += UInt32(24) + n
        end
        used < cap && return Int32(0)
        if cookie == previous
            # No complete entry fit. Grow up to the staging chunk limit, then fail.
            cap == Staging.CHUNK && return Int32(37) # ENAMETOOLONG
            cap *= UInt32(2)
            buf = Staging.alloc_data(cap)
        end
    end
end

## files by descriptor (`Base.Filesystem.File`: `cp`, `touch`, `mv` across devices)

# the open flags (Base's `JL_O_*`, the platform's values)
const JL_O_WRONLY = Base.Filesystem.JL_O_WRONLY
const JL_O_RDWR = Base.Filesystem.JL_O_RDWR
const JL_O_CREAT = Base.Filesystem.JL_O_CREAT
const JL_O_EXCL = Base.Filesystem.JL_O_EXCL
const JL_O_TRUNC = Base.Filesystem.JL_O_TRUNC
const JL_O_APPEND = Base.Filesystem.JL_O_APPEND
const JL_O_DIRECTORY = Base.Filesystem.JL_O_DIRECTORY
const JL_O_NOFOLLOW = Base.Filesystem.JL_O_NOFOLLOW
const JL_O_SYNC = Base.Filesystem.JL_O_SYNC
const JL_O_DSYNC = Base.Filesystem.JL_O_DSYNC
# flags that change nothing here (no other process, no terminal)
const JL_O_IGNORED = Base.Filesystem.JL_O_CLOEXEC | Base.Filesystem.JL_O_NOCTTY | Base.Filesystem.JL_O_NONBLOCK
const JL_O_KNOWN = JL_O_WRONLY | JL_O_RDWR | JL_O_CREAT | JL_O_EXCL | JL_O_TRUNC | JL_O_APPEND |
                   JL_O_DIRECTORY | JL_O_NOFOLLOW | JL_O_SYNC | JL_O_DSYNC | JL_O_IGNORED

"""
`uv_fs_open(loop, req, path, flags, mode, cb)`: the fd (or an error code) is the result of
`req` (its first 8 bytes, which `uv_fs_get_result` reads). A file it creates gets `mode`
(less the default umask, 0o022), as `open(2)` does.
"""
function uv_fs_open(loop::Ptr{Cvoid}, req::Ptr{Cvoid}, path::Cstring, flags::Int32, mode::Int32, cb::Ptr{Cvoid})
    r = open_path(unsafe_string(path), flags, mode)
    store_le!(Ptr{UInt8}(req), 0, reinterpret(UInt64, Int64(r)), 8)
    return r < 0 ? r : Int32(0)
end
uv_fs_get_result(req::Ptr{Cvoid}) = reinterpret(Int64, load_le(Ptr{UInt8}(req), 0, 8))

function open_path(path::String, flags::Int32, mode::Int32)
    c = check_path(path)
    c == 0 || return c
    # (flags the host cannot honor: an error, not ignored)
    flags & ~JL_O_KNOWN == 0 || return Int32(Base.UV_EINVAL)
    acc = flags & 0x3
    c = open_check(path, flags & JL_O_CREAT != 0, acc != 0)
    c == 0 || return c
    fd, rel = resolve(path)
    trailing = trailing_sep(path)
    # (created: absent, followed, as the host creates the target of a dangling link)
    creating = flags & JL_O_CREAT != 0 && filetype(path, true) == UV_ENOENT
    oflags = (flags & JL_O_CREAT != 0 ? O_CREAT : UInt32(0)) | (flags & JL_O_EXCL != 0 ? O_EXCL : UInt32(0)) |
             (flags & JL_O_TRUNC != 0 ? O_TRUNC : UInt32(0)) |
             (flags & JL_O_DIRECTORY != 0 || trailing ? O_DIRECTORY : UInt32(0))
    fdflags = (flags & JL_O_APPEND != 0 ? FDFLAGS_APPEND : UInt32(0)) |
              (flags & JL_O_SYNC == JL_O_SYNC ? FDFLAGS_SYNC : flags & JL_O_DSYNC != 0 ? FDFLAGS_DSYNC : UInt32(0))
    # (a trailing separator follows the last component, whatever O_NOFOLLOW says)
    nofollow = flags & JL_O_NOFOLLOW != 0 && !trailing
    if nofollow
        # (hosts may follow the last component anyway: as open(2), an existing name is
        # EEXIST for O_CREAT|O_EXCL, else a link is ELOOP)
        ft = filetype(path, false)
        if !(ft isa Int32)
            flags & (JL_O_CREAT | JL_O_EXCL) == JL_O_CREAT | JL_O_EXCL && return Int32(Base.UV_EEXIST)
            ft == FT_LINK && return Int32(Base.UV_ELOOP)
        end
    end
    r = open_at(fd, rel, oflags, fdflags, open_rights(fd, acc != JL_O_WRONLY, acc != 0),
                nofollow ? UInt32(0) : SYMLINK_FOLLOW)
    r < 0 && return r
    if creating
        now = perm_bits(path)
        e = now === nothing ? Int32(0) : now isa Int32 ? now : apply_mode!(path, mode, now; dir=false)
        # Creation and mode adjustment are not atomic. On failure the created file
        # remains at its host mode, but the new descriptor is closed. A path-based
        # provider must handle replacement races; atomic create-with-mode needs a
        # stronger host interface.
        e == 0 || (fd_close(r); return e)
    end
    return r
end
open_at(fd::Int32, rel::String, oflags::UInt32, fdflags::UInt32, rights::UInt64, lookup::UInt32) = Staging.with_scope() do
    o, ol = Staging.raw_path(rel)
    e = path_open(fd, lookup, o, ol, oflags, rights, inheriting_rights(fd), fdflags, Staging.SCRATCH_OUT)
    e == 0 ? reinterpret(Int32, Staging.load32(Staging.SCRATCH_OUT)) : uv(e)
end

jl_fs_close(fd::RawFD) = (r = fd_close(reinterpret(Int32, fd)); r == 0 ? Int32(0) : uv(r))

# Raw descriptor calls return a count or a negative libuv error, and allow short IO.
# Bound each request to one staging chunk (also safely representable by Int32).
# A negative offset selects sequential writes, as in libuv.
function jl_fs_write(fd::RawFD, buf::Ptr{UInt8}, n::Csize_t, offset::Int64)
    k = Int(min(n, Csize_t(Staging.CHUNK)))
    return Staging.with_scope() do
        off = Staging.alloc_data(k)
        Staging.copy_ptr_to_linear!(off, buf, k)
        write_once(reinterpret(Int32, fd), off, UInt32(k), offset)
    end
end

function jl_fs_read(fd::RawFD, buf::Ptr{Cvoid}, n::Csize_t)
    k = Int(min(n, Csize_t(Staging.CHUNK)))
    return Staging.with_scope() do
        off = Staging.alloc_data(k)
        got = read_once(reinterpret(Int32, fd), off, UInt32(k))
        got < 0 && return got
        for j in 1:Int(got)
            unsafe_store!(Ptr{UInt8}(buf), Staging.load8(off + UInt32(j - 1)), j)
        end
        got
    end
end

# The source position is never changed, including on short writes and errors. Reusing the
# linear chunk avoids a linear-to-GC-to-linear round trip for each copy operation.
function jl_fs_sendfile(src::RawFD, dst::RawFD, offset::Int64, n::Csize_t)
    offset < 0 && return Int32(Base.UV_EINVAL)
    k = UInt32(min(n, Csize_t(Staging.CHUNK)))
    return Staging.with_scope() do
        off = Staging.alloc_data(k)
        got = read_once(reinterpret(Int32, src), off, k, offset)
        got <= 0 && return got
        write_once(reinterpret(Int32, dst), off, UInt32(got))
    end
end

"`jl_lseek(fd, offset, whence)`: the new offset, or -1 (errno set)."
function jl_lseek(fd::RawFD, offset::Int64, whence::Cint)
    r = fd_seek(reinterpret(Int32, fd), offset, UInt32(whence), Staging.SCRATCH_OUT)
    r == 0 || (set_errno(libc_errno(r)); return Int64(-1))
    return reinterpret(Int64, Staging.load64(Staging.SCRATCH_OUT))
end

"`uv_fs_ftruncate(loop, req, fd, n, cb)`."
function uv_fs_ftruncate(loop::Ptr{Cvoid}, req::Ptr{Cvoid}, fd::RawFD, n::Int64, cb::Ptr{Cvoid})
    n < 0 && return Int32(Base.UV_EINVAL)
    r = fd_filestat_set_size(reinterpret(Int32, fd), UInt64(n))
    return r == 0 ? Int32(0) : uv(r)
end
"`uv_fs_futime(loop, req, fd, atime, mtime, cb)`: times in seconds."
function uv_fs_futime(loop::Ptr{Cvoid}, req::Ptr{Cvoid}, fd::RawFD, atime::Float64, mtime::Float64, cb::Ptr{Cvoid})
    ns(t) = round(UInt64, max(t, 0.0) * 1e9)
    r = fd_filestat_set_times(reinterpret(Int32, fd), ns(atime), ns(mtime), UInt32(1 | 4))
    return r == 0 ? Int32(0) : uv(r)
end
"`futimes(fd, NULL)` (libc, `touch`): both times now; times given (not NULL) are not supported."
function futimes(fd::Cint, tv::Ptr{Cvoid})
    tv == C_NULL || (ccall(:jl_set_errno, Cvoid, (Cint,), Cint(22)); return Cint(-1))
    r = fd_filestat_set_times(Int32(fd), UInt64(0), UInt64(0), UInt32(2 | 8))
    r == 0 && return Cint(0)
    ccall(:jl_set_errno, Cvoid, (Cint,), Cint(libc_errno(r)))
    return Cint(-1)
end

"`getpid()`: the process of the host is not the program's: 1."
getpid() = Int32(1)

## reads and writes of a file descriptor, a staging chunk at a time

# copy `n` bytes of the linear memory at `off` to `dst` (a `Vector{UInt8}` or a pointer)
# from `i` (0-based), and of `src` from `i` to the linear memory at `off`
copy_out!(dst::Vector{UInt8}, i::Int, off::UInt32, n::Int) =
    Staging.copy_from_linear!(dst, i + 1, off, n)
function copy_out!(dst::Ptr{UInt8}, i::Int, off::UInt32, n::Int)
    for k in 1:n
        unsafe_store!(dst, Staging.load8(off + UInt32(k - 1)), i + k)
    end
end
copy_in!(off::UInt32, src::Vector{UInt8}, i::Int, n::Int) =
    Staging.copy_to_linear!(off, src, i + 1, n)
copy_in!(off::UInt32, src::Ptr{UInt8}, i::Int, n::Int) =
    Staging.copy_ptr_to_linear!(off, src + i, n)

# `_enonfatal`: WASI's EINTR or EAGAIN, after which a read or a write is tried again (as by
# ios.c; a host interrupting it endlessly is an error, never the end of the input)
enonfatal(r::Int32) = r == Int32(27) || r == Int32(6)
const MAX_TRIES = 1_000_000

# read up to `k` bytes (at most a chunk) of `fd` into `dst` from `i` (0-based), again while
# interrupted or not ready: the bytes read (0 at EOF), or a libuv code
function read_chunk(fd::Int32, dst, i::Int, k::Int)
    return Staging.with_scope() do
        off = Staging.alloc_data(k)
        Staging.store32(Staging.SCRATCH_IOVEC, off)
        Staging.store32(Staging.SCRATCH_IOVEC + UInt32(4), UInt32(k))
        r = fd_read(fd, Staging.SCRATCH_IOVEC, UInt32(1), Staging.SCRATCH_OUT)
        tries = 0
        while enonfatal(r)
            tries += 1
            tries > MAX_TRIES && throw(Base.IOError("read: " * Errno.uv_message(uv(r)), uv(r)))
            r = fd_read(fd, Staging.SCRATCH_IOVEC, UInt32(1), Staging.SCRATCH_OUT)
        end
        r == 0 || return Int(uv(r))
        got = Int(Staging.load32(Staging.SCRATCH_OUT))
        copy_out!(dst, i, off, got)
        got
    end
end

# write the `k` bytes (at most a chunk) of `src` (a `Vector{UInt8}` or a pointer) from `i`
# (0-based) to `fd`, each write again while interrupted or not ready: (the guest's errno or
# 0, the bytes written)
write_chunk(fd::Int32, src, i::Int, k::Int) = Staging.with_scope() do
    off = Staging.alloc_data(k)
    copy_in!(off, src, i, k)
    w = 0
    tries = 0
    while w < k
        Staging.store32(Staging.SCRATCH_IOVEC, off + UInt32(w))
        Staging.store32(Staging.SCRATCH_IOVEC + UInt32(4), UInt32(k - w))
        r = WASI.fd_write(fd, Staging.SCRATCH_IOVEC, UInt32(1), Staging.SCRATCH_OUT)
        if enonfatal(r)
            tries += 1
            tries > MAX_TRIES && throw(Base.IOError("write: " * Errno.uv_message(uv(r)), uv(r)))
            continue
        end
        r == 0 || return (libc_errno(r), w)
        n = Int(Staging.load32(Staging.SCRATCH_OUT))
        if n == 0
            # (no progress: again, as ios.c's `_os_write_all` loops)
            tries += 1
            tries > MAX_TRIES && throw(Base.IOError("write: no progress", Int32(Base.UV_EIO)))
            continue
        end
        w += n
    end
    return (Int32(0), w)
end

# Synchronous hosts can retry EINTR, but cannot wait for readiness on EAGAIN.
# Report EAGAIN promptly; callers must not retry an entire partially completed write.
function write_once(fd::Int32, off::UInt32, n::UInt32, offset::Int64=Int64(-1))
    Staging.store32(Staging.SCRATCH_IOVEC, off)
    Staging.store32(Staging.SCRATCH_IOVEC + UInt32(4), n)
    while true
        r = offset < 0 ? fd_write(fd, Staging.SCRATCH_IOVEC, UInt32(1), Staging.SCRATCH_OUT) :
            fd_pwrite(fd, Staging.SCRATCH_IOVEC, UInt32(1), UInt64(offset), Staging.SCRATCH_OUT)
        r == 27 && continue # EINTR, at the same remaining offset
        r == 0 || return uv(r)
        return reinterpret(Int32, Staging.load32(Staging.SCRATCH_OUT))
    end
end

function read_once(fd::Int32, off::UInt32, n::UInt32, offset::Int64=Int64(-1))
    Staging.store32(Staging.SCRATCH_IOVEC, off)
    Staging.store32(Staging.SCRATCH_IOVEC + UInt32(4), n)
    while true
        r = offset == -1 ? fd_read(fd, Staging.SCRATCH_IOVEC, UInt32(1), Staging.SCRATCH_OUT) :
            fd_pread(fd, Staging.SCRATCH_IOVEC, UInt32(1), UInt64(offset), Staging.SCRATCH_OUT)
        r == 27 && continue
        r == 0 || return uv(r)
        return reinterpret(Int32, Staging.load32(Staging.SCRATCH_OUT))
    end
end

## the IO streams of files (`IOStream`): `ios_*`, ported from src/support/ios.c
#
# An `IOStream`'s `ios` buffer (`sizeof_ios_t` bytes, the native size) holds: at 0, a magic
# u32 (`IOS_MAGIC` while open, `IOS_CLOSED` once closed, for good); at 4, the index (u32,
# 1-based) of its state (an `IOS`, ios.c's `ios_t`) in `IOS_TABLE`. Closing a stream gives
# its slot up for later streams and keeps in the bytes what a closed `ios_t` still holds
# (`ios_close`). The functions are ios.c's, and sys.c's that read an `ios_t`, for a stream of
# a file descriptor: an IOStream is never a memory stream (`bm_mem`, its branches and
# `_write_grow` are left out), and never has the inline buffer (`local`) or one it does not
# own. Its system calls are over WASI (`_os_read`, `_os_write_all`, `lseek`, `ftruncate`,
# below). As natively, a read error is the end of the input, a write error a short count
# (and errno), and a closed stream one whose fd is -1.

const IOS_MAGIC = 0x5753_4f49   # "IOSW"
const IOS_CLOSED = 0x4453_4f49  # "IOSD"

const IOS_BUFSIZE = 32768
const IOS_EOF = Cint(-1)
const LINE_CHUNK_SIZE = 160
# `bufmode_t`: when written data moves out to the fd
const BM_NONE = Int32(1000)
const BM_LINE = Int32(1001)
const BM_BLOCK = Int32(1002)
# `bufstate_t`: where the fd's position is relative to the buffer: reading, at its end;
# writing, at its start
const BST_NONE = Int32(0)
const BST_RD = Int32(1)
const BST_WR = Int32(2)

"`MOST_OF(x)`: what fits comfortably in a buffer of `x` bytes."
most_of(x::Int) = x - (x >> 4)

"""
The state of a stream, ios.c's `ios_t`: `buf` holds `size` bytes of the file, of which the
first `ndirty` are to be written out; `bpos` is the position in it (0-based, offsets as in
C); `fpos` caches the fd's position (-1: unknown). Of `ios_t`'s other fields: `rereadable`,
`lineno` and `u_colno` are not read by any function here, `growable` and `ownbuf` are always
set.
"""
mutable struct IOS
    buf::Vector{UInt8}   # (of `maxsize` bytes; empty once closed, `NULL`)
    bm::Int32
    state::Int32
    maxsize::Int
    size::Int
    bpos::Int
    ndirty::Int
    fpos::Int64
    fd::Int
    readable::Bool
    writable::Bool
    ownfd::Bool
    _eof::Bool
end

const IOS_TABLE = Union{Nothing,IOS}[]

set_errno(e::Integer) = ccall(:jl_set_errno, Cvoid, (Cint,), Cint(e))

# a closed stream's bytes: what `ios_close` leaves of its `ios_t` but its fd (-1) and its
# buffer (none): at 8, its state, `_eof`, `readable` and `writable`, a byte each; at 12, its
# buffer mode (u32); at 16, its cached position (i64)
closed_ios(p::Ptr{UInt8}) =
    IOS(UInt8[], load_le(p, 12, 4) % Int32, load_le(p, 8, 1) % Int32, 0, 0, 0, 0,
        reinterpret(Int64, load_le(p, 16, 8)), -1, load_le(p, 10, 1) != 0, load_le(p, 11, 1) != 0,
        false, load_le(p, 9, 1) != 0)
function save_closed!(p::Ptr{UInt8}, s::IOS)
    store_le!(p, 8, UInt64(s.state), 1)
    store_le!(p, 9, UInt64(s._eof), 1)
    store_le!(p, 10, UInt64(s.readable), 1)
    store_le!(p, 11, UInt64(s.writable), 1)
    store_le!(p, 12, UInt64(s.bm), 4)
    store_le!(p, 16, reinterpret(UInt64, s.fpos), 8)
end

"""
    with_ios(f, s)

`f(st)`, of the state `st` of the stream whose `ios_t` is at `s`: an open stream's, in
`IOS_TABLE`; a closed one's, made from its bytes and written back to them.
"""
function with_ios(f::F, s::Ptr{Cvoid}) where {F}
    p = Ptr{UInt8}(s)
    magic = load_le(p, 0, 4) % UInt32
    magic == IOS_MAGIC && return f(IOS_TABLE[Int(load_le(p, 4, 4))]::IOS)
    magic == IOS_CLOSED || throw(ArgumentError("not an IOStream of the runtime"))
    st = closed_ios(p)
    r = f(st)
    save_closed!(p, st)
    return r
end

function new_ios!(s::Ptr{Cvoid}, st::IOS)
    i = findfirst(isnothing, IOS_TABLE)
    if i === nothing
        push!(IOS_TABLE, st)
        i = length(IOS_TABLE)
    else
        IOS_TABLE[i] = st
    end
    p = Ptr{UInt8}(s)
    store_le!(p, 0, UInt64(IOS_MAGIC), 4)
    store_le!(p, 4, UInt64(i), 4)
    return s
end

## ios.c's system calls, over WASI: they set errno on failure, as the C library does; a
## negative fd (a closed stream's) is EBADF

const EBADF = Int32(9)
const SEEK_SET = UInt32(0)
const SEEK_CUR = UInt32(1)
const SEEK_END = UInt32(2)

# the WASI fd of `fd`: -1 for one out of WASI's range (EBADF)
wasi_fd(fd::Int) = 0 <= fd <= typemax(Int32) ? Int32(fd) : Int32(-1)

"""
`_os_read(fd, buf, n, &nread)`: one read of up to `n` bytes of `fd` into `dst` (a
`Vector{UInt8}` or a pointer) from `i` (0-based): (errno or 0, the bytes read). A staging
chunk is read at a time, and the next while they come back full: one `read(2)` of a file
reads all it can.
"""
function _os_read(fd::Int, dst, i::Int, n::Int)
    wfd = wasi_fd(fd)
    wfd < 0 && (set_errno(EBADF); return (EBADF, 0))
    got = 0
    while got < n
        k = min(n - got, Int(Staging.CHUNK))
        r = read_chunk(wfd, dst, i + got, k)
        if r < 0
            # (after some bytes, those: the error comes with the next read)
            got > 0 && break
            e = libc_from_uv(r)
            set_errno(e)
            return (e, 0)
        end
        got += r
        r < k && break
    end
    return (Int32(0), got)
end

# `_os_read_all`: reads until `n` bytes, the end of the input or an error
function _os_read_all(fd::Int, dst, i::Int, n::Int)
    nread = 0
    while n > 0
        err, got = _os_read(fd, dst, i + nread, n)
        n -= got
        nread += got
        (err != 0 || got == 0) && return (err, nread)
    end
    return (Int32(0), nread)
end

"""
`_os_write_all(fd, buf, n, &nwritten)`: the `n` bytes of `src` (a `Vector{UInt8}` or a
pointer) from `i` (0-based) to `fd`: (errno or 0, the bytes written).
"""
function _os_write_all(fd::Int, src, i::Int, n::Int)
    wfd = wasi_fd(fd)
    wfd < 0 && (set_errno(EBADF); return (EBADF, 0))
    nwritten = 0
    while nwritten < n
        err, wrote = write_chunk(wfd, src, i + nwritten, min(n - nwritten, Int(Staging.CHUNK)))
        nwritten += wrote
        err == 0 || (set_errno(err); return (err, nwritten))
    end
    return (Int32(0), nwritten)
end

"`lseek(fd, offset, whence)`: the new position, or -1 (errno set)."
function lseek(fd::Int, offset::Int64, whence::UInt32)
    wfd = wasi_fd(fd)
    wfd < 0 && (set_errno(EBADF); return Int64(-1))
    return jl_lseek(RawFD(wfd), offset, Cint(whence))
end

"`ftruncate(fd, length)`: 0, or -1 (errno set)."
function ftruncate(fd::Int, length::Int64)
    wfd = wasi_fd(fd)
    wfd < 0 && (set_errno(EBADF); return Cint(-1))
    length < 0 && (set_errno(22); return Cint(-1))
    r = fd_filestat_set_size(wfd, UInt64(length))
    r == 0 || (set_errno(libc_errno(r)); return Cint(-1))
    return Cint(0)
end

# `memcpy` between the buffer and a caller's bytes (a `Vector{UInt8}` or a pointer), and
# `memmove` within the buffer: `n` bytes, offsets 0-based
memcpy!(dst::Vector{UInt8}, di::Int, src::Vector{UInt8}, si::Int, n::Int) =
    (copyto!(dst, di + 1, src, si + 1, n); nothing)
function memcpy!(dst::Ptr{UInt8}, di::Int, src::Vector{UInt8}, si::Int, n::Int)
    for k in 1:n
        unsafe_store!(dst, src[si+k], di + k)
    end
end
function memcpy!(dst::Vector{UInt8}, di::Int, src::Ptr{UInt8}, si::Int, n::Int)
    for k in 1:n
        dst[di+k] = unsafe_load(src, si + k)
    end
end
memmove!(buf::Vector{UInt8}, di::Int, si::Int, n::Int) =
    (copyto!(buf, di + 1, buf, si + 1, n); nothing)

# `memchr`: the offset of the first `c` of the `n` bytes of `buf` from `i`, or -1 (the
# search stops at the end of the buffer, past which C would read)
function memchr(buf::Vector{UInt8}, i::Int, c::UInt8, n::UInt)
    stop = i + Int(min(n, UInt(max(length(buf) - i, 0))))
    for k in i:stop-1
        buf[k+1] == c && return k
    end
    return -1
end
# `memrchr`: the offset (from `i`) of the last `c` of the `n` bytes of `data` (a
# `Vector{UInt8}` or a pointer) from `i`, or -1
function memrchr(data, i::Int, c::UInt8, n::Int)
    for k in n-1:-1:0
        byte_at(data, i + k) == c && return k
    end
    return -1
end
byte_at(data::Vector{UInt8}, i::Int) = data[i+1]
byte_at(data::Ptr{UInt8}, i::Int) = unsafe_load(data, i + 1)

## ios.c's internals

# `_buf_realloc`: room for `sz` bytes in the buffer, its data kept (an IOStream's buffer is
# its own and growable: this does not fail)
function _buf_realloc(s::IOS, sz::Int)
    if sz > s.maxsize
        resize!(s.buf, sz)
        s.maxsize = sz
    end
    return nothing
end

function _write_update_pos(s::IOS)
    s.bpos > s.ndirty && (s.ndirty = s.bpos)
    s.bpos > s.size && (s.size = s.bpos)
    return nothing
end

# `_ios_read`: up to `n` bytes into `dest` (a pointer or a `Vector{UInt8}`); with `all`, until
# `n` or the end of the input. What does not fit comfortably in the buffer is read directly,
# leaving it empty.
function _ios_read(s::IOS, dest, n::Int, all::Bool)
    tot = 0
    didread = false
    s.state == BST_WR && ios_seek(s, ios_pos(s))
    s.state = BST_RD
    while n > 0
        # (`size_t`: a buffer truncated below the position has "all" of it, as in C)
        avail = (s.size - s.bpos) % UInt
        if avail > 0
            ncopy = avail >= n ? n : Int(avail)
            memcpy!(dest, tot, s.buf, s.bpos, ncopy)
            s.bpos += ncopy
            ncopy >= n && return tot + ncopy
        end
        if s.fd == -1
            # (no more data)
            avail == 0 && (s._eof = true)
            return Int(avail)
        end
        n -= Int(avail)
        tot += Int(avail)
        didread && !all && return tot
        ios_flush(s)
        s.bpos = s.size = 0
        s.fpos = -1
        if n > most_of(s.maxsize)
            # (it doesn't fit comfortably in the buffer: directly)
            _, got = all ? _os_read_all(s.fd, dest, tot, n) : _os_read(s.fd, dest, tot, n)
            tot += got
            got == 0 && (s._eof = true)
            return tot
        else
            # (refill the buffer)
            err, got = _os_read(s.fd, s.buf, 0, s.maxsize)
            if err != 0 || got == 0
                s._eof = true
                return tot
            end
            s.size = got
        end
        didread = true
    end
    return tot
end

"""
`ios_readprep(s, n)`: `n` bytes buffered if possible (the data moved back, or the buffer
grown, to fit them): the bytes available.
"""
function ios_readprep(s::IOS, n::UInt)
    if s.state == BST_WR
        ios_flush(s)
        s.bpos = s.size = 0
    end
    space = (s.size - s.bpos) % UInt
    s.state = BST_RD
    (space >= n || s.fd == -1) && return space
    if s.maxsize < s.bpos + n
        # (it won't fit: grow the buffer or move the data back)
        if n <= s.maxsize && space <= s.maxsize >> 2
            space != 0 && memmove!(s.buf, 0, s.bpos, Int(space))
            s.size -= s.bpos
            s.bpos = 0
        else
            _buf_realloc(s, s.bpos + Int(n))
        end
    end
    s.fpos = -1
    err, got = _os_read(s.fd, s.buf, s.size, s.maxsize - s.size)
    err != 0 && return space
    s.size += got
    return (s.size - s.bpos) % UInt
end

"""
`ios_fillbuf(s)`: the buffer filled: the bytes available if that is the whole rest of the
file, else -1.
"""
function ios_fillbuf(s::IOS)
    nb = (s.maxsize - s.bpos) % UInt
    got = ios_readprep(s, nb)
    got < nb && return got % Cssize_t
    return Cssize_t(-1)
end

"""
`ios_write(s, data, n)`: `n` bytes of `data` (a pointer or a `Vector{UInt8}`) from `i`,
held in the buffer as its mode says: the bytes written.
"""
function ios_write(s::IOS, data, i::Int, n::Int)
    s.writable || return 0
    n == 0 && return 0
    wrote = 0
    s.state == BST_RD && ios_seek(s, ios_pos(s))
    s.state = BST_WR
    space = (s.maxsize - s.bpos) % UInt
    if s.bm == BM_NONE
        s.fpos = -1
        _, wrote = _os_write_all(s.fd, data, i, n)
        return wrote
    elseif n <= space
        if s.bm == BM_LINE
            nl = memrchr(data, i, UInt8('\n'), n)
            if nl >= 0
                linesz = nl + 1
                s.bm = BM_BLOCK
                wrote += ios_write(s, data, i, linesz)
                ios_flush(s)
                s.bm = BM_LINE
                n -= linesz
                i += linesz
            end
        end
        memcpy!(s.buf, s.bpos, data, i, n)
        s.bpos += n
        wrote += n
    else
        ios_flush(s)
        if n > most_of(s.maxsize)
            s.fpos = -1
            _, wrote = _os_write_all(s.fd, data, i, n)
            return wrote
        end
        return ios_write(s, data, i, n)
    end
    _write_update_pos(s)
    return wrote
end

"`ios_seek(s, pos)`: 0, or -1 (errno set)."
function ios_seek(s::IOS, pos::Int64)
    s._eof = false
    ios_flush(s)
    fdpos = lseek(s.fd, pos, SEEK_SET)
    fdpos == -1 && return fdpos
    s.fpos = fdpos
    s.bpos = s.size = 0
    return Int64(0)
end

"`ios_seek_end(s)`: 0, or -1 (errno set); the input has ended."
function ios_seek_end(s::IOS)
    s._eof = true
    ios_flush(s)
    fdpos = lseek(s.fd, Int64(0), SEEK_END)
    fdpos == -1 && return fdpos
    s.fpos = fdpos
    s.bpos = s.size = 0
    return Int64(0)
end

"`ios_skip(s, offs)`: a relative seek, within the buffer if it can: 0, or -1 (errno set)."
function ios_skip(s::IOS, offs::Int64)
    if offs != 0
        if offs > 0
            if offs <= s.size - s.bpos
                s.bpos += offs
                return Int64(0)
            end
        elseif -offs <= s.bpos
            s.bpos += offs
            s._eof = false
            return Int64(0)
        end
        ios_flush(s)
        if s.state == BST_WR
            offs += s.bpos
        elseif s.state == BST_RD
            offs -= s.size - s.bpos
        end
        fdpos = lseek(s.fd, offs, SEEK_CUR)
        fdpos == -1 && return fdpos
        s.fpos = fdpos
        s.bpos = s.size = 0
        s._eof = false
    end
    return Int64(0)
end

"`ios_pos(s)`: the position, from the fd's (cached), or -1 (errno set)."
function ios_pos(s::IOS)
    fdpos = s.fpos
    if fdpos == -1
        fdpos = lseek(s.fd, Int64(0), SEEK_CUR)
        fdpos == -1 && return fdpos
        s.fpos = fdpos
    end
    if s.state == BST_WR
        fdpos += s.bpos
    elseif s.state == BST_RD
        fdpos -= s.size - s.bpos
    end
    return fdpos
end

"`ios_filesize(s)`: the size of the file (what is written out), or -1 (errno set)."
function ios_filesize(s::IOS)
    fdpos = s.fpos
    if fdpos == -1
        fdpos = lseek(s.fd, Int64(0), SEEK_CUR)
        fdpos == -1 && return fdpos
        s.fpos = fdpos
    end
    sz = lseek(s.fd, Int64(0), SEEK_END)
    lseek(s.fd, fdpos, SEEK_SET)
    return sz
end

"`ios_trunc(s, size)`: 0, or 1 (errno set)."
function ios_trunc(s::IOS, size::UInt)
    ios_flush(s)
    if s.state == BST_RD
        p = ios_pos(s)
        # (compared unsigned, as in C)
        if size < (p + (s.size - s.bpos)) % UInt
            s.size -= p + (s.size - s.bpos) - size % Int
        end
    end
    return ftruncate(s.fd, size % Int64) == 0 ? Cint(0) : Cint(1)
end

# `ios_eof`: whether the input has ended, without reading
function ios_eof(s::IOS)
    s.state == BST_RD && s.bpos < s.size && return false
    s._eof && return true
    return s.fd == -1
end

"`ios_eof_blocking(s)`: whether the input has ended, reading to know."
function ios_eof_blocking(s::IOS)
    s.state == BST_RD && s.bpos < s.size && return Cint(0)
    s.fd == -1 && return Cint(1)
    return ios_readprep(s, UInt(1)) < 1 ? Cint(1) : Cint(0)
end

"`ios_flush(s)`: the dirty bytes written out: 0, an errno, or -1 (a short write)."
function ios_flush(s::IOS)
    (s.ndirty == 0 || isempty(s.buf)) && return Cint(0)
    s.fd == -1 && return Cint(-1)
    s.state == BST_RD && lseek(s.fd, -Int64(s.size), SEEK_CUR)
    ntowrite = s.ndirty
    s.fpos = -1
    err, nw = _os_write_all(s.fd, s.buf, 0, ntowrite)
    if s.state == BST_RD
        lseek(s.fd, Int64(s.size - nw), SEEK_CUR)
    elseif s.state == BST_WR
        s.bpos != nw && lseek(s.fd, Int64(s.bpos - nw), SEEK_CUR)
        # (the data to write begins at the start of the buffer again, and `size` counts the
        # file's data it holds)
        s.size > s.ndirty && memmove!(s.buf, 0, s.ndirty, s.size - s.ndirty)
        s.size -= s.ndirty
        s.bpos = 0
    end
    s.ndirty = 0
    err != 0 && return err
    nw < ntowrite && return Cint(-1)
    return Cint(0)
end

"`ios_putc(c, s)`: the byte `c` written: 1, or 0."
function ios_putc(c::Cint, s::IOS)
    ch = c % UInt8
    if s.state == BST_WR && s.bpos < s.maxsize && s.bm != BM_NONE
        s.buf[s.bpos+1] = ch
        s.bpos += 1
        _write_update_pos(s)
        s.bm == BM_LINE && ch == UInt8('\n') && ios_flush(s)
        return Cint(1)
    end
    return Cint(ios_write(s, UInt8[ch], 0, 1))
end

"`ios_getc(s)`: the next byte, or `IOS_EOF`."
function ios_getc(s::IOS)
    if s.state == BST_RD && s.bpos < s.size
        ch = s.buf[s.bpos+1]
        s.bpos += 1
    else
        s._eof && return IOS_EOF
        b = UInt8[0x00]
        _ios_read(s, b, 1, false) < 1 && return IOS_EOF
        ch = b[1]
    end
    return Cint(ch)
end

"`ios_peekc(s)`: the next byte, left to read, or `IOS_EOF`."
function ios_peekc(s::IOS)
    s.bpos < s.size && return Cint(s.buf[s.bpos+1])
    s._eof && return IOS_EOF
    ios_readprep(s, UInt(1)) == 0 && return IOS_EOF
    return Cint(s.buf[s.bpos+1])
end

# `ios_copyuntil(to, from, delim, keep)`: the bytes of `from` up to `delim` (it too, with
# `keep`) appended to `to` (natively a memory stream): their number
function ios_copyuntil(to::Vector{UInt8}, from::IOS, delim::UInt8, keep::Bool)
    total = 0
    avail = (from.size - from.bpos) % UInt
    while !ios_eof(from)
        if avail == 0
            avail = ios_readprep(from, UInt(LINE_CHUNK_SIZE))
            avail == 0 && break
        end
        pd = memchr(from.buf, from.bpos, delim, avail)
        if pd == -1
            total += append_bytes!(to, from.buf, from.bpos, Int(avail))
            from.bpos += Int(avail)
            avail = UInt(0)
        else
            ntowrite = pd - from.bpos + keep
            total += append_bytes!(to, from.buf, from.bpos, ntowrite)
            from.bpos += ntowrite + !keep
            return total
        end
    end
    from._eof = true
    return total
end

# (`ios_write` to a memory stream: the `n` bytes of `buf` from `i` appended to `to`)
function append_bytes!(to::Vector{UInt8}, buf::Vector{UInt8}, i::Int, n::Int)
    m = length(to)
    resize!(to, m + n)
    copyto!(to, m + 1, buf, i + 1, n)
    return n
end

# `ios_nchomp(from, n)`: the bytes to drop from the `n` up to a line's end: 2 for "\r\n"
ios_nchomp(from::IOS, n::Int) = n > 1 && from.buf[from.bpos+n-1] == UInt8('\r') ? 2 : 1

## the functions of the C runtime (`RUNTIME_CCALLS`), of the stream whose `ios_t` is at `s`

"""
`ios_fd(s, fd, isfile, own)`: a stream of the open fd `fd` (`fdio`), buffered by block
(stderr unbuffered, stdout by line); closing it closes the fd if it owns it.
"""
function ios_fd(s::Ptr{Cvoid}, fd::Int, isfile::Cint, own::Cint)
    # (`_ios_init`, then `_buf_init(s, bm_block)`)
    st = IOS(Vector{UInt8}(undef, IOS_BUFSIZE), BM_BLOCK, BST_NONE, IOS_BUFSIZE, 0, 0, 0,
             Int64(-1), fd, true, true, own != 0, false)
    fd == 2 && (st.bm = BM_NONE)
    fd == 1 && (st.bm = BM_LINE)
    return new_ios!(s, st)
end

"`ios_file(s, fname, rd, wr, create, trunc)`: `s`, or C_NULL (and errno set)."
function ios_file(s::Ptr{UInt8}, fname::Cstring, rd::Cint, wr::Cint, create::Cint, trunc::Cint)
    fail(e) = (set_errno(e); Ptr{Cvoid}(C_NULL))
    (rd != 0 || wr != 0) || return fail(22)
    name = unsafe_string(fname)
    c = check_path(name)
    c == 0 || return fail(libc_from_uv(c))
    c = open_check(name, create != 0, wr != 0)
    c == 0 || return fail(libc_from_uv(c))
    fd, rel = resolve(name)
    oflags = (create != 0 ? O_CREAT : UInt32(0)) | (trunc != 0 ? O_TRUNC : UInt32(0))
    r = Staging.with_scope() do
        o, ol = Staging.raw_path(rel)
        path_open(fd, SYMLINK_FOLLOW, o, ol, oflags, open_rights(fd, rd != 0, wr != 0), inheriting_rights(fd), UInt32(0), Staging.SCRATCH_OUT)
    end
    r == 0 || return fail(libc_errno(r))
    nfd = reinterpret(Int32, Staging.load32(Staging.SCRATCH_OUT))
    p = ios_fd(Ptr{Cvoid}(s), Int(nfd), Cint(1), Cint(1))
    with_ios(p) do st
        st.fpos = 0
        rd == 0 && (st.readable = false)
        wr == 0 && (st.writable = false)
    end
    return p
end

ios_read(s::Ptr{Cvoid}, dest::Ptr{Cvoid}, n::Csize_t) =
    with_ios(st -> Csize_t(_ios_read(st, Ptr{UInt8}(dest), Int(n), false)), s)
ios_readall(s::Ptr{Cvoid}, dest::Ptr{Cvoid}, n::Csize_t) =
    with_ios(st -> Csize_t(_ios_read(st, Ptr{UInt8}(dest), Int(n), true)), s)
ios_fillbuf(s::Ptr{Cvoid}) = with_ios(ios_fillbuf, s)
ios_write(s::Ptr{Cvoid}, p::Ptr{Cvoid}, n::Csize_t) =
    with_ios(st -> Csize_t(ios_write(st, Ptr{UInt8}(p), 0, Int(n))), s)
ios_putc(c::Cint, s::Ptr{Cvoid}) = with_ios(st -> ios_putc(c, st), s)
ios_flush(s::Ptr{Cvoid}) = with_ios(ios_flush, s)
ios_getc(s::Ptr{Cvoid}) = with_ios(ios_getc, s)
ios_peekc(s::Ptr{Cvoid}) = with_ios(ios_peekc, s)
ios_eof_blocking(s::Ptr{Cvoid}) = with_ios(ios_eof_blocking, s)
ios_seek(s::Ptr{Cvoid}, pos::Int64) = with_ios(st -> ios_seek(st, pos), s)
ios_seek_end(s::Ptr{Cvoid}) = with_ios(ios_seek_end, s)
ios_skip(s::Ptr{Cvoid}, offs::Int64) = with_ios(st -> ios_skip(st, offs), s)
ios_pos(s::Ptr{Cvoid}) = with_ios(ios_pos, s)
ios_filesize(s::Ptr{Cvoid}) = with_ios(ios_filesize, s)
ios_trunc(s::Ptr{Cvoid}, size::Csize_t) = with_ios(st -> ios_trunc(st, UInt(size)), s)
ios_isopen(s::Ptr{Cvoid}) = with_ios(st -> Cint(st.fd != -1), s)
ios_get_readable(s::Ptr{Cvoid}) = with_ios(st -> Cint(st.readable), s)
ios_get_writable(s::Ptr{Cvoid}) = with_ios(st -> Cint(st.writable), s)

"""
`ios_close(s)`: the dirty bytes written out and the fd closed (if owned): 0, or an error
(errno set).
"""
function ios_close(s::Ptr{Cvoid})
    p = Ptr{UInt8}(s)
    # (closed already: nothing to write out and no fd, as natively; or never opened)
    load_le(p, 0, 4) % UInt32 == IOS_MAGIC || return Cint(0)
    i = Int(load_le(p, 4, 4))
    st = IOS_TABLE[i]::IOS
    err = ios_flush(st)
    if st.fd != -1 && st.ownfd
        r = fd_close(wasi_fd(st.fd))
        r == 0 || (set_errno(libc_errno(r)); err = Cint(-1))
    end
    st.fd = -1
    st.buf = UInt8[]
    st.size = st.maxsize = st.bpos = 0
    store_le!(p, 0, UInt64(IOS_CLOSED), 4)
    save_closed!(p, st)
    IOS_TABLE[i] = nothing
    return err
end

## sys.c's functions of an `ios_t`

jl_ios_fd(s::Ptr{Cvoid}) = with_ios(st -> st.fd, s)
jl_nb_available(s::Ptr{Cvoid}) = with_ios(st -> (st.size - st.bpos) % Int32, s)

"`jl_ios_buffer_n(s, n)`: 0 once `n` bytes are buffered, 1 if they cannot be."
function jl_ios_buffer_n(s::IOS, n::UInt)
    while true
        space = (s.size - s.bpos) % UInt
        ret = ios_readprep(s, n)
        space == ret && ret < n && return Cint(1)
        ret < n || return Cint(0)
    end
end
jl_ios_buffer_n(s::Ptr{Cvoid}, n::Csize_t) = with_ios(st -> jl_ios_buffer_n(st, UInt(n)), s)

"`jl_ios_get_nbyte_int(s, n)`: the `n`-byte little-endian integer at the position (buffered)."
function jl_ios_get_nbyte_int(s::IOS, n::Int)
    x = UInt64(0)
    for i in 0:n-1
        x |= UInt64(s.buf[s.bpos+i+1]) << (8i)
    end
    s.bpos += n
    return x
end
jl_ios_get_nbyte_int(s::Ptr{Cvoid}, n::Csize_t) =
    with_ios(st -> jl_ios_get_nbyte_int(st, Int(n)), s)

"""
`jl_readuntil(s, delim, str, chomp)`: the bytes up to `delim` (a `String` if `str`, else a
`Vector{UInt8}`): with it (`chomp` 0), without it (1), or without it and a `\\r` before it (2).
"""
function jl_readuntil(s::IOS, delim::UInt8, str::UInt8, chomp::UInt8)
    # (the common case: `delim` in the buffer)
    pd = memchr(s.buf, s.bpos, delim, (s.size - s.bpos) % UInt)
    if pd != -1
        n = pd - s.bpos + 1
        nchomp = chomp == 0 ? 0 : chomp == 2 ? ios_nchomp(s, n) : 1
        a = s.buf[s.bpos+1:s.bpos+n-nchomp]
        s.bpos += n
    else
        a = UInt8[]
        n = ios_copyuntil(a, s, delim, true)
        if chomp != 0 && n > 0 && a[n] == delim
            n -= 1
            chomp == 2 && n > 0 && a[n] == UInt8('\r') && (n -= 1)
            resize!(a, n)
        end
    end
    return str != 0 ? String(a) : a
end
jl_readuntil(s::Ptr{Cvoid}, delim::UInt8, str::UInt8, chomp::UInt8) =
    with_ios(st -> jl_readuntil(st, delim, str, chomp), s)

end # FS

## functions of Base patched for Wasm (`trim/wasm-fs.jl`) call these: natively, Base's own
## (the method before the patches, in the world before them); in the module, methods of
## `WASM_METHODS` on the above (see `methods.jl`)

module BaseFS

using ..Runtime: @wasm_method, original, Errno, entropy
import ..FS

const UV_DIRENT = (0x00 => Cint(0), FS.FT_FILE => Cint(1), FS.FT_DIR => Cint(2), FS.FT_LINK => Cint(3),
                   FS.FT_STREAM => Cint(5), FS.FT_DGRAM => Cint(5), FS.FT_CHAR => Cint(6),
                   FS.FT_BLOCK => Cint(7))
function uv_dirent(ft::UInt8)
    for (w, u) in UV_DIRENT
        w == ft && return u
    end
    return Cint(0)
end

# Keep the build process's libc formatter native; only the guest uses the fixed ABI.
@noinline libc_strerror(e::Int32) = original(Base.Libc.strerror, e)::String
@wasm_method libc_strerror(e::Int32) = Errno.strerror(e)

throw_uv(prefix::String, code::Integer) = throw(Base.IOError(string(prefix, ": ", Errno.uv_message(code), " (",
                                                                    Errno.uv_name(code), ")"), Int32(code)))

"The entries of `dir`: (name, libuv's dirent type), unsorted."
@noinline function dir_entries(dir::String)
    es = original(Base.Filesystem._readdirx, dir; sort=false)::Vector{Base.Filesystem.DirEntry}
    return Tuple{String,Cint}[(e.name, e.rawtype) for e in es]
end
function dir_entries_wasm(dir::String)
    r = FS.readdir_entries(dir)
    r isa Int32 && throw_uv(string("readdir(", repr(dir), ")"), r)
    entries = r::Vector{Tuple{String,UInt8}}
    return Tuple{String,Cint}[(name, uv_dirent(ft)) for (name, ft) in entries]
end

@noinline readlink(path::String) = original(Base.Filesystem.readlink, path)::String
function readlink_wasm(path::String)
    r = FS.readlink_path(path)
    r isa Int32 && throw_uv(string("readlink(", repr(path), ")"), r)
    return r::String
end

@noinline realpath(path::String) = original(Base.Filesystem.realpath, path)::String
"""
`realpath`: the path with its symbolic links resolved, one component at a time, below the
preopened directory it is in (whose own path is taken as it is: its ancestors may be out of
reach).
"""
function realpath_wasm(path::String)
    err(code) = throw_uv(string("realpath(", repr(path), ")"), code)
    c = FS.check_path(path)
    c == 0 || err(c)
    p = FS.normalize(path)
    hops = 0
    while true
        fd, rel = FS.resolve(p)
        fd < 0 && err(Int32(Base.UV_ENOENT))
        root = "/"
        for (f, dir) in FS.preopens()
            f == fd && (root = dir)
        end
        parts = rel == "." ? String[] : String[String(x) for x in split(rel, '/'; keepempty=false)]
        done = root
        changed = false
        for (k, c) in enumerate(parts)
            q = done == "/" ? "/" * c : done * "/" * c
            t = FS.readlink_path(q)
            if t isa String
                hops += 1
                hops > 40 && err(Int32(Base.UV_ELOOP))
                rest = join(parts[k+1:end], "/")
                base = startswith(t, '/') ? t : (done == "/" ? "/" * t : done * "/" * t)
                p = FS.normalize(isempty(rest) ? base : base * "/" * rest)
                changed = true
                break
            elseif t != Int32(Base.UV_EINVAL)   # EINVAL: not a link
                err(t)
            end
            done = q
        end
        changed && continue
        # (it must exist)
        r = FS.with_path((fd, off, len) -> FS.path_filestat_get(fd, FS.SYMLINK_FOLLOW, off, len, FS.Staging.SCRATCH_OUT), p)
        r == 0 || err(r < 0 ? r : FS.uv(r))
        return p
    end
end

"`realpath_wasm(path)`, or nothing if it fails."
function realpath_wasm_or_nothing(path::String)
    try
        return realpath_wasm(path)
    catch
        return nothing
    end
end

@noinline pwd() = original(Base.Filesystem.pwd)::String
pwd_wasm() = FS.cwd()

@noinline cd(dir::String) = (original(Base.Filesystem.cd, dir); nothing)
function cd_wasm(dir::String)
    c = FS.check_path(dir)
    c == 0 || throw_uv(string("cd(", repr(dir), ")"), c)
    p = FS.normalize(dir)
    r = FS.with_path((fd, off, len) -> FS.path_filestat_get(fd, FS.SYMLINK_FOLLOW, off, len, FS.Staging.SCRATCH_OUT), p)
    r == 0 || throw_uv(string("cd(", repr(dir), ")"), r < 0 ? r : FS.uv(r))
    FS.Staging.load8(FS.Staging.SCRATCH_OUT + UInt32(16)) == FS.FT_DIR ||
        throw_uv(string("cd(", repr(dir), ")"), Int32(Base.UV_ENOTDIR))
    # (the physical directory, as chdir(2): its symbolic links resolved)
    FS.CWD[] = realpath_wasm(p)
    return nothing
end

"""
The working directory to return to after `cd(f, dir)`: natively an fd of it (Base's way:
`open(".")`, then `fchdir`), in Wasm its path (there is no fd of it).
"""
struct SavedCwd
    fd::Int32
    path::String
end
@noinline function cwd_save()
    fd = ccall(:open, Int32, (Cstring, Int32, UInt32...), :., 0)
    systemerror(:open, fd == -1)
    return SavedCwd(fd, "")
end
cwd_save_wasm() = SavedCwd(Int32(-1), FS.cwd())
@noinline function cwd_restore(h::SavedCwd)
    try
        systemerror(:fchdir, ccall(:fchdir, Int32, (Int32,), h.fd) != 0)
    finally
        systemerror(:close, ccall(:close, Int32, (Int32,), h.fd) != 0)
    end
    return nothing
end
cwd_restore_wasm(h::SavedCwd) = cd_wasm(h.path)

@noinline tempdir() = original(Base.Filesystem.tempdir)::String
"`tempdir()`: `TMPDIR`, `TMP`, `TEMP`, `TEMPDIR` of the environment, else `/tmp`, as libuv's."
function tempdir_wasm()
    for name in ("TMPDIR", "TMP", "TEMP", "TEMPDIR")
        v = FS.host_env(name)
        if v !== nothing && !isempty(v)
            return length(v) > 1 && endswith(v, '/') ? String(chop(v)) : v
        end
    end
    return "/tmp"
end

@noinline homedir() = original(Base.Filesystem.homedir)::String
"`homedir()`: `HOME` of the environment as it is, even empty (there is no user database:
without it, an error)."
function homedir_wasm()
    v = FS.host_env("HOME")
    v === nothing && throw_uv("homedir()", Int32(Base.UV_ENOENT))
    return v
end

const NAME_CHARS = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
"A random name of `n` characters (of the host's entropy)."
rand_name(n::Int) = String(UInt8[NAME_CHARS[entropy() % length(NAME_CHARS) + 1] for _ in 1:n])

@noinline rand_filename(len::Int) = original(Base.Filesystem._rand_filename, len)::String
rand_filename_wasm(len::Int) = rand_name(len)

"`mkdtemp(template)`: the directory made of `template` with its trailing `XXXXXX` random."
@noinline mkdtemp(parent::String, prefix::String) =
    original(Base.Filesystem.mktempdir, parent; prefix=prefix, cleanup=false)::String
function mkdtemp_wasm(parent::String, prefix::String)
    tpath = isempty(parent) || endswith(parent, '/') ? string(parent, prefix) : string(parent, "/", prefix)
    for _ in 1:100
        p = tpath * rand_name(6)
        r = FS.mkdir_path(p, 0o700)
        r == 0 && return p
        r == Int32(Base.UV_EEXIST) || throw_uv(string("mktempdir(", repr(parent), ")"), r)
    end
    throw_uv(string("mktempdir(", repr(parent), ")"), Int32(Base.UV_EEXIST))
end

"`mkstemp`: a new file `parent/jl_XXXXXX` (random), open for reading and writing."
@noinline mkstemp(parent::String) = original(Base.Filesystem.mktemp, parent; cleanup=false)::Tuple{String,IOStream}
function mkstemp_wasm(parent::String)
    for _ in 1:100
        p = joinpath(parent, Base.Filesystem.temp_prefix * rand_name(6))
        # (created exclusively, readable and writable by the owner only, as mkstemp does)
        fd = FS.open_path(p, Int32(FS.JL_O_RDWR | FS.JL_O_CREAT | FS.JL_O_EXCL | FS.JL_O_NOFOLLOW), Int32(0o600))
        fd == Int32(Base.UV_EEXIST) && continue
        fd < 0 && throw(SystemError("mktemp", Int(FS.libc_from_uv(fd))))
        return (p, Base.fdio(Int(fd), true))
    end
    throw(SystemError("mktemp", 17))
end

@wasm_method dir_entries(dir::String) = dir_entries_wasm(dir)
@wasm_method readlink(path::String) = readlink_wasm(path)
@wasm_method realpath(path::String) = realpath_wasm(path)
@wasm_method pwd() = pwd_wasm()
@wasm_method cd(dir::String) = cd_wasm(dir)
@wasm_method cwd_save() = cwd_save_wasm()
@wasm_method cwd_restore(h::SavedCwd) = cwd_restore_wasm(h)
@wasm_method tempdir() = tempdir_wasm()
@wasm_method homedir() = homedir_wasm()
@wasm_method rand_filename(len::Int) = rand_filename_wasm(len)
@wasm_method mkdtemp(parent::String, prefix::String) = mkdtemp_wasm(parent, prefix)
@wasm_method mkstemp(parent::String) = mkstemp_wasm(parent)

end # BaseFS

"""
    Walkdir(root, topdown, follow_symlinks, onerror)

`walkdir` without a task (Base's runs a task putting the values in a channel): a stateful
iterator doing, when the next value is taken, what the task did between two values, so the
order of the values, of the directories read and of the calls of `onerror` is the same,
and a consumer changing `dirs` (or the files) before taking the next value acts as before.
An error `onerror` throws ends the iteration with it, after the values before it, as
closing the channel with it did.
"""
mutable struct WalkFrame
    path::String
    dirs::Vector{String}
    files::Vector{String}
    next::Int
end

mutable struct Walkdir{F}
    root::String
    topdown::Bool
    follow_symlinks::Bool
    onerror::F
    stack::Vector{WalkFrame}
    started::Bool
    done::Bool
    failed::Any     # the error `onerror` threw, or nothing
end
Walkdir(root::String, topdown::Bool, follow::Bool, onerror::F) where {F} =
    Walkdir{F}(root, topdown, follow, onerror, WalkFrame[], false, false, nothing)

Base.IteratorSize(::Type{<:Walkdir}) = Base.SizeUnknown()
Base.eltype(::Type{<:Walkdir}) = Tuple{String,Vector{String},Vector{String}}

# `f(p)`, or `nothing` after an IOError given to `onerror` (if it throws, the end)
function walk_try(w::Walkdir, f::G, p) where {G}
    try
        return f(p)
    catch err
        isa(err, Base.IOError) || rethrow()
        try
            w.onerror(err)
        catch err2
            w.failed === nothing && (w.failed = err2)
        end
        return nothing
    end
end

# the directory `path`: (path, dirs, files, next), or nothing
function walk_visit(w::Walkdir, path::String)
    entries = walk_try(w, Base.Filesystem._readdirx, path)
    entries === nothing && return nothing
    dirs = Vector{String}()
    files = Vector{String}()
    for entry in entries::Vector{Base.Filesystem.DirEntry}
        # (not following symbolic links, they are files)
        if (!w.follow_symlinks && something(walk_try(w, islink, entry), true)) ||
           !something(walk_try(w, isdir, entry), false)
            push!(files, entry.name)
        else
            push!(dirs, entry.name)
        end
    end
    return WalkFrame(path, dirs, files, 0)
end

function Base.iterate(w::Walkdir, _=nothing)
    while true
        w.done && return nothing
        if w.failed !== nothing
            w.done = true
            throw(w.failed)
        end
        if !w.started
            w.started = true
            f = walk_visit(w, w.root)
            # (an error `onerror` threw: the end, with no value, as the task put none)
            w.failed === nothing || continue
            f === nothing && (w.done = true; continue)
            push!(w.stack, f)
            w.topdown && return ((f.path, f.dirs, f.files), nothing)
            continue
        end
        if isempty(w.stack)
            w.done = true
            return nothing
        end
        top = w.stack[end]
        if top.next < length(top.dirs)
            top.next += 1
            f = walk_visit(w, joinpath(top.path, top.dirs[top.next]))
            w.failed === nothing || continue
            f === nothing && continue
            push!(w.stack, f)
            w.topdown && return ((f.path, f.dirs, f.files), nothing)
        else
            pop!(w.stack)
            w.topdown || return ((top.path, top.dirs, top.files), nothing)
        end
    end
end
