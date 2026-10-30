# The runtime's linear memory (`Staging`), the functions of WASI preview 1 it calls (`ccall`s
# of the library "wasi_snapshot_preview1", Wasm imports for `Config(host = :wasi)`, see
# `foreigncall.jl`), and their errors (`Errno`).

"""
    Staging

The runtime's part of the linear memory (memory 0, exported as `"memory"`, see `host.jl`): its
layout, the primitives the runtime moves bytes with, and its scoped bump allocators. The
first page is the host interface's (`host.jl`: call results and the output buffer); the
runtime's starts at the second:

- `[BASE, BASE + 64 KiB)`: the arenas' state (`[BASE, BASE + 8)`) and the scratch regions
  below, valid only between building the arguments of one host call and its return (not
  scoped);
- `[RECORD_BASE, RECORD_END)` = `[128 KiB, 1 MiB + 64 KiB)`: the path and record arena;
- `[DATA_BASE, DATA_END)` = `[1 MiB + 64 KiB, 6 MiB + 64 KiB)`: the data arena (at most 1 MiB
  per allocation).

The memory is fixed at compile time when staging is used; allocations do not grow it.
Scopes share one pair of arena tops and support a single synchronous call stack, including
nested scopes. Pointers must not escape their scope. Threads, suspension inside a scope,
and reentrant host callbacks that reuse staging require separate ownership and are unsupported.

Hosts get offsets of this memory only as arguments of their functions, never as constants
of their own, so the layout can change.

Offsets are 0-based `UInt32`s. `load8`/`store8` ... are the memory's loads and stores in
Wasm; natively, in the build process, they read and write an array of the same size, so the
runtime's code runs there too. The arenas are scoped: [`with_scope`](@ref) releases what
was allocated in it, also when it throws, and nests. Records are packed: `u32`s
little-endian and unaligned, `str` a `u32` length then the bytes.
"""
module Staging

"The memory's pages when the runtime uses it: the host interface's, then the runtime's."
const PAGES = 97
const SIZE = UInt32(PAGES * 65536)

"The start of the runtime's part (the second page)."
const BASE = UInt32(0x10000)
# the arenas' state: the bytes used of each
const RECORD_USED = BASE
const DATA_USED = BASE + UInt32(4)
"256 bytes: single-call out-parameters (nwritten, filestat, ...)."
const SCRATCH_OUT = BASE + UInt32(0x0100)
"256 bytes: up to 16 iovecs (`buf u32, len u32`)."
const SCRATCH_IOVEC = BASE + UInt32(0x0200)
const RECORD_BASE = BASE + UInt32(0x10000)
const RECORD_END = BASE + UInt32(0x100000)
const DATA_BASE = BASE + UInt32(0x100000)
const DATA_END = BASE + UInt32(0x600000)
"The largest allocation of the data arena (an IO chunk)."
const CHUNK = UInt32(0x100000)

## the primitives: memory instructions in Wasm (see `overlays.jl`), an array natively

const NATIVE = UInt8[]

function native_memory()
    length(NATIVE) == SIZE || (resize!(NATIVE, SIZE); fill!(NATIVE, 0x00))
    return NATIVE
end

@noinline throw_out_of_bounds(off::UInt32, n::Int) =
    throw(ArgumentError(string("linear memory access out of bounds: ", n, " bytes at ", off)))

# the offset of `n` bytes at `off`, checked against the memory's size (in Wasm too, before
# each load and store: see `overlays.jl`)
function check(off::UInt32, n::Int)
    (n >= 0 && n <= Int(SIZE) - Int(off)) || throw_out_of_bounds(off, n)
    return Int(off)
end

@noinline load8(off::UInt32) = native_memory()[check(off, 1)+1]
@noinline function load16(off::UInt32)
    m, i = native_memory(), check(off, 2)
    return UInt16(m[i+1]) | UInt16(m[i+2]) << 8
end
@noinline function load32(off::UInt32)
    m, i = native_memory(), check(off, 4)
    return UInt32(m[i+1]) | UInt32(m[i+2]) << 8 | UInt32(m[i+3]) << 16 | UInt32(m[i+4]) << 24
end
@noinline load64(off::UInt32) = (check(off, 8); UInt64(load32(off)) | UInt64(load32(off + UInt32(4))) << 32)
@noinline store8(off::UInt32, v::UInt8) = (native_memory()[check(off, 1)+1] = v; nothing)
@noinline function store16(off::UInt32, v::UInt16)
    m, i = native_memory(), check(off, 2)
    m[i+1] = v % UInt8; m[i+2] = (v >> 8) % UInt8
    return nothing
end
@noinline function store32(off::UInt32, v::UInt32)
    m, i = native_memory(), check(off, 4)
    for k in 0:3
        m[i+k+1] = (v >> (8k)) % UInt8
    end
    return nothing
end
@noinline function store64(off::UInt32, v::UInt64)
    check(off, 8)   # (the whole range, before either half is written)
    store32(off, v % UInt32)
    store32(off + UInt32(4), (v >> 32) % UInt32)
    return nothing
end

## arenas

"""
    with_scope(f)

Call `f()` synchronously; what it allocates is released when it returns or throws.
Nested scopes are supported; pointers must not outlive the scope (see [`Staging`](@ref)).
"""
function with_scope(f::F) where {F}
    record, data = load32(RECORD_USED), load32(DATA_USED)
    try
        return f()
    finally
        store32(RECORD_USED, record)
        store32(DATA_USED, data)
    end
end

@noinline throw_overflow() = throw(ErrorException("staging overflow"))

# `n` bytes at the top of an arena, at an address aligned to `align` (computed as `Int`s, so
# that no rounding wraps around): an alignment the arena cannot have is an overflow
function alloc(used::UInt32, base::UInt32, stop::UInt32, n::Integer, align::Integer)
    (align >= 1 && ispow2(align)) || throw(ArgumentError("alignment $align is not a power of 2"))
    (n < 0 || align > Int(stop)) && throw_overflow()
    al = Int(align)
    top = Int(base) + Int(load32(used))
    a = (top + al - 1) & -al
    (a > Int(stop) || n > Int(stop) - a) && throw_overflow()
    store32(used, UInt32(a + Int(n) - Int(base)))
    return UInt32(a)
end

"`n` bytes of the record arena, until the end of the scope."
alloc_record(n::Integer; align::Integer=4) = alloc(RECORD_USED, RECORD_BASE, RECORD_END, n, align)
"`n` bytes (at most `CHUNK`) of the data arena, until the end of the scope."
function alloc_data(n::Integer; align::Integer=8)
    n > CHUNK && throw_overflow()
    return alloc(DATA_USED, DATA_BASE, DATA_END, n, align)
end

## copies between objects and the linear memory

"""
    copy_to_linear!(off, src, src_index, n)

Copy the `n` bytes of `src` (a `String`, `Memory{UInt8}` or `Vector{UInt8}`) from
`src_index` to the linear memory at `off`.
"""
function copy_to_linear!(off::UInt32, src::Union{String,Memory{UInt8},Vector{UInt8}}, src_index::Int, n::Int)
    (n >= 0 && src_index >= 1 && n <= sizeof(src) - (src_index - 1)) || throw(BoundsError(src, src_index))
    check(off, n)
    for k in 0:n-1
        b = src isa String ? codeunit(src, src_index + k) : @inbounds src[src_index+k]
        store8(off + UInt32(k), b)
    end
    return nothing
end

"""
    copy_from_linear!(dst, dst_index, off, n)

Copy `n` bytes of the linear memory at `off` to `dst` (a `Memory{UInt8}` or
`Vector{UInt8}`) from `dst_index`.
"""
function copy_from_linear!(dst::Union{Memory{UInt8},Vector{UInt8}}, dst_index::Int, off::UInt32, n::Int)
    (n >= 0 && dst_index >= 1 && n <= length(dst) - (dst_index - 1)) || throw(BoundsError(dst, dst_index))
    check(off, n)
    for k in 0:n-1
        @inbounds dst[dst_index+k] = load8(off + UInt32(k))
    end
    return nothing
end

"Copy the `n` bytes at the pointer `p` to the linear memory at `off`."
function copy_ptr_to_linear!(off::UInt32, p::Ptr{UInt8}, n::Int)
    check(off, n)
    for k in 1:n
        store8(off + UInt32(k - 1), unsafe_load(p, k))
    end
    return nothing
end

## records

"Write the u32 `v` at `off`; the offset after it."
put_u32!(off::UInt32, v::Integer) = (store32(off, UInt32(v)); off + UInt32(4))
"The u32 at `off`."
get_u32(off::UInt32) = load32(off)

"Write the `str` `s` (u32 length, bytes) at `off`; the offset after it."
function put_str!(off::UInt32, s::Union{String,SubString{String}})
    str = String(s)
    n = sizeof(str)
    off = put_u32!(off, n)
    copy_to_linear!(off, str, 1, n)
    return off + UInt32(n)
end

"The `str` at `off`, and the offset after it."
function get_str(off::UInt32)
    n = load32(off)
    check(off + UInt32(4), Int(n))
    buf = Vector{UInt8}(undef, n)
    copy_from_linear!(buf, 1, off + UInt32(4), Int(n))
    return (String(buf), off + UInt32(4) + n)
end

"""
    raw_path(s) -> (off, len)

The bytes of `s` (no length, no NUL) in the record arena of the current scope.
"""
function raw_path(s::String)
    n = sizeof(s)
    off = alloc_record(n; align=1)
    copy_to_linear!(off, s, 1, n)
    return (off, UInt32(n))
end

end # Staging

"""
    WASI

The host functions of WASI preview 1 the runtime uses (`ccall`s of the library
"wasi_snapshot_preview1", Wasm imports), with their standard signatures: pointers are
offsets of the linear memory, the result is a WASI errno (0: success).
"""
module WASI

const ESUCCESS = Int32(0)

const CLOCK_REALTIME = UInt32(0)
const CLOCK_MONOTONIC = UInt32(1)

fd_write(fd::Int32, iovs::UInt32, iovs_len::UInt32, nwritten::UInt32) =
    ccall((:fd_write, "wasi_snapshot_preview1"), Int32, (Int32, UInt32, UInt32, UInt32),
          fd, iovs, iovs_len, nwritten)
clock_time_get(id::UInt32, precision::UInt64, time::UInt32) =
    ccall((:clock_time_get, "wasi_snapshot_preview1"), Int32, (UInt32, UInt64, UInt32),
          id, precision, time)

end # WASI

"""
    Errno

WASI errnos (preview 1 numbering) mapped by name to the build platform's `Base.UV_E*`
codes. ENOTCAPABLE becomes EACCES; errors without a libuv equivalent and unknown WASI
codes become EIO. Guest libc errno numbers are a separate, fixed Linux ABI, independent
of the build host. Messages are captured natively when the package loads.
"""
module Errno

# the names of WASI's errnos, from 0
const WASI_NAMES = (:SUCCESS, :E2BIG, :EACCES, :EADDRINUSE, :EADDRNOTAVAIL, :EAFNOSUPPORT, :EAGAIN,
    :EALREADY, :EBADF, :EBADMSG, :EBUSY, :ECANCELED, :ECHILD, :ECONNABORTED, :ECONNREFUSED,
    :ECONNRESET, :EDEADLK, :EDESTADDRREQ, :EDOM, :EDQUOT, :EEXIST, :EFAULT, :EFBIG, :EHOSTUNREACH,
    :EIDRM, :EILSEQ, :EINPROGRESS, :EINTR, :EINVAL, :EIO, :EISCONN, :EISDIR, :ELOOP, :EMFILE,
    :EMLINK, :EMSGSIZE, :EMULTIHOP, :ENAMETOOLONG, :ENETDOWN, :ENETRESET, :ENETUNREACH, :ENFILE,
    :ENOBUFS, :ENODEV, :ENOENT, :ENOEXEC, :ENOLCK, :ENOLINK, :ENOMEM, :ENOMSG, :ENOPROTOOPT,
    :ENOSPC, :ENOSYS, :ENOTCONN, :ENOTDIR, :ENOTEMPTY, :ENOTRECOVERABLE, :ENOTSOCK, :ENOTSUP,
    :ENOTTY, :ENXIO, :EOVERFLOW, :EOWNERDEAD, :EPERM, :EPIPE, :EPROTO, :EPROTONOSUPPORT,
    :EPROTOTYPE, :ERANGE, :EROFS, :ESPIPE, :ESRCH, :ESTALE, :ETIMEDOUT, :ETXTBSY, :EXDEV,
    :ENOTCAPABLE)

"The fixed guest libc errno of each WASI errno (index: the WASI errno + 1)."
const LINUX = Int32[0, 7, 13, 98, 99, 97, 11, 114, 9, 74, 16, 125, 10, 103, 111,
    104, 35, 89, 33, 122, 17, 14, 27, 113, 43, 84, 115, 4, 22, 5, 106, 21, 40, 24,
    31, 90, 72, 36, 100, 102, 101, 23, 105, 19, 2, 8, 37, 67, 12, 42, 92, 28, 38,
    107, 20, 39, 131, 88, 95, 25, 6, 75, 130, 1, 32, 71, 93, 91, 34, 30, 29, 3,
    116, 110, 26, 18, 13]

# Resolve by libuv name, never by negating a libc errno. Some WASI/POSIX errors
# (e.g. EDOM, EOWNERDEAD) have no libuv name; report EIO for those.
const UV = Int32[name === :SUCCESS ? 0 :
    getglobal(Base, isdefined(Base, Symbol(:UV_, name === :ENOTCAPABLE ? :EACCES : name)) ?
        Symbol(:UV_, name === :ENOTCAPABLE ? :EACCES : name) : :UV_EIO) for name in WASI_NAMES]

# Include all of Base's libuv codes, including Windows's non-libc numbering and EOF.
const UV_CODES = Int32[v for (_, v) in Base.uv_err_vals]
const UV_STRERROR = String[Base.struverror(c) for c in UV_CODES]
const UV_NAME = String[Base.uverrorname(c) for c in UV_CODES]

"The libuv code of WASI errno `e` (`UV_EIO` for unknown or unrepresentable errors)."
uv_code(e::Integer) = 0 <= e < length(UV) ? UV[e+1] : Int32(Base.UV_EIO)

"`uv_strerror(code)`, as libuv's."
function uv_message(code::Integer)
    i = findfirst(==(code), UV_CODES)
    return i === nothing ? string("Unknown system error ", code) : UV_STRERROR[i]
end
"`uv_err_name(code)`, as libuv's."
function uv_name(code::Integer)
    i = findfirst(==(code), UV_CODES)
    return i === nothing ? string("Unknown system error ", code) : UV_NAME[i]
end

# Guest libc numbers stay fixed even when the build libc uses different numbers.
const NERR = 134
const STRERROR = let messages = String[string("Unknown error ", e) for e in 0:NERR-1]
    messages[1] = Base.Libc.strerror(Int32(0))
    for (i, name) in enumerate(WASI_NAMES)
        name === :SUCCESS && continue
        native_name = name === :ENOTCAPABLE ? :EACCES : name
        messages[LINUX[i]+1] = isdefined(Base.Libc, native_name) ?
            Base.Libc.strerror(Int32(getglobal(Base.Libc, native_name))) : uv_message(UV[i])
    end
    messages
end

"`strerror(errno)` for the guest's fixed Linux libc errno ABI."
strerror(e::Integer) = 0 <= e < NERR ? STRERROR[e+1] : string("Unknown error ", e)

end # Errno

# an error of the host (a WASI errno) as libuv's errors are (`Base._UVError`)
@noinline function wasi_check(r::Int32, what::String)
    r == WASI.ESUCCESS || throw_uv_error(what, Errno.uv_code(r))
    return nothing
end
@noinline throw_uv_error(what::String, code::Int32) =
    throw(Base.IOError(string(what, ": ", Errno.uv_message(code), " (", Errno.uv_name(code), ")"), code))
