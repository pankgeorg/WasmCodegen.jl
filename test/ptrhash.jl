# Bytes of strings and byte memories read through pointers without a static origin (in a
# function other than the one that took the pointer: Base's `hash_bytes`, `memcmp`): read
# from the owner's byte array within its bytes, through `jl_ptr_load_byte` otherwise (the NUL
# past a string's end, out of bounds).

const HASH_STRS = ["", "a", "ab", "abc", "abcd", "exactly8", "nine bytes", "sixteen-bytes-ok",
                   "seventeen bytes !", "αβγ", "ünïcödé ✓ 日本語", "a\0b", "\0", "\0\0\0\0\0\0\0\0\0",
                   repeat("xyz", 40), repeat("é", 33)]

function hash_strings(k::Int)
    h = UInt(k)
    for s in HASH_STRS
        h = hash(s, h)
    end
    return h
end

# every length from 0 to n, ASCII and not (the branches of `hash_bytes` by length)
function hash_prefixes(n::Int, multibyte::Bool)
    s = multibyte ? repeat("aé日\0", n) : repeat("abcdefghijklmnopqrstuvwxyz", 2)
    h = UInt(0)
    for m in 0:min(n, ncodeunits(s))
        h = hash(String(codeunits(s)[1:m]), h)
    end
    return h
end

function hash_substrings(k::Int)
    h = UInt(0)
    for s in HASH_STRS, i in 1:k:ncodeunits(s)
        isvalid(s, i) || continue
        h = hash(SubString(s, i), h)
        h = hash(SubString(s, 1, prevind(s, i)), h)
    end
    return h
end

prefix(s::String, k::Int) = SubString(s, 1, thisind(s, min(k, ncodeunits(s))))
function compare_hashed_strings(k::Int)
    r = 0
    for a in HASH_STRS, b in HASH_STRS
        r = 3r + cmp(a, b) + 7 * (a == b) + 11 * (a * "x" == b * "x")
        sa, sb = prefix(a, k), prefix(b, k)
        r = 5r + cmp(sa, sb) + 13 * (sa == sb)
        r %= 1_000_000_007
    end
    return r
end

@noinline load8(p::Ptr{UInt8}, i::Int) = unsafe_load(p, i)
@noinline load64(p::Ptr{UInt8}, i::Int) = unsafe_load(Ptr{UInt64}(p + i - 1))

# the NUL past a string's end, alone and as the last byte of a wider load
function string_nul(k::Int)
    s = "abcdefg"[1:k]
    GC.@preserve s (load8(pointer(s), k + 1), k == 7 ? load64(pointer(s), 1) : UInt64(0))
end
string_past_nul(k::Int) = (s = "abc"[1:k]; GC.@preserve s load8(pointer(s), k + 2))
string_wide_past_nul(k::Int) = (s = "abcdefg"[1:k]; GC.@preserve s load64(pointer(s), 1))
string_before(k::Int) = (s = "abc"[1:k]; GC.@preserve s load8(pointer(s), 0))
# a memory of bytes has no NUL past its end
function memory_bytes(k::Int)
    v = UInt8[(i * 37) % UInt8 for i in 1:k]
    GC.@preserve v (load8(pointer(v), k), load64(pointer(v), 1))
end
memory_past_end(k::Int) = (v = UInt8[1:k;]; GC.@preserve v load8(pointer(v), k + 1))
# a Ref's bytes still go through the owner's fields
ref_word(x::Int) = (r = Ref(x); GC.@preserve r load64(Ptr{UInt8}(pointer_from_objref(r)), 1))
# a Symbol's name of 7 bytes, its NUL, and the 8 bytes ending with it
function symbol_bytes(k::Int)
    s = Symbol("sym", k)
    p = Base.unsafe_convert(Ptr{UInt8}, s)
    (load8(p, 1), load8(p, ncodeunits(string(s)) + 1), load64(p, 1))
end
# bytes stored into the owner between two loads of the same owner are read
@noinline function load_store_load(p::Ptr{UInt8}, v::Vector{UInt8})
    a = unsafe_load(Ptr{UInt64}(p))
    v[3] = 0xee
    return (a, unsafe_load(Ptr{UInt64}(p)), unsafe_load(p, 3))
end
function reload_after_store(k::Int)
    v = UInt8[(i + k) % UInt8 for i in 1:12]
    GC.@preserve v load_store_load(pointer(v), v)
end

# one pointer local whose owner changes between strings, a memory and a Ref
@noinline function alternate(p::Ptr{UInt8}, q::Ptr{UInt8}, n::Int)
    s = UInt64(0)
    for i in 1:n
        s = 31s + unsafe_load(p) + UInt64(i) * unsafe_load(Ptr{UInt64}(p))
        p, q = q + 1, p + 1
    end
    return s
end
function alternate_owners(n::Int)
    a = repeat("abcdefghij", n)
    b = UInt8[(i * 3) % UInt8 for i in 1:10n]
    c = repeat("ü", 5n)
    r = Ref(ntuple(i -> UInt64(i * 0x0101 + n), Val(8)))
    GC.@preserve a b c r begin
        rp = Ptr{UInt8}(pointer_from_objref(r))
        alternate(pointer(a), pointer(b), n) + alternate(pointer(c), pointer(a), n) +
            alternate(rp, pointer(c), n) + alternate(pointer(b), rp, n)
    end
end

@noinline function sum_bytes(p::Ptr{UInt8}, n::Int)
    s = UInt64(0)
    for i in 1:n
        s = 31s + unsafe_load(p, i)
    end
    return s
end
sum_string_bytes(k::Int) = (s = repeat("abc", k); GC.@preserve s sum_bytes(pointer(s), ncodeunits(s)))

# whether the functions compiled for the method `name` with a pointer as first argument read
# bytes through a byte view guarded by the owner's identity
function reads_through_view(c, name::Symbol)
    infos = [info for (mi, info) in c.cgm.funcs
             if mi.def isa Method && mi.def.name === name && mi.specTypes.parameters[2] <: Ptr]
    isempty(infos) && return false
    return all(infos) do info
        body = info.func.body
        any(i -> i.op === :call && i.imm[1].name == "jl_ptr_byte_view", body) &&
            any(i -> i.op === :ref_eq, body) && any(i -> i.op === :array_get_u, body)
    end
end

@testset "pointer bytes through byte views" begin
    calls = [(hash_strings, (0,)), (hash_strings, (12345,)), (hash_prefixes, (40, false)), (hash_prefixes, (12, true)),
             (hash_substrings, (1,)), (hash_substrings, (3,)), (compare_hashed_strings, (2,)),
             (compare_hashed_strings, (100,)), (string_nul, (3,)), (string_nul, (7,)), (string_nul, (0,)),
             (memory_bytes, (9,)), (ref_word, (72623859790382856,)), (symbol_bytes, (4242,)),
             (reload_after_store, (5,)), (alternate_owners, (4,)), (sum_string_bytes, (7,))]
    # each runs natively without throwing, so the comparisons below compare values
    for (f, args) in calls
        @test (f(args...); true)
    end
    @wtest hash_strings(0)
    @wtest hash_strings(12345)
    @wtest hash_prefixes(40, false)
    @wtest hash_prefixes(12, true)
    @wtest hash_substrings(1)
    @wtest hash_substrings(3)
    @wtest compare_hashed_strings(2)
    @wtest compare_hashed_strings(100)
    @wtest string_nul(3)
    @wtest string_nul(7)
    @wtest string_nul(0)
    @wtest memory_bytes(9)
    @wtest ref_word(72623859790382856)
    @wtest symbol_bytes(4242)
    @wtest reload_after_store(5)
    @wtest alternate_owners(4)
    @wtest sum_string_bytes(7)
    for (f, k, T) in ((string_past_nul, 2, UInt8), (string_wide_past_nul, 3, UInt64), (string_before, 3, UInt8),
                      (memory_past_end, 4, UInt8))
        r = wasm_run(wcompile(f, (Int,)), string(nameof(f)), k; rettype=T)
        @test r isa Tuple && r[1] === :trap
    end
    @test reads_through_view(wcompile(sum_string_bytes, (Int,)), :sum_bytes)
    # Base hashes strings with `hash_bytes(::Ptr{UInt8}, ...)` from Julia 1.13
    isdefined(Base, :hash_bytes) && @test reads_through_view(wcompile(hash_strings, (Int,)), :hash_bytes)
end
