# SIMD vectors (`WasmCodegen.SIMD128` on `NTuple{N,VecElement{T}}`) compiled to WebAssembly SIMD128:
# each operation compared with native, where it is the same operation lane by lane. Inputs of
# `muladd` are small integers, so that fused and unfused results are equal.
using WasmCodegen: SIMD128 as S

const D2 = NTuple{2,VecElement{Float64}}
const F4 = NTuple{4,VecElement{Float32}}
const F2 = NTuple{2,VecElement{Float32}}

mkvec(::Type{NTuple{N,VecElement{T}}}, f) where {N,T} = ntuple(i -> VecElement(T(f(i))), Val(N))
lanes(v::NTuple{N,VecElement{T}}) where {N,T} = ntuple(i -> v[i].value, Val(N))
lanetype(::Type{NTuple{N,VecElement{T}}}) where {N,T} = T

# every operation on vectors built from the argument (no cached v128: built at the use)
function ops(::Type{V}, k::Int) where {V}
    a = mkvec(V, i -> k + 2i); b = mkvec(V, i -> 3 - i * k); c = mkvec(V, i -> i)
    s = S.add(a, b); d = S.sub(a, b); m = S.mul(a, c); q = S.div(a, mkvec(V, i -> 2i))
    n = S.neg(d); x = S.abs(n); r = S.sqrt(S.mul(a, a)); f = S.muladd(a, b, c)
    p = S.splat(V, lanetype(V)(k))
    return lanes(s), lanes(d), lanes(m), lanes(q), lanes(n), lanes(x), lanes(r), lanes(f), lanes(p)
end
ops_d2(k::Int) = ops(D2, k)
ops_f4(k::Int) = ops(F4, k)
ops_f2(k::Int) = ops(F2, k)

# a chain of operations (cached v128s), shuffles of one and of two vectors (FFTL's complex
# product: a * w with interleaved re, im)
function cmul(ar::Float64, ai::Float64, wr::Float64, wi::Float64)
    a = (VecElement(ar), VecElement(ai)); w = (VecElement(wr), VecElement(wi))
    t = S.mul(S.shuffle(a, Val((1, 1))), S.shuffle(w, Val((1, 0))))
    re = S.shuffle(a, Val((0, 0)))
    y = S.shuffle(S.muladd(re, w, S.neg(t)), S.muladd(re, w, t), Val((0, 3)))
    return lanes(y)
end
cmul_d2(k::Int) = cmul(Float64(k), 2.0, -3.0, Float64(k + 1))
function shuffles_f4(k::Int)
    a = mkvec(F4, i -> i + k); b = mkvec(F4, i -> -i)
    return lanes(S.shuffle(a, Val((3, 2, 1, 0)))), lanes(S.shuffle(a, b, Val((0, 4, 2, 7)))),
           lanes(S.add(S.shuffle(a, Val((1, 1, 0, 0))), b))
end
function shuffles_f2(k::Int)
    a = mkvec(F2, i -> i + k); b = mkvec(F2, i -> 10i)
    return lanes(S.shuffle(a, Val((1, 0)))), lanes(S.shuffle(a, b, Val((3, 0)))), lanes(S.mul(S.shuffle(a, b, Val((2, 1))), a))
end
# a shuffle must keep the number of lanes (an ArgumentError natively, a trap here)
bad_shuffle(k::Int) = lanes(S.shuffle(mkvec(D2, i -> i + k), Val((0, 1, 0, 1))))

# vectors through pointer arguments (no static origin): fused loads and stores
@noinline function vaxpy!(py::Ptr{T}, px::Ptr{T}, n::Int, a::T, ::Type{V}) where {T,V}
    N = fieldcount(V); av = S.splat(V, a)
    for i in 0:N:n-N
        S.vstore(S.muladd(av, S.vload(V, px + i * sizeof(T)), S.vload(V, py + i * sizeof(T))), py + i * sizeof(T))
    end
end
function axpy(::Type{V}, n::Int, off::Int) where {V}
    T = lanetype(V)
    x = T[i for i in 1:n+4]; y = T[2 - i for i in 1:n+4]
    GC.@preserve x y vaxpy!(pointer(y) + off, pointer(x) + off, n, T(3), V)   # off = 4: misaligned for Float64
    return sum(i * y[i] for i in eachindex(y))
end
axpy_d2(n::Int) = axpy(D2, n, 0)
axpy_d2_misaligned(n::Int) = axpy(D2, n, 4)
axpy_f4(n::Int) = axpy(F4, n, 0)
axpy_f4_misaligned(n::Int) = axpy(F4, n, 2)
axpy_f2(n::Int) = axpy(F2, n, 4)
# ComplexF64 storage as vectors of two Float64s
function complex_scale(n::Int)
    z = [ComplexF64(i, -i) for i in 1:n]
    GC.@preserve z vaxpy!(Ptr{Float64}(pointer(z)), Ptr{Float64}(pointer(z)), 2n, 0.5, D2)
    return real(sum(z)), imag(sum(z))
end
# pointers made in the same function (a static origin): lane by lane
function static_origin(n::Int)
    x = [Float64(i) for i in 1:2n]
    GC.@preserve x begin
        p = pointer(x)
        for i in 0:2:2n-2
            S.vstore(S.add(S.vload(D2, p + 8i), S.splat(D2, 1.0)), p + 8i)
        end
    end
    return sum(x)
end
# a vector carried by a loop (the v128 rebuilt from the carry's lanes)
@noinline function vdot(px::Ptr{Float64}, py::Ptr{Float64}, n::Int)
    acc = S.splat(D2, 0.0)
    for i in 0:2:n-2
        acc = S.muladd(S.vload(D2, px + 8i), S.vload(D2, py + 8i), acc)
    end
    return acc[1].value + acc[2].value
end
dot_d2(n::Int) = (x = [Float64(i) for i in 1:n]; y = [Float64(n - i) for i in 1:n]; GC.@preserve x y vdot(pointer(x), pointer(y), n))

# control flow: definitions selected by a branch, nested merges, a loop that may run zero times,
# try/catch with the vector updated before a throw
function branchy(k::Int)
    a = mkvec(D2, i -> k + i); b = mkvec(D2, i -> 2i - k)
    v = isodd(k) ? S.add(a, b) : S.mul(a, b)
    w = S.sub(v, a)
    if k > 2
        w = k > 4 ? S.muladd(w, b, a) : S.neg(w)
    end
    acc = S.splat(D2, 0.0)
    for i in 1:k-3
        acc = S.add(acc, w)
    end
    return lanes(S.add(acc, w))
end
function vtry(k::Int)
    v = mkvec(F4, i -> i + k)
    try
        v = S.mul(v, v)
        k > 2 && throw(DomainError(k))
        v = S.add(v, v)
    catch
        v = S.sub(v, mkvec(F4, i -> 1))
    end
    return lanes(S.add(v, v))
end
# vectors through an immutable field, the elements of an array, a function that is not inlined
struct Holder
    v::D2
    x::Float64
end
@noinline passvec(v::D2, w::D2) = S.mul(v, w)
function through(k::Int)
    a = S.add(mkvec(D2, i -> i), mkvec(D2, i -> k))
    h = Holder(a, 1.0)
    arr = [a, S.neg(a)]
    r = passvec(h.v, arr[2])
    return lanes(S.add(r, arr[1])), h.x
end

# floating-point edges, as bits (isequal does not tell NaNs apart): signed zeros, signed NaNs
# with payloads, infinities, subnormals through neg, abs, shuffles and loads/stores
ubits(v::NTuple{N,VecElement{T}}) where {N,T} = ntuple(i -> reinterpret(Base.uinttype(T), v[i].value), Val(N))
const ODD_D = (-0.0, reinterpret(Float64, 0xfff8000000000123), Inf, 5.0e-324)
const ODD_F = (-0.0f0, reinterpret(Float32, 0x7fc00123), -Inf32, 1.0f-45)
@noinline function roundtrip!(p::Ptr{T}, ::Type{V}) where {T,V}
    S.vstore(S.shuffle(S.vload(V, p), Val(ntuple(i -> fieldcount(V) - i, fieldcount(V)))), p)
end
function edges_d2(k::Int)
    a = (VecElement(ODD_D[mod1(k, 4)]), VecElement(ODD_D[mod1(k + 1, 4)]))
    x = [ODD_D...]
    GC.@preserve x roundtrip!(pointer(x), D2)
    s = S.add(a, (VecElement(-Inf), VecElement(5.0e-324)))
    return ubits(S.neg(a)), ubits(S.abs(a)), ubits(S.shuffle(a, Val((1, 0)))),
           ntuple(i -> reinterpret(UInt64, x[i]), 4), isnan.(lanes(s)), lanes(S.sqrt((VecElement(-1.0), VecElement(4.0))))[2]
end
function edges_f4(k::Int)
    a = ntuple(i -> VecElement(ODD_F[mod1(i + k, 4)]), Val(4))
    x = [ODD_F...]
    GC.@preserve x roundtrip!(pointer(x), F4)
    return ubits(S.neg(a)), ubits(S.abs(a)), ubits(S.shuffle(a, Val((3, 1, 2, 0)))), ntuple(i -> reinterpret(UInt32, x[i]), 4),
           isnan(lanes(S.sqrt(mkvec(F4, i -> -i)))[1])
end
# a multiply-add whose fused and unfused results differ (either is a correct `muladd`)
function madd_rounding(k::Int)
    a = 1.0 + 2.0^-30; b = 1.0 - 2.0^-30
    return lanes(S.muladd(S.splat(D2, a), S.splat(D2, b), S.splat(D2, -1.0 * k)))[1]
end

has_inst(f, op) = any(i -> i.op === op, (i for g in wcompile(f, (Int,)).cgm.mod.funcs for i in g.body))

@testset "SIMD128" begin
    for k in (1, 5, -3)
        @wtest ops_d2(k)
        @wtest ops_f4(k)
        @wtest ops_f2(k)
        @wtest cmul_d2(k)
        @wtest shuffles_f4(k)
        @wtest shuffles_f2(k)
    end
    @wtest bad_shuffle(1)
    for n in (8, 13)
        @wtest axpy_d2(n)
        @wtest axpy_d2_misaligned(n)
        @wtest axpy_f4(n)
        @wtest axpy_f4_misaligned(n)
        @wtest axpy_f2(n)
        @wtest complex_scale(n)
        @wtest static_origin(n)
        @wtest dot_d2(n)
    end
    # the instructions: v128 arithmetic, relaxed_madd (a multiply and an add without relaxed SIMD)
    @test has_inst(ops_d2, :f64x2_add) && has_inst(ops_d2, :f64x2_relaxed_madd)
    @test has_inst(ops_f4, :f32x4_mul) && has_inst(shuffles_f4, :i8x16_shuffle)
    @test has_inst(axpy_d2, :f64x2_relaxed_madd)
    for k in (1, 3, 4, 6)
        @wtest branchy(k)
        @wtest vtry(k)
        @wtest through(k)
    end
    for k in 1:4
        @wtest edges_d2(k)
        @wtest edges_f4(k)
    end
    r = wasm_run(wcompile(madd_rounding, (Int,)), "madd_rounding", 1; rettype=Float64)
    @test r == 0.0 || r == -2.0^-60
    # without relaxed SIMD: a multiply and an add, for every shape, in the optimized module
    relaxed(bytes) = any(i -> bytes[i] == 0xfd && bytes[i+2] == 0x02 && bytes[i+1] in (0x85, 0x87), 1:length(bytes)-2)
    @test relaxed(wcompile(ops_d2, (Int,)).bytes) && relaxed(wcompile(ops_f4, (Int,)).bytes)
    for (f, name) in ((ops_d2, "ops_d2"), (ops_f4, "ops_f4"), (ops_f2, "ops_f2"), (axpy_d2, "axpy_d2"))
        c = WasmCodegen.compile(f, (Int,); config=test_config(relaxed_simd=false))
        @test !relaxed(c.bytes)
        @test isequal(wasm_run(c, name, 5; rettype=Base.return_types(f, (Int,))[1]), f(5))
    end
end
