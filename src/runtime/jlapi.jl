# Functions of Julia's C runtime (libjulia) that Base calls and that are computations, or
# constants of a program of one thread and one task, done here as natively (see
# `foreigncall.jl`'s `RUNTIME_CCALLS`).

## CRC-32C (`Base._crc32c`, `CRC32c.crc32c`; Pkg's package slugs): src/crc32c.c

const CRC32C_TABLE = let t = Vector{UInt32}(undef, 256)
    for i in 0:255
        c = UInt32(i)
        for _ in 1:8
            c = c & 1 != 0 ? (c >> 1) ⊻ 0x82f63b78 : c >> 1
        end
        t[i+1] = c
    end
    t
end

"`jl_crc32c(crc, p, n)`: the CRC-32C (Castagnoli) of the `n` bytes at `p`, continuing `crc`."
function crc32c(crc::UInt32, p::Ptr{UInt8}, n::UInt)
    c = ~crc
    i = UInt(1)
    while i <= n
        c = CRC32C_TABLE[((c ⊻ unsafe_load(p, i)) & 0xff) + 1] ⊻ (c >> 8)
        i += 1
    end
    return ~c
end
crc32c(crc::UInt32, p::Ptr, n::UInt) = crc32c(crc, convert(Ptr{UInt8}, p), n)

## IdSet (`Base.IdSet`): src/idset.c over src/smallintset.c

"""
The C runtime's `jl_idset_*`: an `IdSet`'s keys are a `Memory{Any}` filled from the front (a
deleted key leaves a hole), and its index a hash table of small integers (`idxs`: a
`Memory{UInt8}`, `{UInt16}` or `{UInt32}`) holding key positions + 1, 0 for an empty slot and
all ones for a deleted one, by open addressing on the key's `objectid` and `===`. As natively,
so that an `IdSet` built at compile time (with the native `objectid`s of the image's
objects) is found at run time and iterates in the same order.
"""
module IdSets

import ..EqTables: unset!

const HT_N_INLINE = 32
max_probe(sz::Int) = sz <= 1024 ? 16 : sz >> 6
h2index(hv::UInt, sz::Int) = (hv & (sz - 1)) % Int

# `jl_intref`: the value of slot `i` (0-based), a deleted one as empty (0)
intref(a::Memory{T}, i::Int) where {T} = (v = a[i+1]; v == typemax(T) ? 0 : Int(v))
# `jl_intref_acquire`: a deleted one as -1
intref_acquire(a::Memory{T}, i::Int) where {T} = (v = a[i+1]; v == typemax(T) ? -1 : Int(v))
max_int(::Memory{T}) where {T} = Int(typemax(T))

function alloc_int(np::Int, len::Int)
    np < 0xff && return fill!(Memory{UInt8}(undef, len), 0x00)
    np < 0xffff && return fill!(Memory{UInt16}(undef, len), 0x0000)
    return fill!(Memory{UInt32}(undef, len), 0x00000000)
end

# `idset_hash`: the objectid of the key at position `idx` (0-based), 0 for none
function key_hash(idx::Int, keys::Memory{Any})
    idx < length(keys) && isassigned(keys, idx + 1) || return UInt(0)
    return objectid(keys[idx+1])
end

function lookup(idxs::Memory{T}, keys::Memory{Any}, @nospecialize(key), hv::UInt, pop::Bool) where {T}
    sz = length(idxs)
    sz == 0 && return -1
    maxprobe = max_probe(sz)
    index = h2index(hv, sz)
    orig = index
    iter = 0
    while true
        val1 = intref_acquire(idxs, index)
        val1 == 0 && return -1
        if val1 != -1 && val1 - 1 < length(keys) && isassigned(keys, val1) && keys[val1] === key
            pop && (idxs[index+1] = typemax(T))
            return val1 - 1
        end
        index = (index + 1) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return -1
    end
end

# `smallintset_insert_`: whether `val1` found an empty slot
function insert_slot!(a::Memory{T}, hv::UInt, val1::Int) where {T}
    sz = length(a)
    sz <= 1 && return false
    index = h2index(hv, sz)
    orig = index
    maxprobe = max_probe(sz)
    iter = 0
    while true
        if intref(a, index) == 0
            a[index+1] = val1 % T
            return true
        end
        index = (index + 1) & (sz - 1)
        iter += 1
        (iter <= maxprobe && index != orig) || return false
    end
end

function rehash(a::Memory, keys::Memory{Any}, newsz::Int, np::Int)
    sz = length(a)
    for i in 0:sz-1
        np = max(np, intref(a, i))
    end
    while true
        newa = alloc_int(np + 1, newsz)
        ok = true
        for i in 0:sz-1
            val1 = intref(a, i)
            if val1 != 0 && !insert_slot!(newa, key_hash(val1 - 1, keys), val1)
                ok = false
                break
            end
        end
        ok && return newa
        newsz <<= 1
    end
end

# `jl_smallintset_insert`: the table with position `val` added (a new one when it grows)
function insert(a::Memory, keys::Memory{Any}, val::Int)
    if val + 1 >= max_int(a)
        a = rehash(a, keys, length(a), val + 1)
    end
    while true
        insert_slot!(a, key_hash(val, keys), val + 1) && return a
        sz = length(a)
        newsz = sz < HT_N_INLINE ? HT_N_INLINE :
                sz >= (1 << 19) || sz <= (1 << 8) ? sz << 1 : sz << 2
        a = rehash(a, keys, newsz, 0)
    end
end

# the index table of the `Union` field `idxs` as one of its types (`f(idxs::Memory{T})`)
@inline function with_idxs(f, idxs)
    idxs isa Memory{UInt8} && return f(idxs)
    idxs isa Memory{UInt16} && return f(idxs)
    return f(idxs::Memory{UInt32})
end

# the C functions, as `ccall`s pass their arguments (`Any`s; positions are 0-based)
# (by the index's width, without a closure capturing `key`: inference may specialize one on
# the key's type, which is not known)
function lookup_any(idxs, keys::Memory{Any}, @nospecialize(key), pop::Bool)
    hv = objectid(key)
    idxs isa Memory{UInt8} && return lookup(idxs, keys, key, hv, pop)
    idxs isa Memory{UInt16} && return lookup(idxs, keys, key, hv, pop)
    return lookup(idxs::Memory{UInt32}, keys, key, hv, pop)
end

peek_bp(keys, idxs, @nospecialize(key)) = lookup_any(idxs, keys::Memory{Any}, key, false)

function pop(keys, idxs, @nospecialize(key))
    k = keys::Memory{Any}
    idx = lookup_any(idxs, k, key, true)
    idx != -1 && unset!(k, idx + 1)
    return idx
end

# `idset_compact`: the keys moved to the front; their number, negated if any moved
function compact!(keys::Memory{Any})
    moved = false
    j = 0
    for i in 0:length(keys)-1
        if isassigned(keys, i + 1)
            if i != j
                moved = true
                keys[j+1] = keys[i+1]
                unset!(keys, i + 1)
            end
            j += 1
        end
    end
    return moved ? -j : j
end

function put_key(keys, @nospecialize(key), newidx::Ptr{Int})
    k = keys::Memory{Any}
    l = length(k)
    i = l
    while i > 0 && !isassigned(k, i)
        i -= 1
    end
    unsafe_store!(newidx, i)
    if i == l
        i = compact!(k)
        if i < 0
            unsafe_store!(newidx, i - 1)
            i = -i
        end
        if i >= l ÷ 3 * 2
            nl = l < 4 ? 4 : (l * 3) >> 1
            nk = Memory{Any}(undef, nl)
            for j in 1:i
                nk[j] = k[j]
            end
            k = nk
        end
    end
    k[i+1] = key
    return k
end

function put_idx(keys, idxs, idx::Int)
    k = keys::Memory{Any}
    if idx < 0
        # a full rehash, after the keys were compacted
        with_idxs(t -> fill!(t, zero(eltype(t))), idxs)
        new = idxs
        for i in 0:-idx-1
            isassigned(k, i + 1) && (new = insert(new::Memory, k, i))
        end
        return new
    end
    return insert(idxs::Memory, k, idx)
end

end

## gensym (`gensym()`, `gensym(tag)`): src/ast.c (`##` and a counter, `##tag#` and it)

"""
The counter of gensyms (`gs_ctr` in src/symbol.c): the module's starts at the build process's
next value as of the end of the compilation (`finish_gensym_counter!` sets it in the image after
everything the compilation generated, inference included), so the module's gensyms continue
the sequence and never repeat a generated symbol the image holds.
"""
const GENSYM_COUNTER = Ref{UInt32}(0)

"The build process's next gensym number (natively; it takes one)."
native_gensym_counter() = parse(UInt32, String(Base.gensym())[3:end]) + 0x1
"Set `GENSYM_COUNTER` (natively) to the build process's next gensym number."
sync_gensym_counter!() = (GENSYM_COUNTER[] = native_gensym_counter(); nothing)

next_gensym() = (c = GENSYM_COUNTER[]; GENSYM_COUNTER[] = c + 0x1; c)

"`jl_gensym()`: the symbol `##n`, `n` the counter's value (then incremented)."
gensym() = Symbol("##", next_gensym())

"""
`jl_tagged_gensym(p, n)`: the symbol `##tag#n` of the tag of the `n` bytes at `p` (`n` all
ones: of the bytes before a NUL).
"""
function tagged_gensym(p::Ptr{UInt8}, n::UInt)
    tag = n == typemax(UInt) ? unsafe_string(p, ptr_strlen(p)) : unsafe_string(p, n)
    occursin('\0', tag) && throw(ArgumentError("Symbol name may not contain \\0"))
    return Symbol("##", tag, "#", next_gensym())
end

## Libc.rand / Libc.srand: src/sys.c (`cong` on a global seed)

# (seeded from the host's entropy when the module starts, `seed_from_host!`)
const RAND_SEED = Ref{UInt64}(0)

"`jl_srand(seed)`."
srand(seed::UInt64) = (RAND_SEED[] = seed; nothing)

"""
`jl_rand()`: the C runtime's `cong(UINT64_MAX, &seed)` (src/julia_internal.h): steps of a
linear congruential generator until one is below the bound.
"""
function rand()
    while true
        seed = RAND_SEED[] * 69069 + 362437
        RAND_SEED[] = seed
        seed < typemax(UInt64) && return seed
    end
end

## the GC (WasmGC's: it collects on its own, and finalizers never run)

const GC_LOGGING = Ref{Cint}(0)

"`jl_enable_gc_logging(on)`: kept as a flag (nothing is logged: WasmGC reports no collections)."
enable_gc_logging(on::Cint) = (GC_LOGGING[] = on != 0 ? Cint(1) : Cint(0); nothing)
is_gc_logging_enabled() = GC_LOGGING[]

"The GC's requested state (`jl_gc_enable`), kept as natively: WasmGC collects regardless."
const GC_ENABLED = Ref{Int32}(1)
"`jl_gc_enable(on)`: enabled if `on` is not 0; the previous state (1 enabled, 0 not)."
gc_enable(on::Int32) = (prev = GC_ENABLED[]; GC_ENABLED[] = on != 0 ? Int32(1) : Int32(0); prev)

## the scheduler's per-thread random state (`Base.Partr.get_ptls_rng`/`set_ptls_rng`): the one
## thread's (src/threading.c)

# (seeded from the host's entropy when the module starts, `seed_from_host!`)
const PTLS_RNG = Ref{UInt64}(0)
get_ptls_rng() = PTLS_RNG[]
set_ptls_rng(seed::UInt64) = (PTLS_RNG[] = seed; nothing)

"`jl_set_nth_field(x, i, v)` with `i` out of range: a BoundsError of `i + 1`, as natively."
@noinline throw_nth_field_bounds(@nospecialize(x), i::UInt) = throw(BoundsError(x, (i % Int) + 1))

# `jl_gc_new_weakref_th(ptls, x)`: a WeakRef holding `x` (strongly: a GC never has to run)
@eval new_weakref(::Ptr{Cvoid}, @nospecialize(x)) = $(Expr(:new, WeakRef, :x))

"`jl_gc_get_total_bytes(p)`: no statistics of the heap (WasmGC has none): 0."
gc_get_total_bytes(p::Ptr{Int64}) = (unsafe_store!(p, Int64(0)); nothing)

"`jl_gc_num()`: `Base.GC_Num` of zeros (`@time` and `@timed` report no allocations)."
const GC_NUM_ZERO = Base.GC_Num((zero(fieldtype(Base.GC_Num, i)) for i in 1:fieldcount(Base.GC_Num))...)
gc_num() = GC_NUM_ZERO

"`jl_set_fenv_rounding(i)`: to nearest (0, success); another mode throws."
function set_fenv_rounding(i::Int32)
    i == Base.Rounding.JL_FE_TONEAREST && return Int32(0)
    throw(ArgumentError("setrounding of Float32/Float64 to a mode other than RoundNearest: " *
                        "Wasm's floating-point operations only round to nearest (WasmCodegen)"))
end

"`jl_set_zero_subnormals(yes)`: keeping subnormals succeeds (0); flushing them is unsupported."
set_zero_subnormals(yes::Int8) = yes == 0 ? Int32(0) : Int32(1)

## the C runtime's global variables code reads (`cglobal`), as the module has them

"`jl_n_threads`: one thread (`Threads.maxthreadid`)."
const N_THREADS = Ref{Cint}(1)
"`jl_n_threadpools`: the interactive pool (empty) and the default one, as natively with `-t 1`."
const N_THREADPOOLS = Ref{Cint}(2)
"`jl_n_gcthreads`: no GC threads besides the one thread (`Threads.ngcthreads() == 1`)."
const N_GCTHREADS = Ref{Cint}(0)

## C structs Base reads through pointers (`cglobal`s of non-scalars), as functions with a
## native twin (see `twins.jl`): natively, in the build process, they read the C runtime's;
## compiled, they are the module's constants. The trim patch `wasm-runtime.jl` makes Base
## call them.

"""
The options of the process that builds the module (`Base.JLOptions()`), without strings or
arrays (null pointer fields: the build's paths are not the program's) and with one thread:
set when the trim patches are applied, serialized into the module.
"""
const BUILD_JLOPTIONS = Ref{Base.JLOptions}()

"`Base.JLOptions()`: natively the process's options."
@noinline jl_options() = unsafe_load(cglobal(:jl_options, Base.JLOptions))
@noinline jl_options_wasm() = BUILD_JLOPTIONS[]
WASM_IMPLS[jl_options] = jl_options_wasm

"The build process's options, sanitized as `BUILD_JLOPTIONS` holds them."
function sanitized_jloptions()
    opts = jl_options()
    fields = Any[]
    for (name, T) in zip(fieldnames(Base.JLOptions), fieldtypes(Base.JLOptions))
        v = getfield(opts, name)
        push!(fields, T <: Ptr ? T(0) : name === :nthreads ? T(1) : name === :nthreadpools ? T(2) : v)
    end
    return Base.JLOptions(fields...)
end

"""
`Threads._nthreads_in_pool(tpid)` (`jl_n_threads_per_pool[tpid]`): natively the process's;
compiled, as natively with `-t 1`: the interactive pool (0) empty, the default one (1) the one
thread.
"""
@noinline function nthreads_in_pool(tpid::Int8)
    p = unsafe_load(cglobal(:jl_n_threads_per_pool, Ptr{Cint}))
    return Int(unsafe_load(p, tpid + 1))
end
@noinline nthreads_in_pool_wasm(tpid::Int8) = tpid == 1 ? 1 : 0
WASM_IMPLS[nthreads_in_pool] = nthreads_in_pool_wasm
