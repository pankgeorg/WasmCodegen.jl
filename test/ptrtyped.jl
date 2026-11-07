# Loads and stores of 4 and 8 bytes through pointers with no static origin (jl_ptr_load_bits4/8,
# jl_ptr_store_bits4/8): one array access when the bytes are an aligned element of the owner's
# array, byte by byte otherwise (misaligned, an owner of bytes, an object's fields). And the
# runtime's memcmp, memmove and memset, which go by 8-byte words when aligned.

# (no static origin: the pointer is an argument of a function that is not inlined)
@noinline ld(p::Ptr{T}, i::Int) where {T} = unsafe_load(p, i)
@noinline st(p::Ptr{T}, x::T, i::Int) where {T} = (unsafe_store!(p, x, i); nothing)
@noinline ldoff(::Type{T}, p::Ptr{UInt8}, o::Int) where {T} = unsafe_load(Ptr{T}(p + o))
@noinline stoff(p::Ptr{UInt8}, o::Int, x::T) where {T} = (unsafe_store!(Ptr{T}(p + o), x); nothing)

# a memory of 8-byte elements: every element read, then written, then read back
function f64_rw(n::Int)
    a = [sin(0.37i) for i in 1:n]
    s = 0.0
    GC.@preserve a begin
        p = pointer(a)
        for i in 1:n; s += i * ld(p, i); end
        for i in 1:n; st(p, ld(p, i) * 2.0 + i, i); end
        for i in 1:n; s += ld(p, i); end
    end
    return s
end
function i32_rw(n::Int)
    a = Int32[i * 7 - 50 for i in 1:n]
    s = 0
    GC.@preserve a begin
        p = pointer(a)
        for i in 1:n; st(p, ld(p, i) * Int32(3), i); end
        for i in 1:n; s = 31s + ld(p, i); end
    end
    return s
end
function f32_rw(n::Int)
    a = Float32[cos(0.1f0 * i) for i in 1:n]
    s = 0.0
    GC.@preserve a begin
        p = pointer(a)
        for i in 1:n; st(p, ld(p, i) + 1.0f0, i); end
        for i in 1:n; s += i * ld(p, i); end
    end
    return s
end
# a memory of ComplexF64 read as Float64s (re, im, re, im, ...), and written
function c64_as_f64(n::Int)
    a = [ComplexF64(i, -2i) for i in 1:n]
    s = 0.0
    GC.@preserve a begin
        p = Ptr{Float64}(pointer(a))
        for i in 1:2n; s = 3s + ld(p, i); end
        for i in 1:2n; st(p, ld(p, i) + 0.5, i); end
    end
    return s + real(sum(a)) + imag(sum(a))
end
# reinterpreted: Float64 loads from a memory of Int64, UInt32 stores into a memory of Float32
function reinterpret_rw(n::Int)
    a = Int64[reinterpret(Int64, 1.5 * i) for i in 1:n]
    b = Float32[i for i in 1:n]
    s = 0.0
    GC.@preserve a b begin
        for i in 1:n; s += ld(Ptr{Float64}(pointer(a)), i); end
        for i in 1:n; st(Ptr{UInt32}(pointer(b)), reinterpret(UInt32, 0.25f0 * i), i); end
    end
    return s + sum(b)
end
# misaligned 8-byte and 4-byte accesses into a memory of Float64 (byte by byte), and into bytes
function misaligned(o::Int)
    a = [1.0 + i / 7 for i in 1:8]
    b = UInt8[i * 13 % 256 for i in 1:64]
    GC.@preserve a b begin
        pa = Ptr{UInt8}(pointer(a)); pb = pointer(b)
        x = ldoff(UInt64, pa, o) ⊻ ldoff(UInt32, pa, o + 1) ⊻ ldoff(UInt64, pb, o) ⊻ ldoff(UInt32, pb, o + 3)
        stoff(pa, o, 0x0102030405060708); stoff(pb, o + 1, 0xa1b2c3d4)
        return x, sum(i * a[i] for i in 1:8), sum(i * Int(b[i]) for i in 1:64)
    end
end
# an object's fields (a Ref of a struct) and a String's bytes
struct Pair2
    x::Float64
    y::Int32
    z::Int32
end
function object_rw(k::Int)
    r = Ref(Pair2(2.5 * k, Int32(k), Int32(-k)))
    GC.@preserve r begin
        p = Ptr{UInt8}(pointer_from_objref(r))
        x = ldoff(Float64, p, 0) + ldoff(Int32, p, 8) + ldoff(Int32, p, 12)
        stoff(p, 0, 0.125); stoff(p, 12, Int32(77))
    end
    return x, r[]
end
function string_words(k::Int)
    s = repeat("abcdefgh", k)
    GC.@preserve s begin
        p = pointer(s)
        return sum(ldoff(UInt64, p, 8j) for j in 0:k-1) + ldoff(UInt32, p, 3)
    end
end

# a memory of inline structs with leaves of mixed sizes (a leaf memory: 4-byte leaf, padding,
# 8-byte leaf): the whole 8-byte leaf, a 4-byte access within it, and an 8-byte access over the
# small leaf and the padding (the padding's bytes are masked off: natively unspecified)
struct Mix
    a::UInt32
    b::UInt64
end
function mixed_leaves(n::Int)
    v = [Mix(UInt32(0x11223344 + i), 0x0102030405060708 * UInt64(i)) for i in 1:n]
    s = UInt64(0)
    GC.@preserve v begin
        p = Ptr{UInt8}(pointer(v))
        for i in 0:n-1
            o = 16i
            s = 3s + ldoff(UInt64, p, o + 8) + ldoff(UInt32, p, o + 12) + (ldoff(UInt64, p, o) & 0xffffffff)
            stoff(p, o + 8, 0xa0a0a0a0a0a0a0a0 + UInt64(i))
            stoff(p, o, UInt32(i))
        end
    end
    return s, sum(x.a for x in v), sum(x.b for x in v)
end
# an object's fields: an 8-byte load and store at offset 4, over two fields
function object_span(k::Int)
    r = Ref(Pair2(1.5 * k, Int32(k), Int32(7)))
    GC.@preserve r begin
        p = Ptr{UInt8}(pointer_from_objref(r))
        x = ldoff(UInt64, p, 4)
        stoff(p, 4, 0x0102030405060708)
    end
    return x, r[]
end
# 8-byte stores and loads over two 4-byte elements (aligned to 8 and not)
function across_elements(o::Int)
    a = Int32[i for i in 1:8]
    GC.@preserve a begin
        p = Ptr{UInt8}(pointer(a))
        x = ldoff(UInt64, p, o)
        stoff(p, o, 0x1111111122222222)
    end
    return x, sum(i * a[i] for i in 1:8)
end

# memcmp (== of vectors of isbits), memmove and memset (unsafe_copyto!, fill!) through pointers
@noinline cmpbytes(p::Ptr{UInt8}, q::Ptr{UInt8}, n::Int) =
    ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), p, q, n)
@noinline movebytes(p::Ptr{UInt8}, q::Ptr{UInt8}, n::Int) =
    (ccall(:memmove, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), p, q, n); nothing)
@noinline setbytes(p::Ptr{UInt8}, b::UInt8, n::Int) =
    (ccall(:memset, Ptr{Cvoid}, (Ptr{UInt8}, Cint, Csize_t), p, b, n); nothing)
function memops(oa::Int, ob::Int, n::Int)
    a = Int64[i * 0x0101010101 for i in 1:16]
    b = copy(a)
    GC.@preserve a b begin
        pa = Ptr{UInt8}(pointer(a)); pb = Ptr{UInt8}(pointer(b))
        c1 = sign(cmpbytes(pa + oa, pb + oa, n))         # equal
        unsafe_store!(pb + oa + n ÷ 2, 0xff)
        c2 = sign(cmpbytes(pa + oa, pb + oa, n))         # differs at n ÷ 2
        c3 = sign(cmpbytes(pa + oa, pb + ob, n))
        movebytes(pa + oa, pa + ob, n)                    # overlapping, both directions
        movebytes(pb + ob, pb + oa, n)
        setbytes(pb + oa, 0x5c, n ÷ 2)
    end
    return c1, c2, c3, sum(i * a[i] for i in 1:16), sum(i * b[i] for i in 1:16)
end
no_owner_load(i::Int) = ld(Ptr{Float64}(UInt(64i)), 1)
refs_load(i::Int) = (v = Any[1.0, "x"]; GC.@preserve v ld(Ptr{Float64}(pointer(v)), i))
out_of_range_load(i::Int) = (v = [1.0, 2.0]; GC.@preserve v ld(pointer(v), i))
vec_eq(n::Int, k::Int) = (a = collect(1:n); b = collect(1:n); k > 0 && (b[k] = 0); a == b)

@testset "typed pointer loads and stores" begin
    @wtest f64_rw(9)
    @wtest i32_rw(11)
    @wtest f32_rw(10)
    @wtest c64_as_f64(5)
    @wtest reinterpret_rw(6)
    for o in (0, 1, 3, 4, 7, 8)
        @wtest misaligned(o)
    end
    @wtest object_rw(3)
    @wtest string_words(4)
    for (oa, ob, n) in ((0, 0, 64), (0, 8, 40), (8, 0, 41), (3, 3, 29), (0, 5, 17), (16, 8, 1), (8, 8, 0))
        @wtest memops(oa, ob, n)
    end
    @wtest vec_eq(100, 0)
    @wtest vec_eq(100, 77)
    @wtest vec_eq(3, 2)
    @wtest mixed_leaves(4)
    @wtest object_span(3)
    @wtest across_elements(0)
    @wtest across_elements(4)
    # the functions doing the accesses call the typed helpers, and no byte helper themselves
    function calls_of(f, name)
        c = wcompile(f, (Int,))
        Set(i.imm[1].name for (mi, info) in c.cgm.funcs if mi.def isa Method && mi.def.name === name
            for i in info.func.body if i.op === :call)
    end
    @test "jl_ptr_load_bits8" in calls_of(f64_rw, :ld) && !("jl_ptr_load_byte" in calls_of(f64_rw, :ld))
    @test "jl_ptr_store_bits8" in calls_of(f64_rw, :st) && !("jl_ptr_store_byte" in calls_of(f64_rw, :st))
    @test "jl_ptr_load_bits4" in calls_of(i32_rw, :ld) && "jl_ptr_store_bits4" in calls_of(i32_rw, :st)
    # traps (natively undefined: not run natively): a pointer without owner, a memory of
    # references, an access out of the owner's range
    trap(f, args...) = (r = wasm_run(wcompile(f, map(typeof, args)), string(nameof(f)), args...; rettype=Float64);
                        r isa Tuple && r[1] === :trap)
    @test trap(no_owner_load, 1)
    @test trap(refs_load, 1)
    @test trap(out_of_range_load, 100)
end
