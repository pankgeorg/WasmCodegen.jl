# Typed views: loads and stores of whole 4/8-byte elements through pointers without a static
# origin are one array access, inline, when the owner's array holds elements of that storage
# (made at function entry for pointer arguments, else refreshed when the owner changes); other
# accesses go through the helpers. Every result compared with native.

# a pointer argument (entry view): read, scale, write back
@noinline function scale!(p::Ptr{T}, n::Int, a::T) where {T}
    s = zero(T)
    for i in 1:n
        x = unsafe_load(p, i)
        unsafe_store!(p, a * x + T(i), i)
        s += x
    end
    return s
end
function entry_views(::Type{T}, n::Int) where {T}
    v = T[T(3i + 7) for i in 1:n]
    w = T[T(2i) for i in 1:2n]
    GC.@preserve v w begin
        s = scale!(pointer(v), n, T(2)) + scale!(pointer(w), 2n, T(3))   # two owners, one function
        s += scale!(pointer(v) + sizeof(T), n - 1, T(1))               # moved by arithmetic
    end
    return s, sum(v), sum(w)
end
ev_f64(n::Int) = entry_views(Float64, n)
ev_f32(n::Int) = entry_views(Float32, n)
ev_i64(n::Int) = entry_views(Int64, n)
ev_i32(n::Int) = entry_views(Int32, n)
ev_u32(n::Int) = entry_views(UInt32, n)

# ComplexF64 storage read and written as Float64s
function ev_complex(n::Int)
    z = [ComplexF64(i, 1 - i) for i in 1:n]
    GC.@preserve z (s = scale!(Ptr{Float64}(pointer(z)), 2n, 0.5))
    return s, real(sum(z)), imag(sum(z))
end

# the owner changes from one iteration to the next (a pointer chosen at run time): the view of
# the owner local is refreshed
@noinline function alternate(pa::Ptr{Float64}, pb::Ptr{Float64}, n::Int)
    s = 0.0
    for i in 1:n
        p = isodd(i) ? pa : pb
        s = 2s + unsafe_load(p, i)
        unsafe_store!(p, Float64(i), i)
    end
    return s
end
function owner_changes(n::Int)
    a = [1.0 / i for i in 1:n]; b = [Float64(i * i) for i in 1:n]
    GC.@preserve a b (s = alternate(pointer(a), pointer(b), n))
    return s, sum(a), sum(b)
end

# pointers loaded from an object's fields (not arguments)
mutable struct Bufs
    p::Ptr{Float64}
    q::Ptr{Int32}
    n::Int
end
@noinline function through_fields(b::Bufs)
    s = 0.0
    for i in 1:b.n
        s += unsafe_load(b.p, i) * unsafe_load(b.q, i)
        unsafe_store!(b.q, Int32(i), i)
    end
    return s
end
function fields(n::Int)
    x = [0.5i for i in 1:n]; y = Int32[10 - i for i in 1:n]
    GC.@preserve x y (s = through_fields(Bufs(pointer(x), pointer(y), n)))
    return s, sum(y)
end

# not a view of that storage: Float64 through a memory of Int64, of bytes, a String; misaligned
@noinline sumf64(p::Ptr{Float64}, n::Int) = (s = 0.0; for i in 1:n; s += unsafe_load(p, i); end; s)
function other_storage(n::Int)
    a = Int64[reinterpret(Int64, 0.25i) for i in 1:n]
    b = zeros(UInt8, 8n); for i in 1:n; GC.@preserve b unsafe_store!(Ptr{Float64}(pointer(b)), Float64(i), i); end
    c = [Float64(i) for i in 1:n+1]
    GC.@preserve a b c begin
        return sumf64(Ptr{Float64}(pointer(a)), n), sumf64(Ptr{Float64}(pointer(b)), n),
               sumf64(Ptr{Float64}(pointer(c) + 4), n)       # misaligned: the helpers
    end
end
string_f64(k::Int) = (s = repeat("01234567", k); GC.@preserve s sumf64(Ptr{Float64}(pointer(s)), k))

# a pointer argument without owner (from an integer): making its view does not trap
@noinline maybe_load(p::Ptr{Float64}) = p == C_NULL ? -1.0 : unsafe_load(p)
null_arg(n::Int) = maybe_load(Ptr{Float64}(UInt(0))) + n

@testset "typed views" begin
    @wtest ev_f64(9)
    @wtest ev_f32(9)
    @wtest ev_i64(7)
    @wtest ev_i32(8)
    @wtest ev_u32(5)
    @wtest ev_complex(6)
    @wtest owner_changes(11)
    @wtest fields(7)
    @wtest other_storage(5)
    @wtest string_f64(3)
    @wtest null_arg(4)
    # accesses through views, not helper calls only
    fnames(f) = Set(g.name for g in wcompile(f, (Int,)).cgm.mod.funcs)
    @test "jl_ptr_view_f64" in fnames(ev_f64)
    @test "jl_ptr_view_i32" in fnames(ev_i32)
end
