# The host's events, for `Config(host = :wasi, host_extensions = [:julia_io])`: timers, HTTP
# requests and their bodies, decompression, the host's platform, and the one wait,
# `await_handle`, on the suspending `poll` (the `julia_io` imports, which `js/julia_io.mjs`
# provides and specifies). Also the host's file modes and symbolic links, in place of the
# defaults of `FS.path_mode`, `FS.path_chmod` and `FS.path_symlink_io` (see `fs.jl`).
#
# The module is a program of one task: there is no scheduler and no `Condition`. A wait is a
# loop of `poll` calls, which suspend the whole Wasm stack (JavaScript Promise Integration)
# until the host has an event. The host's readiness is level-triggered (a ready handle stays
# ready until the module consumes it), so a wait needs no buffer of the other handles found
# ready: they are found again.
#
# These functions call host imports: they run in Wasm only (natively, the library
# "julia_io" does not exist and the calls throw), but for `sleep_ns`, a twin. Needs
# `Staging`, `Errno`, `FS` and `showerror_any` before it.

"""
    JuliaIO

The `julia_io` host functions (see `js/julia_io.mjs`), as `ccall`s of the library
"julia_io" (Wasm imports, for `Config(host = :wasi, host_extensions = [:julia_io])`).
Offsets are of the linear memory; statuses are 0 or a WASI errno, handle and count results
a value ≥ 0 or a negated WASI errno.
"""
module JuliaIO

http_start(spec::UInt32, len::UInt32) =
    ccall((:http_start, "julia_io"), Int32, (UInt32, UInt32), spec, len)
http_head(h::Int32, out::UInt32, cap::UInt32) =
    ccall((:http_head, "julia_io"), Int32, (Int32, UInt32, UInt32), h, out, cap)
read(h::Int32, off::UInt32, len::UInt32) =
    ccall((:read, "julia_io"), Int64, (Int32, UInt32, UInt32), h, off, len)
timer_start(ns::Int64) = ccall((:timer_start, "julia_io"), Int32, (Int64,), ns)
poll(interest::UInt32, n_interest::Int32, timeout_ns::Int64, out::UInt32, cap::Int32) =
    ccall((:poll, "julia_io"), Int32, (UInt32, Int32, Int64, UInt32, Int32),
          interest, n_interest, timeout_ns, out, cap)
errmsg(h::Int32, out::UInt32, cap::UInt32) =
    ccall((:errmsg, "julia_io"), Int32, (Int32, UInt32, UInt32), h, out, cap)
cancel(h::Int32) = ccall((:cancel, "julia_io"), Int32, (Int32,), h)
close(h::Int32) = ccall((:close, "julia_io"), Int32, (Int32,), h)
decompress(src::UInt32, src_len::UInt32, dst::UInt32, dst_len::UInt32) =
    ccall((:decompress, "julia_io"), Int32, (UInt32, UInt32, UInt32, UInt32), src, src_len, dst, dst_len)
host_platform(out::UInt32, cap::UInt32) =
    ccall((:host_platform, "julia_io"), Int32, (UInt32, UInt32), out, cap)

# the host's file modes and symbolic links of any target (the seams of `FS`: same signatures)
path_mode(path::UInt32, len::UInt32, follow::Int32) =
    ccall((:path_mode, "julia_io"), Int32, (UInt32, UInt32, Int32), path, len, follow)
path_chmod(path::UInt32, len::UInt32, mode::Int32) =
    ccall((:path_chmod, "julia_io"), Int32, (UInt32, UInt32, Int32), path, len, mode)
path_symlink(target::UInt32, tlen::UInt32, link::UInt32, llen::UInt32) =
    ccall((:path_symlink, "julia_io"), Int32, (UInt32, UInt32, UInt32, UInt32), target, tlen, link, llen)

end # JuliaIO

# (only in modules whose host has `julia_io`: others keep the defaults, a host without modes)
EXTENSION_IMPLS[:julia_io] = IdDict{Any,Any}(FS.path_mode => JuliaIO.path_mode,
                                             FS.path_chmod => JuliaIO.path_chmod,
                                             FS.path_symlink_io => JuliaIO.path_symlink)

"""
    Host

The runtime's side of the host's events: [`await_handle`](@ref), [`sleep_ns`](@ref),
[`http_start`](@ref), [`http_head`](@ref), [`http_read!`](@ref), [`http_download`](@ref),
[`decompress`](@ref) and [`host_platform`](@ref). Failures of the host are thrown as
[`HostCallError`](@ref)s.
"""
module Host

import ..Staging
import ..JuliaIO
import ..showerror_any
import ..Errno
import ..Twins
using ..Runtime: WASM_IMPLS

const EAGAIN = Int32(6)
const ECANCELED = Int32(11)
const EINVAL = Int32(28)
const EIO = Int32(29)
const ENOBUFS = Int32(42)

"The largest body chunk read at once (`Staging.alloc_data` takes at most 1 MiB)."
const CHUNK = Int(Staging.CHUNK)

"""
    HostCallError(errno, msg)

A failure the host reported: `errno` is a WASI errno, `msg` the host's message (`errmsg`).
"""
struct HostCallError <: Exception
    errno::Int32
    msg::String
end

Base.showerror(io::IO, e::HostCallError) = print(io, "HostCallError: ", e.msg, " (errno ", e.errno, ")")

"The host's message for the handle `h` (`-1`: the last failure without a handle)."
function errmsg(h::Int32)
    Staging.with_scope() do
        cap = UInt32(4096)
        off = Staging.alloc_record(cap)
        n = JuliaIO.errmsg(h, off, cap)
        n < 0 ? string("(no message: errmsg returned ", n, ")") : get_bytes(off, UInt32(n))
    end
end

# the string of the `n` bytes at `off`
function get_bytes(off::UInt32, n::UInt32)
    buf = Vector{UInt8}(undef, Int(n))
    Staging.copy_from_linear!(buf, 1, off, Int(n))
    return String(buf)
end

@noinline throw_host(errno::Integer, h::Int32) = throw(HostCallError(Int32(errno), errmsg(h)))

"Release the handle `h` (once: closing a closed handle is an error)."
function close(h::Int32)
    r = JuliaIO.close(h)
    r == 0 || throw_host(-r, Int32(-1))
    return nothing
end

"""
    await_handle(h)

Wait until the handle `h` is ready (a timer fired; an HTTP head, body bytes, the end of the
body or an error is available). Returns at once if it is already ready. Throws a
`HostCallError` if the host has nothing to wait for (`EINVAL`).
"""
function await_handle(h::Int32)
    # (the interest set is `h` alone: other ready handles are not reported, and stay ready)
    while true
        ready = Staging.with_scope() do
            interest = Staging.alloc_record(4)
            out = Staging.alloc_record(4)
            Staging.store32(interest, h % UInt32)
            n = JuliaIO.poll(interest, Int32(1), Int64(-1), out, Int32(1))
            n < 0 && throw_host(-n, Int32(-1))
            n == 1 && Staging.load32(out) % Int32 == h
        end
        ready && return nothing
    end
end

"""
    sleep_ns(ns)

Wait `ns` nanoseconds on a host timer; the host's event loop runs meanwhile. (Natively, in
the build process, Base's `sleep`.)
"""
@noinline sleep_ns(ns::Int64) = (Twins.original(Base.sleep, ns / 1e9); nothing)

@noinline function sleep_ns_wasm(ns::Int64)
    h = JuliaIO.timer_start(ns)
    h < 0 && throw_host(-h, Int32(-1))
    try
        await_handle(h)
    finally
        JuliaIO.close(h) # (in `finally`: not throwing over the error being thrown)
    end
    return nothing
end

WASM_IMPLS[sleep_ns] = sleep_ns_wasm

## HTTP

"The head of an HTTP response: status, URL after redirects, headers (names as the server sent them)."
struct Head
    status::Int
    url::String
    headers::Vector{Pair{String,String}}
end

const FOLLOW_REDIRECTS = UInt32(1)

# the size of a packed string
packed(s::String) = 4 + sizeof(s)

# the request record of `http_start`, in the record arena of the current scope: (offset,
# length)
function put_spec(method::String, url::String, headers::Vector{Pair{String,String}}, follow::Bool)
    n = packed(method) + packed(url) + 4 + 4
    for (k, v) in headers
        n += packed(k) + packed(v)
    end
    spec = Staging.alloc_record(n)
    p = Staging.put_str!(spec, method)
    p = Staging.put_str!(p, url)
    p = Staging.put_u32!(p, UInt32(length(headers)))
    for (k, v) in headers
        p = Staging.put_str!(p, k)
        p = Staging.put_str!(p, v)
    end
    Staging.put_u32!(p, follow ? FOLLOW_REDIRECTS : UInt32(0))
    return spec, UInt32(n)
end

"""
    http_start(method, url, headers; follow=true) -> handle

Start an HTTP request (no body). Throws a `HostCallError` if the host refuses it.
"""
function http_start(method::String, url::String, headers::Vector{Pair{String,String}}; follow::Bool=true)
    Staging.with_scope() do
        spec, n = put_spec(method, url, headers, follow)
        h = JuliaIO.http_start(spec, n)
        h < 0 && throw_host(-h, Int32(-1))
        h
    end
end

@noinline malformed() = throw(HostCallError(EIO, "http_head: malformed record"))

# a packed string of the record ending at `stop`
function get_packed(p::UInt32, stop::UInt32)
    p + UInt32(4) <= stop || malformed()
    Staging.get_u32(p) <= stop - p - UInt32(4) || malformed()
    return Staging.get_str(p)
end

function decode_head(off::UInt32, len::UInt32)
    stop = off + len
    len >= UInt32(4) || malformed()
    status = Int(Staging.get_u32(off))
    url, p = get_packed(off + UInt32(4), stop)
    p + UInt32(4) <= stop || malformed()
    k = Staging.get_u32(p); p += UInt32(4)
    k <= len || malformed()
    headers = Vector{Pair{String,String}}(undef, Int(k))
    for i in 1:Int(k)
        name, p = get_packed(p, stop)
        value, p = get_packed(p, stop)
        headers[i] = name => value
    end
    p == stop || malformed()
    return Head(status, url, headers)
end

const HEAD_CAP = UInt32(16 * 1024)

# the head of `h` if the host has it: a record of at most `cap` bytes at a scoped offset, or
# the negated errno (-ENOBUFS: the record needs more: its size is at the offset)
function try_head(h::Int32, cap::UInt32)
    Staging.with_scope() do
        off = Staging.alloc_record(cap)
        n = JuliaIO.http_head(h, off, cap)
        n >= 0 ? (n, decode_head(off, UInt32(n))) : (n, n == -ENOBUFS ? Staging.get_u32(off) : UInt32(0))
    end
end

"The head of the response of the request `h`, waiting for it."
function http_head(h::Int32)
    cap = HEAD_CAP
    while true
        n, r = try_head(h, cap)
        r isa Head && return r
        if n == -ENOBUFS
            cap = r::UInt32 # (a larger record: retried with the size it needs)
        elseif n == -EAGAIN
            await_handle(h)
        else
            throw_host(-n, h)
        end
    end
end

"""
    http_read!(h, head, buf) -> n

Read the next bytes (at most `length(buf)`, and at most `CHUNK`) of the body of the request
`h` into `buf`, waiting for them; `0` at the end of the body. `head` is the request's head
from [`http_head`](@ref): the body is read after it, since a head not taken keeps the
handle ready and a wait for body bytes would not wait.
"""
function http_read!(h::Int32, ::Head, buf::Vector{UInt8})
    len = UInt32(min(length(buf), CHUNK))
    while true
        n = Staging.with_scope() do
            off = Staging.alloc_data(len)
            r = JuliaIO.read(h, off, len)
            r > 0 && Staging.copy_from_linear!(buf, 1, off, Int(r))
            r
        end
        n >= 0 && return Int(n)
        if n == -EAGAIN
            await_handle(h)
        else
            throw_host(-n, h)
        end
    end
end

"""
    http_download(url, dest, headers) -> Head

GET `url` into the file `dest`, following redirects (at most 10): the body is written to
`dest * ".partial"` (a stale one is removed first), and published by a single rename, which
replaces `dest` atomically or fails leaving it as it was (no delete-and-copy fallback,
unlike `mv(...; force=true)`). On an HTTP status ≥ 400 the body is read to its end but not
written; then `dest` is removed. On any failure (transport, file system, publication) the
partial file is removed and a previous `dest` is left as it was. Transport failures throw
`HostCallError`s, file system ones Base's errors; a failure to remove the partial file is
reported with the original error, as a `HostCallError` (`EIO`).
"""
function http_download(url::String, dest::String, headers::Vector{Pair{String,String}})
    tmp = dest * ".partial"
    rm(tmp; force=true)
    h = http_start("GET", url, headers)
    try
        head = http_head(h)
        buf = Vector{UInt8}(undef, CHUNK)
        if head.status >= 400
            # (the whole error response: a transport failure in it is an error, which leaves
            # `dest` as it was)
            try
                while http_read!(h, head, buf) != 0 end
            catch
                JuliaIO.cancel(h)
                rethrow()
            end
            rm(dest; force=true)
            return head
        end
        try
            open(tmp, "w") do io
                while true
                    n = http_read!(h, head, buf)
                    n == 0 && break
                    GC.@preserve buf unsafe_write(io, pointer(buf), UInt(n))
                end
            end
            Base.rename(tmp, dest)
        catch err
            JuliaIO.cancel(h)
            remove_partial(tmp, err)
            rethrow()
        end
        return head
    finally
        JuliaIO.close(h) # (in `finally`: not throwing over the error being thrown)
    end
end

"""
    error_text(e) -> String

The text `showerror` shows for the exception `e`, of any type: in a closed world a caught
exception is of no known type, and `sprint(showerror, e)` is a dynamic call
(`showerror_any` shows the runtime's and Base's usual exceptions).
"""
function error_text(@nospecialize(e))
    e isa HostCallError && return string(e.msg, " (errno ", e.errno, ")")
    e isa SystemError && return system_error_text(e)
    io = IOBuffer()
    showerror_any(io, e)
    return String(take!(io))
end

# a SystemError as Base shows it (`showerror_any` does not know its `extrainfo`, of any type
# in Base): its `extrainfo` is shown when it is a string or an integer
function system_error_text(e::SystemError)
    x = e.extrainfo
    with = x === nothing ? "" :
           x isa String ? string(" (with ", x, ")") :
           x isa Int ? string(" (with ", x, ")") :
           " (with information the runtime cannot show)"
    return string("SystemError", with, ": ", e.prefix, ": ", Errno.strerror(e.errnum))
end

# remove the partial file `tmp` after the failure `err`, reporting a failure to
@noinline function remove_partial(tmp::String, @nospecialize(err))
    try
        rm(tmp; force=true)
    catch rm_err
        throw(HostCallError(EIO, string(error_text(err), "; additionally failed to remove ",
                                        tmp, ": ", error_text(rm_err))))
    end
    return nothing
end

"""
    decompress(src, dst)

Decompress the gzip or zstd file `src` (by its magic bytes) into `dst`, synchronously, on
the host. Throws a `HostCallError` (`EILSEQ`: not gzip or zstd, or malformed; `EIO`:
truncated; or the file system's errno).
"""
function decompress(src::String, dst::String)
    # (the host takes absolute paths: a relative one is of the working directory, as natively;
    # an empty one is passed as it is, for the host to reject, not made the working directory;
    # new bindings, which the closure captures unboxed)
    asrc = isempty(src) ? src : abspath(src)
    adst = isempty(dst) ? dst : abspath(dst)
    Staging.with_scope() do
        s, sn = Staging.raw_path(asrc)
        d, dn = Staging.raw_path(adst)
        r = JuliaIO.decompress(s, sn, d, dn)
        r == 0 || throw_host(r, Int32(-1))
    end
    return nothing
end

## the host's platform

# the record `u32 n, (str key, str value)*n` of `len` bytes at `off`
function decode_platform(off::UInt32, len::UInt32)
    stop = off + len
    len >= UInt32(4) || malformed()
    k = Staging.get_u32(off)
    k <= len || malformed()
    p = off + UInt32(4)
    tags = Vector{Pair{String,String}}(undef, Int(k))
    for i in 1:Int(k)
        key, p = get_packed(p, stop)
        value, p = get_packed(p, stop)
        tags[i] = key => value
    end
    p == stop || malformed()
    return tags
end

function try_platform(cap::UInt32)
    Staging.with_scope() do
        off = Staging.alloc_record(cap)
        n = JuliaIO.host_platform(off, cap)
        n >= 0 ? (n, decode_platform(off, UInt32(n))) : (n, n == -ENOBUFS ? Staging.get_u32(off) : UInt32(0))
    end
end

"""
    host_platform() -> Vector{Pair{String,String}}

The tags of the host machine (`"arch" => "x86_64"`, `"os" => "linux"`, `"libc" => "glibc"`,
...), as the host detects them and its configuration overrides them, in its order, with the
names of `Base.BinaryPlatforms`. Never `julia_version`: the program adds its own. Throws a
`HostCallError` if the host cannot tell (`ENOTSUP`).
"""
function host_platform()
    cap = UInt32(1024)
    while true
        n, r = try_platform(cap)
        r isa Vector{Pair{String,String}} && return r
        n == -ENOBUFS || throw_host(-n, Int32(-1))
        cap = r::UInt32
    end
end

end # Host
