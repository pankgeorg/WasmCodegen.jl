# The hash of a symbol, as Julia's C runtime computes it when it creates the symbol
# (`hash_symbol` in src/symbol.c): MurmurHash3_x64_128 of the name, mixed with `int64hash`.
# `objectid(::Symbol)` is this hash, and `hash(::Symbol)` is computed from it, so a Dict
# with symbol keys built at compile time is found at run time. Symbols serialized into the
# module carry the hash computed natively; this computes it for symbols made at run time.

rotl64(x::UInt64, r::Int) = (x << r) | (x >> (64 - r))

function fmix64(k::UInt64)
    k ⊻= k >> 33
    k *= 0xff51afd7ed558ccd
    k ⊻= k >> 33
    k *= 0xc4ceb9fe1a85ec53
    k ⊻= k >> 33
    return k
end

function int64hash(key::UInt64)
    key = (~key) + (key << 21)
    key = key ⊻ (key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = key ⊻ (key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = key ⊻ (key >> 28)
    key = key + (key << 31)
    return key
end

# the little-endian UInt64 at the byte offsets i:i+7, `at(i)` being the byte at offset i
function load64(at, i::Int)
    w = UInt64(0)
    for j in 7:-1:0
        w = (w << 8) | UInt64(at(i + j))
    end
    return w
end

"""
The second half of MurmurHash3_x64_128 of the `n` bytes `at(0)`, ..., `at(n-1)`: the C
runtime's `memhash_seed`, which `hash(::String)` calls before Julia 1.13.
"""
function murmur3_h2(at, n::Int, seed::UInt32)
    h1 = UInt64(seed)
    h2 = UInt64(seed)
    c1 = 0x87c37b91114253d5
    c2 = 0x4cf5ad432745937f
    nblocks = n ÷ 16
    for b in 0:nblocks-1
        k1 = load64(at, 16b)
        k2 = load64(at, 16b + 8)
        k1 *= c1; k1 = rotl64(k1, 31); k1 *= c2; h1 ⊻= k1
        h1 = rotl64(h1, 27); h1 += h2; h1 = h1 * 5 + 0x52dce729
        k2 *= c2; k2 = rotl64(k2, 33); k2 *= c1; h2 ⊻= k2
        h2 = rotl64(h2, 31); h2 += h1; h2 = h2 * 5 + 0x38495ab5
    end
    tail = 16nblocks
    r = n & 15
    k1 = UInt64(0)
    k2 = UInt64(0)
    if r > 8
        for j in r-1:-1:8
            k2 ⊻= UInt64(at(tail + j)) << (8 * (j - 8))
        end
        k2 *= c2; k2 = rotl64(k2, 33); k2 *= c1; h2 ⊻= k2
    end
    if r > 0
        for j in min(r, 8)-1:-1:0
            k1 ⊻= UInt64(at(tail + j)) << (8 * j)
        end
        k1 *= c1; k1 = rotl64(k1, 31); k1 *= c2; h1 ⊻= k1
    end
    h1 ⊻= UInt64(n)
    h2 ⊻= UInt64(n)
    h1 += h2
    h2 += h1
    h1 = fmix64(h1)
    h2 = fmix64(h2)
    h1 += h2
    h2 += h1
    return h2
end

"Julia's `memhash` of the bytes of `s`."
memhash(s::String, seed::UInt32=0xcafe8881) = murmur3_h2(i -> codeunit(s, i + 1), ncodeunits(s), seed)

"`memhash_seed(buf, n, seed)`, through a pointer."
memhash_seed(p::Ptr{UInt8}, n::UInt64, seed::UInt32) = murmur3_h2(i -> unsafe_load(p, i + 1), Int(n), seed)

"The hash of the symbol named `s` (its `objectid`)."
symbol_hash(s::String) = int64hash(-(memhash(s) ⊻ 0xaaaaaaaaaaaaaaaa))

# `objectid` of an isbits value without padding, as Julia's C runtime computes it
# (`immut_id_` in src/builtins.c): a hash of its bits, mixed with its type's hash (which the
# code generator knows at compile time)

function int32hash(a::UInt32)
    a = (a + 0x7ed55d16) + (a << 12)
    a = (a ⊻ 0xc761c23c) ⊻ (a >> 19)
    a = (a + 0x165667b1) + (a << 5)
    a = (a + 0xd3a2646c) ⊻ (a << 9)
    a = (a + 0xfd7046c5) + (a << 3)
    a = (a ⊻ 0xb55a4f09) ⊻ (a >> 16)
    return a
end

"The hash of the bits of a value of 1, 2, 4 or 8 bytes (`bits_hash`: one byte is read as an
`int8_t`, sign-extended, two as a `uint16_t`)."
bits_hash(x::Int8) = UInt64(int32hash(reinterpret(UInt32, Int32(x))))
bits_hash(x::Int16) = UInt64(int32hash(UInt32(reinterpret(UInt16, x))))
bits_hash(x::Int32) = UInt64(int32hash(reinterpret(UInt32, x)))
bits_hash(x::UInt64) = int64hash(x)

"`bitmix(a, b)`: how `objectid` mixes the ids of a value's fields."
bitmix(a::UInt64, b::UInt64) = int64hash(a ⊻ bswap(b))

"The hash of the bits of a value of another size (`memhash` of its bytes)."
bits_hash(x::NTuple{N,UInt8}) where {N} = murmur3_h2(i -> x[i + 1], N, 0xcafe8881)

"""
    objectid_as(x, T)

`objectid(x)` of `x`, a `T`: the case of `T` of `objectid` of a value whose type is known only
at run time (see `objectid_any_func!`).
"""
@noinline objectid_as(@nospecialize(x), ::Type{T}) where {T} = objectid(x::T)

"""
    dynamic_call_as(f, T, args...)

`f(args...)` for an `f` of type `T`, the case of `T` of a call of a function value of a type
known only at run time. The result in a `RefValue{Any}`, one form for every case.
"""
@noinline dynamic_call_as(@nospecialize(f), ::Type{T}) where {T} = Base.RefValue{Any}((f::T)())
@noinline dynamic_call_as(@nospecialize(f), ::Type{T}, a) where {T} = Base.RefValue{Any}((f::T)(a))
@noinline dynamic_call_as(@nospecialize(f), ::Type{T}, a, b) where {T} = Base.RefValue{Any}((f::T)(a, b))
@noinline dynamic_call_as(@nospecialize(f), ::Type{T}, a, b, c) where {T} = Base.RefValue{Any}((f::T)(a, b, c))
@noinline dynamic_call_as(@nospecialize(f), ::Type{T}, a, b, c, d) where {T} = Base.RefValue{Any}((f::T)(a, b, c, d))
dynamic_call_result(r::Base.RefValue{Any}) = r.x
