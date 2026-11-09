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

# views whose first access runs on one path only, refreshed on one path, in try/catch, with
# several owners, two storages through one owner, a reassigned pointer argument
mutable struct Two
    p::Ptr{Float64}
    q::Ptr{Float64}
end
@noinline function path_first(b::Two, k::Int)
    p = k > 0 ? b.p : b.q
    s = 0.0
    if isodd(k)
        s += unsafe_load(p, 1)           # the first access, on one arm only
    else
        unsafe_store!(p, 2.5, 2)
    end
    s += unsafe_load(p, 3)               # after the join
    for i in 1:4
        i == 2 && continue               # an iteration without access
        s += unsafe_load(p, i)
        isodd(i + k) && (p = b.q)        # the owner changes on one path
    end
    return s + unsafe_load(p, 4)
end
@noinline function in_try(b::Two, k::Int)
    s = 0.0
    p = b.p
    try
        s += unsafe_load(p, 1)
        k > 2 && error("k")
        p = b.q
        s += unsafe_load(p, 2)
    catch
        p = b.q
        s += 10 * unsafe_load(p, 3)
    end
    return s + unsafe_load(p, 1)
end
function paths(k::Int)
    x = [1.0, 2.0, 3.0, 4.0]; y = [10.0, 20.0, 30.0, 40.0]
    GC.@preserve x y begin
        b = Two(pointer(x), pointer(y))
        return path_first(b, k), in_try(b, k), sum(x), sum(y)
    end
end
@noinline function rotate(ps::NTuple{3,Ptr{Float64}}, n::Int)
    s = 0.0
    for i in 1:n
        p = ps[mod1(i, 3)]
        s = 2s + unsafe_load(p, mod1(i, 4))
        unsafe_store!(p, Float64(i), mod1(i + 1, 4))
    end
    return s
end
function three_owners(n::Int)
    a = [1.0, 2.0, 3.0, 4.0]; b = [5.0, 6.0, 7.0, 8.0]; c = [9.0, 10.0, 11.0, 12.0]
    GC.@preserve a b c (s = rotate((pointer(a), pointer(b), pointer(c)), n))
    return s, sum(a), sum(b), sum(c)
end
@noinline function two_storages(p::Ptr{Float64}, n::Int)
    q = Ptr{Int64}(p)                    # the same owner, another storage (no view: the helpers)
    s = 0.0
    for i in 1:n
        s += unsafe_load(p, i) + (unsafe_load(q, i) % 1000)
        unsafe_store!(q, reinterpret(Int64, Float64(i)), i)
    end
    return s
end
two_storage(n::Int) = (v = [0.5i for i in 1:n]; GC.@preserve v (two_storages(pointer(v), n), sum(v)))
@noinline function reassigned(p::Ptr{Float64}, q::Ptr{Float64}, n::Int)
    s = 0.0
    for i in 1:n
        s = 3s + unsafe_load(p, i)
        p = q                            # a new value, not the argument's local
    end
    return s
end
reassign(n::Int) = (a = [1.0 * i for i in 1:n]; b = [-2.0 * i for i in 1:n]; GC.@preserve a b reassigned(pointer(a), pointer(b), n))
# an argument never dereferenced: no view made for it
@noinline passthru(p::Ptr{Float64}, n::Int) = p + 8n
untouched(n::Int) = (v = zeros(4); GC.@preserve v Int(passthru(pointer(v), n) - pointer(v)))

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
    for k in (-2, -1, 1, 2, 3, 4)
        @wtest paths(k)
    end
    @wtest three_owners(10)
    @wtest two_storage(6)
    @wtest reassign(5)
    @wtest untouched(3)
    # the accessing function's own code: inline array accesses through the view made at its
    # entry; and no view for an argument that is never dereferenced
    body(f, name) = [i for (mi, info) in wcompile(f, (Int,)).cgm.funcs if mi.def isa Method && mi.def.name === name
                     for i in info.func.body]
    calls(is) = Set(i.imm[1].name for i in is if i.op === :call)
    b = body(ev_f64, :scale!)
    @test any(i -> i.op === :array_get, b) && any(i -> i.op === :array_set, b) && "jl_ptr_view_f64" in calls(b)
    @test "jl_ptr_view_i32" in calls(body(ev_i32, :scale!))
    @test !("jl_ptr_view_f64" in calls(body(untouched, :passthru)))
end
