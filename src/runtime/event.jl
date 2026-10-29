# The host's events, for `Config(host = :wasi, host_extensions = [:julia_io])`: timers and the
# one wait, `await_handle`, on the suspending `poll` (the `julia_io` imports, which
# `js/julia_io.mjs` provides and specifies). Also the host's file modes and symbolic links, in
# place of the defaults of `FS.path_mode`, `FS.path_chmod` and `FS.path_symlink_io` (see `fs.jl`).
#
# The module is a program of one task: there is no scheduler and no `Condition`. A wait is a
# loop of `poll` calls, which suspend the whole Wasm stack (JavaScript Promise Integration)
# until the host has an event. The host's readiness is level-triggered (a ready handle stays
# ready until the module consumes it), so a wait needs no buffer of the other handles found
# ready: they are found again.
#
# These functions call host imports: they run in Wasm only (natively, the library
# "julia_io" does not exist and the calls throw), but for `sleep_ns`, Base's `sleep` natively.
# Needs `Staging`, `Errno`, `FS` and `showerror_any` before it.

"""
    JuliaIO

The `julia_io` host functions (see `js/julia_io.mjs`), as `ccall`s of the library
"julia_io" (Wasm imports, for `Config(host = :wasi, host_extensions = [:julia_io])`).
Offsets are of the linear memory; statuses are 0 or a WASI errno, handle and count results
a value ≥ 0 or a negated WASI errno.
"""
module JuliaIO

timer_start(ns::Int64) = ccall((:timer_start, "julia_io"), Int32, (Int64,), ns)
poll(interest::UInt32, n_interest::Int32, timeout_ns::Int64, out::UInt32, cap::Int32) =
    ccall((:poll, "julia_io"), Int32, (UInt32, Int32, Int64, UInt32, Int32),
          interest, n_interest, timeout_ns, out, cap)
errmsg(h::Int32, out::UInt32, cap::UInt32) =
    ccall((:errmsg, "julia_io"), Int32, (Int32, UInt32, UInt32), h, out, cap)
cancel(h::Int32) = ccall((:cancel, "julia_io"), Int32, (Int32,), h)
close(h::Int32) = ccall((:close, "julia_io"), Int32, (Int32,), h)

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

The runtime's side of the host's events: [`await_handle`](@ref) and [`sleep_ns`](@ref).
Failures of the host are thrown as [`HostCallError`](@ref)s; [`error_text`](@ref) is the text
of an exception of any type.
"""
module Host

import ..Staging
import ..JuliaIO
import ..showerror_any
import ..Errno
using ..Runtime: @wasm_method, original

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

Wait until the handle `h` is ready (a timer fired). Returns at once if it is already ready.
Throws a `HostCallError` if the host has nothing to wait for (`EINVAL`).
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
@noinline sleep_ns(ns::Int64) = (original(Base.sleep, ns / 1e9); nothing)

function sleep_ns_wasm(ns::Int64)
    h = JuliaIO.timer_start(ns)
    h < 0 && throw_host(-h, Int32(-1))
    try
        await_handle(h)
    finally
        JuliaIO.close(h) # (in `finally`: not throwing over the error being thrown)
    end
    return nothing
end

@wasm_method sleep_ns(ns::Int64) = sleep_ns_wasm(ns)

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

end # Host
