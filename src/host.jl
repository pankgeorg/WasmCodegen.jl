# The host interface: what the module needs of the world outside it. The runtime's host
# primitives are writing bytes to stdout or stderr (`write_byte`, then `flush_output` when
# a write completes), entropy for the seed of the random number generator (`entropy`), a
# monotonic clock in nanoseconds (`hrtime`) and the time of day in seconds since the Unix
# epoch (`clock_now`). `Config(host = ...)` chooses how the module imports them:
#
# - `:js`: functions of the import module `julia`: `write_byte(fd: i32, byte: i32)`,
#   `entropy() -> i64`, `hrtime() -> i64` and `clock_now() -> f64`, which `js/julia.mjs`
#   provides (flushing is the host's: nothing is buffered in the module).
# - `:wasi`: WASI preview 1 (`wasi_snapshot_preview1`): `fd_write`, `random_get` and
#   `clock_time_get`, as other languages compiling to WASI do. WASI passes data through
#   linear memory: the module has one page of it, exported as `memory` (as WASI requires),
#   holding the results of calls and a buffer of output, written by `fd_write` when a
#   write completes or the buffer is full. Initialization runs from the exported
#   `_initialize` (a WASI reactor) rather than a start function: WASI calls need the
#   instance's memory, which the host has only once the instance is made.

"The path of `js/julia.mjs`, the JavaScript host of the modules, to copy next to a module."
const JS_HOST = normpath(joinpath(@__DIR__, "..", "js", "julia.mjs"))

const HOST_PRIMITIVES = Dict(:write_byte => (ValType[I32, I32], ValType[]),
                             :entropy => (ValType[], ValType[I64]),
                             :hrtime => (ValType[], ValType[I64]),
                             :clock_now => (ValType[], ValType[F64]))

"""
    host_func!(cgm, name) -> Func

The function of the host primitive `name` (`:write_byte`, `:entropy`, `:hrtime`,
`:clock_now`): the import `julia.name`, or for WASI a function of the module over WASI's.
"""
function host_func!(cgm::CGModule, name::Symbol)
    cgm.config.host === :wasi && return wasi_func!(cgm, name)
    return host_import!(cgm, string(name), HOST_PRIMITIVES[name]...)
end

"""
    host_import!(cgm, name, params, results) -> Func

The function `name` the host provides (import module `julia`), the runtime's interface to
the world outside: see `js/julia.mjs` for what each one does.
"""
host_import!(cgm::CGModule, name::AbstractString, params::Vector{ValType}, results::Vector{ValType}) =
    add_import!(cgm.mod, "julia", name, params, results)

"`flush_output`: the end of a write, the output buffered so far written out (WASI)."
function emit_flush_output!(fc::FnCtx)
    fc.cgm.config.host === :wasi && call!(fc.b, wasi_func!(fc.cgm, :flush_output))
    return ghost(Nothing, nothing)
end

"The module's part of the host interface, once the module is complete: WASI's memory."
function finish_host!(cgm::CGModule)
    cgm.config.host === :wasi && wasi_memory!(cgm)
    return nothing
end

"""
    staging_memory!(cgm)

The linear memory, of the pages the runtime's part needs too (`Runtime.Staging`, from the
second page), when the module uses it: a module that does not keeps one page.
"""
function staging_memory!(cgm::CGModule)
    get!(cgm.helpers, :staging_memory) do
        mem = wasi_memory!(cgm)
        mem.min = max(mem.min, Int(Runtime.Staging.PAGES))
        mem.max === nothing || (mem.max = max(mem.max, mem.min))
        mem
    end
end

## WASI

const WASI = "wasi_snapshot_preview1"

# the exports of a WASI module that are not entry points
const WASI_EXPORTS = ("memory", "_initialize")

# the layout of the linear memory: the 8 bytes of a call's result, an iovec (the address
# and length of bytes for `fd_write`), the count of bytes `fd_write` wrote, and the output
# buffer (the rest of the page)
const WASI_RESULT = 0
const WASI_IOVEC = 8
const WASI_NWRITTEN = 16
const WASI_OUT = 64
const WASI_OUT_SIZE = 65536 - WASI_OUT

# WASI's clocks (`clockid`)
const WASI_CLOCK_REALTIME = 0
const WASI_CLOCK_MONOTONIC = 1

"The function `name` of WASI preview 1 (each returns an errno, 0 on success)."
wasi_import!(cgm::CGModule, name::AbstractString, params::Vector{ValType}) =
    add_import!(cgm.mod, WASI, name, params, ValType[I32])

"The module's linear memory, for WASI's calls: one page, exported as `memory`."
wasi_memory!(cgm::CGModule) = get!(cgm.helpers, :wasi_memory) do
    mem = add_memory!(cgm.mod, 1)
    add_export!(cgm.mod, "memory", mem)
    mem
end

# trap unless the errno on the stack is 0 (a call that cannot fail on a working host)
function wasi_check!(b::Builder)
    if!(b); unreachable!(b); end!(b)
end

"""
    wasi_func!(cgm, name) -> Func

The host primitive `name` over WASI preview 1 (and `:flush_output`, writing out the output
buffer).
"""
function wasi_func!(cgm::CGModule, name::Symbol)
    get!(cgm.helpers, Symbol(:wasi_, name)) do
        wasi_memory!(cgm)
        if name === :write_byte || name === :flush_output
            return wasi_output!(cgm)[name]
        end
        f = add_func!(cgm.mod, "jl_wasi_" * string(name), HOST_PRIMITIVES[name]...)
        b = Builder(cgm.mod, f)
        if name === :entropy
            # random_get(buf, len)
            emit!(b, :i32_const, WASI_RESULT); emit!(b, :i32_const, 8)
            call!(b, wasi_import!(cgm, "random_get", ValType[I32, I32]))
        elseif name === :hrtime
            # clock_time_get(id, precision, time)
            emit!(b, :i32_const, WASI_CLOCK_MONOTONIC); emit!(b, :i64_const, 1); emit!(b, :i32_const, WASI_RESULT)
            call!(b, wasi_import!(cgm, "clock_time_get", ValType[I32, I64, I32]))
        elseif name === :clock_now
            # the real-time clock to the microsecond, as seconds and microseconds, as natively
            # (`jl_clock_now`: gettimeofday's `tv_sec + tv_usec * 1e-6`)
            emit!(b, :i32_const, WASI_CLOCK_REALTIME); emit!(b, :i64_const, 1000); emit!(b, :i32_const, WASI_RESULT)
            call!(b, wasi_import!(cgm, "clock_time_get", ValType[I32, I64, I32]))
            wasi_check!(b)
            ns = add_local!(f, I64)
            emit!(b, :i32_const, WASI_RESULT); emit!(b, :i64_load, 3, 0); emit!(b, :local_set, ns)
            emit!(b, :local_get, ns); emit!(b, :i64_const, 1_000_000_000); emit!(b, :i64_div_u)
            emit!(b, :f64_convert_i64_u)
            emit!(b, :local_get, ns); emit!(b, :i64_const, 1_000_000_000); emit!(b, :i64_rem_u)
            emit!(b, :i64_const, 1000); emit!(b, :i64_div_u); emit!(b, :f64_convert_i64_u)
            emit!(b, :f64_const, 1.0e-6); emit!(b, :f64_mul); emit!(b, :f64_add)
            finish!(b)
            return f
        else
            error("no host primitive $name")
        end
        wasi_check!(b)
        emit!(b, :i32_const, WASI_RESULT); emit!(b, :i64_load, 3, 0)
        finish!(b)
        f
    end
end

"""
The output functions over WASI's `fd_write`: `write_byte(fd, byte)` appends to the buffer
(first writing out what it holds when it is full or for another file descriptor), and
`flush_output()` writes the buffer out.
"""
function wasi_output!(cgm::CGModule)
    get!(cgm.helpers, :wasi_output) do
        len = add_global!(cgm.mod, "jl_wasi_out_len", I32, true, Inst[Inst(:i32_const, 0)])
        fd = add_global!(cgm.mod, "jl_wasi_out_fd", I32, true, Inst[Inst(:i32_const, 1)])
        fd_write = wasi_import!(cgm, "fd_write", ValType[I32, I32, I32, I32])
        # flush_output(): fd_write until all is written (or it fails: the output is lost)
        flush = add_func!(cgm.mod, "jl_wasi_flush_output", ValType[], ValType[])
        b = Builder(cgm.mod, flush)
        p, n = add_local!(flush, I32), add_local!(flush, I32)
        emit!(b, :i32_const, WASI_OUT); emit!(b, :local_set, p)
        emit!(b, :global_get, len); emit!(b, :local_set, n)
        emit!(b, :i32_const, 0); emit!(b, :global_set, len)
        block!(b); loop!(b)
        emit!(b, :local_get, n); emit!(b, :i32_eqz); br_if!(b, 1)
        emit!(b, :i32_const, WASI_IOVEC); emit!(b, :local_get, p); emit!(b, :i32_store, 2, 0)
        emit!(b, :i32_const, WASI_IOVEC); emit!(b, :local_get, n); emit!(b, :i32_store, 2, 4)
        emit!(b, :global_get, fd); emit!(b, :i32_const, WASI_IOVEC); emit!(b, :i32_const, 1)
        emit!(b, :i32_const, WASI_NWRITTEN)
        call!(b, fd_write)
        br_if!(b, 1)
        # (nothing written: give up rather than loop)
        emit!(b, :i32_const, WASI_NWRITTEN); emit!(b, :i32_load, 2, 0); emit!(b, :i32_eqz); br_if!(b, 1)
        emit!(b, :local_get, p); emit!(b, :i32_const, WASI_NWRITTEN); emit!(b, :i32_load, 2, 0)
        emit!(b, :i32_add); emit!(b, :local_set, p)
        emit!(b, :local_get, n); emit!(b, :i32_const, WASI_NWRITTEN); emit!(b, :i32_load, 2, 0)
        emit!(b, :i32_sub); emit!(b, :local_set, n)
        br!(b, 0)
        end!(b); end!(b)
        finish!(b)
        # write_byte(fd, byte)
        write = add_func!(cgm.mod, "jl_wasi_write_byte", HOST_PRIMITIVES[:write_byte]...)
        b = Builder(cgm.mod, write)
        emit!(b, :global_get, len); emit!(b, :i32_const, WASI_OUT_SIZE); emit!(b, :i32_eq)
        emit!(b, :global_get, len); emit!(b, :i32_const, 0); emit!(b, :i32_ne)
        emit!(b, :global_get, fd); emit!(b, :local_get, 0); emit!(b, :i32_ne)
        emit!(b, :i32_and); emit!(b, :i32_or)
        if!(b); call!(b, flush); end!(b)
        emit!(b, :local_get, 0); emit!(b, :global_set, fd)
        emit!(b, :global_get, len); emit!(b, :local_get, 1); emit!(b, :i32_store8, 0, WASI_OUT)
        emit!(b, :global_get, len); emit!(b, :i32_const, 1); emit!(b, :i32_add); emit!(b, :global_set, len)
        finish!(b)
        Dict(:write_byte => write, :flush_output => flush)
    end
end
