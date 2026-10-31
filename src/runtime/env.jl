# The environment (`ENV`): a snapshot of the host's (WASI `environ_get`), read on
# first use, that `setenv`/`unsetenv` change (WASI cannot change the host's). Base's
# `EnvDict` API is kept: `getenv`, `setenv` and `unsetenv` are these functions
# (`RUNTIME_CCALLS`), and iterating `ENV` is patched (`trim/wasm-env.jl`). Wasm only.
# The initial snapshot supports at most 1 MiB of NUL-terminated name=value bytes and
# 1 MiB of wasm32 pointers (262144 entries). Oversize snapshots throw ArgumentError
# before environ_get; nothing is truncated or published. Later snapshot mutations
# use Julia storage and do not consume these staging allocations.

module Env

using ..Runtime: Staging, wasi_check

environ_sizes_get(count::UInt32, size::UInt32) =
    ccall((:environ_sizes_get, "wasi_snapshot_preview1"), Int32, (UInt32, UInt32), count, size)
environ_get(environ::UInt32, buf::UInt32) =
    ccall((:environ_get, "wasi_snapshot_preview1"), Int32, (UInt32, UInt32), environ, buf)

"An entry of the environment: its name, its value, and the whole `name=value` string."
struct Entry
    name::String
    value::String
    raw::String
end

"The environment, in the host's order (then in the order of `setenv`)."
const ENTRIES = Entry[]
const LOADED = Ref(false)

# the NUL-terminated string at `off`
function cstring_at(off::UInt32)
    n = 0
    while Staging.load8(off + UInt32(n)) != 0x00
        n += 1
    end
    b = Vector{UInt8}(undef, n)
    Staging.copy_from_linear!(b, 1, off, n)
    return String(b)
end

function entry(raw::String)
    i = findfirst(==(UInt8('=')), codeunits(raw))
    # (an entry without `=`: no name; iterating ENV warns of it, as natively)
    i === nothing && return Entry("", "", raw)
    return Entry(String(codeunits(raw)[1:i-1]), String(codeunits(raw)[i+1:end]), raw)
end

"Maximum bytes in each staging allocation of the initial environment snapshot."
const MAX_BYTES = Staging.CHUNK

# Widen before multiplying: count is an untrusted wasm32 host result.
function snapshot_size(count::UInt32, size::UInt32)
    ptr_bytes = UInt64(count) * UInt64(4)
    ptr_bytes <= MAX_BYTES || throw(ArgumentError("WASI environment pointer table exceeds 1 MiB (262144 entries)"))
    size <= MAX_BYTES || throw(ArgumentError("WASI environment strings exceed 1 MiB (including NUL terminators)"))
    return Int(ptr_bytes)
end

"The entries, read on first use; host/size errors leave the snapshot unloaded for retry."
function entries()
    LOADED[] && return ENTRIES
    read = Staging.with_scope() do
        wasi_check(environ_sizes_get(Staging.SCRATCH_OUT, Staging.SCRATCH_OUT + UInt32(4)), "environ_sizes_get")
        count = Staging.load32(Staging.SCRATCH_OUT)
        size = Staging.load32(Staging.SCRATCH_OUT + UInt32(4))
        ptr_bytes = snapshot_size(count, size)
        # (an empty environment: nothing to read, and some hosts refuse buffers of no bytes)
        count == 0 && return Entry[]
        ptrs = Staging.alloc_data(ptr_bytes; align=4)
        buf = Staging.alloc_data(size; align=1)
        wasi_check(environ_get(ptrs, buf), "environ_get")
        return Entry[entry(cstring_at(Staging.load32(ptrs + UInt32(4i)))) for i in 0:Int(count)-1]
    end
    # (published only once complete)
    append!(ENTRIES, read)
    LOADED[] = true
    return ENTRIES
end

function find(name::String)
    es = entries()
    for i in eachindex(es)
        es[i].name == name && return i
    end
    return 0
end

"The value of `name`, or `nothing`."
function get(name::String)
    i = find(name)
    return i == 0 ? nothing : entries()[i].value
end

set_errno(e) = ccall(:jl_set_errno, Cvoid, (Cint,), Cint(e))
valid_name(name::String) = !isempty(name) && !occursin('=', name)

"""
`getenv(name)`: as glibc's, the rest of the first entry starting with `name=` (a name with
`=` may match inside a value: `A=a` finds `b` in `A=a=b`), a pointer to a string the snapshot
keeps; C_NULL if none, or for an empty name.
"""
function getenv(name::Cstring)
    n = unsafe_string(name)
    isempty(n) && return Cstring(C_NULL)
    prefix = n * "="
    for e in entries()
        if startswith(e.raw, prefix)
            # (the pointer keeps its string alive: pointers carry the object they point into)
            v = e.name == n ? e.value : String(SubString(e.raw, ncodeunits(prefix) + 1))
            return Base.unsafe_convert(Cstring, v)
        end
    end
    return Cstring(C_NULL)
end

"`setenv(name, value, overwrite)`: 0, or -1 (EINVAL) for an empty name or one with `=`."
function setenv(name::Cstring, value::Cstring, overwrite::Int32)
    n = unsafe_string(name)
    valid_name(n) || (set_errno(22); return Int32(-1))
    v = unsafe_string(value)
    i = find(n)
    if i == 0
        push!(entries(), Entry(n, v, string(n, "=", v)))
    elseif overwrite != 0
        entries()[i] = Entry(n, v, string(n, "=", v))
    end
    return Int32(0)
end

"`unsetenv(name)`: 0, or -1 (EINVAL) for an empty name or one with `=`."
function unsetenv(name::Cstring)
    n = unsafe_string(name)
    valid_name(n) || (set_errno(22); return Int32(-1))
    i = find(n)
    i == 0 || deleteat!(entries(), i)
    return Int32(0)
end

"""
    env_entry(i) -> String or nothing

The `i`-th entry (from 0) of the environment as `environ` has it (`name=value`), or nothing
after the last: a twin (natively, the process's `environ`).
"""
@noinline function env_entry(i::Int)
    envs = Base._environ()
    envp = unsafe_load(envs, i + 1)
    return envp == C_NULL ? nothing : unsafe_string(envp)
end
function env_entry_wasm(i::Int)
    es = entries()
    return i < length(es) ? es[i+1].raw : nothing
end

end # Env

WASM_IMPLS[Env.env_entry] = Env.env_entry_wasm
