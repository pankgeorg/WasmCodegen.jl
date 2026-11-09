add1(x::Int) = x + 1
fmuladd(a::Float64, b::Float64, c::Float64) = a * b + c
function loopsum(n::Int)
    s = 0.0
    for i in 1:n
        s += i
    end
    s
end
function halve(x::Float64)
    while x > 1.0
        x /= 2
    end
    x
end
collatz(n::Int) = (k = 0; while n != 1; n = iseven(n) ? n ÷ 2 : 3n + 1; k += 1; end; k)
sh(x::Int8, y::Int) = (x << y, x >> y, x >>> y)
narrow(x::UInt8, y::UInt8) = x + y
fact(n::Int) = n <= 1 ? 1 : n * fact(n - 1)
tup(x::Float64) = (x, 2x, Int(round(x)))
cmpf(x::Float64, y::Float64) = (x === y, isequal(x, y), x == y)
divs(a::Int, b::Int) = (div(a, b), rem(a, b))

@testset "basics" begin
    @wtest add1(41)
    @wtest fmuladd(1.5, 2.0, 0.25)
    @wtest loopsum(10)
    @wtest halve(1000.0)
    @wtest collatz(27)
    @wtest sh(Int8(-7), 3)
    @wtest sh(Int8(-7), 9)
    @wtest narrow(0xff, 0x02)
    @wtest fact(20)
    @wtest tup(2.6)
    @wtest cmpf(0.0, -0.0)
    @wtest cmpf(NaN, NaN)
    @wtest divs(-7, 2)
    @wtest divs(1, 0)
end

# byte swaps of floats: `bswap`, `hton` and `ntoh` of a Float64 or Float32 are the intrinsic
# `bswap_int` of the float, natively a swap of its bits (in and out by their bits, so that NaN
# payloads are compared too)
bswap_f64(b::UInt64) = (x = reinterpret(Float64, b);
    (reinterpret(UInt64, bswap(x)), reinterpret(UInt64, hton(x)), reinterpret(UInt64, ntoh(x)), reinterpret(UInt64, ntoh(hton(x)))))
bswap_f32(b::UInt32) = (x = reinterpret(Float32, b);
    (reinterpret(UInt32, bswap(x)), reinterpret(UInt32, hton(x)), reinterpret(UInt32, ntoh(x)), reinterpret(UInt32, ntoh(hton(x)))))
# (a swapped float used as a float)
bswap_twice(x::Float64, y::Float32) = (bswap(bswap(x)) + 1.0, bswap(bswap(y)) * 2.0f0)

@testset "byte swaps of floats" begin
    # 1.5, -0.0, a quiet NaN with a payload, a signalling NaN, the smallest subnormal, and one
    # whose swap is a NaN
    for b in (reinterpret(UInt64, 1.5), reinterpret(UInt64, -0.0), 0x7ff8000000000001, 0x7ff0000000000001,
              0x0000000000000001, 0x00000000000ff87f)
        @wtest bswap_f64(b)
    end
    for b in (reinterpret(UInt32, 1.5f0), reinterpret(UInt32, -0.0f0), 0x7fc00001, 0x7f800001, 0x00000001, 0x0000c07f)
        @wtest bswap_f32(b)
    end
    @wtest bswap_twice(1.5, 2.25f0)
end

i128ops(a::Int64, b::Int64) = (x = Int128(a) * Int128(b) * 1000; (x + 1, x - 7, x * 3, x ÷ 7, x % 7, x < 0, x >> 70, x << 3, leading_zeros(x), Int64(x >> 64)))
u128div(a::UInt64, b::UInt64) = (x = UInt128(a) << 64 | b; (x ÷ UInt128(12345), x % UInt128(12345), x * x, count_ones(x)))
cmp_rational(x::Float64) = x < 1 // 10^5

@testset "int128" begin
    @wtest i128ops(123456789, -987654321)
    @wtest i128ops(-3, 7)
    @wtest u128div(0x0123456789abcdef, 0xfedcba9876543210)
    @wtest cmp_rational(1e-6)
    @wtest cmp_rational(1e-4)
end

function reinterp_load(n::Int)
    buf = UInt8[(i * 37) % 256 for i in 1:16]
    p = Ptr{UInt64}(pointer(buf))
    GC.@preserve buf unsafe_load(p, 1) + unsafe_load(p, 2) * n
end
function reinterp_store(x::UInt64)
    buf = zeros(UInt8, 8)
    GC.@preserve buf unsafe_store!(Ptr{UInt64}(pointer(buf)), x)
    return sum(Int.(buf) .* (1:8))
end

# pointers that cross calls: their owner goes with them
@noinline function sum_bytes(p::Ptr{UInt8}, n::Int)
    s = 0
    for i in 1:n
        s += unsafe_load(p, i)
    end
    return s
end
@noinline function fill_words!(p::Ptr{UInt32}, n::Int, v::UInt32)
    for i in 1:n
        unsafe_store!(p, v + UInt32(i), i)
    end
end
function ptr_call(n::Int)
    buf = UInt32[i * 0x01020304 for i in 1:n]
    fill_words!(pointer(buf, 2), n - 1, UInt32(n))
    GC.@preserve buf sum_bytes(Ptr{UInt8}(pointer(buf)), 4n) + Int(buf[end])
end
@noinline copy_bytes!(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::Int) = (unsafe_copyto!(dst, src, n); nothing)
function ptr_memmove(n::Int)
    a = UInt64[i * 0x0101010101010101 for i in 1:n]
    b = zeros(UInt64, n)
    GC.@preserve a b copy_bytes!(Ptr{UInt8}(pointer(b)) + 3, Ptr{UInt8}(pointer(a)), 8n - 3)
    # overlapping, backwards
    GC.@preserve a copy_bytes!(Ptr{UInt8}(pointer(a)) + 1, Ptr{UInt8}(pointer(a)), 8n - 1)
    return sum(b) + sum(a)
end
function ptr_narrow(n::Int)
    buf = UInt32[i * 0x01020304 for i in 1:n]
    p = Ptr{UInt8}(pointer(buf))
    GC.@preserve buf unsafe_load(p, 3) + unsafe_load(p + 5, 2) * n + (pointer(buf, n) - pointer(buf)) % Int
end

# copies between memories of unions (pointers are element indices)
function union_copy(i::Int)
    a = Union{Nothing,Int}[nothing, 11, 22]
    b = Union{Nothing,Int}[nothing, nothing, nothing]
    copyto!(b, 1, a, 2, 1)
    something(b[i], 0)
end
# accesses not aligned to the elements of the memory
function misaligned(x::UInt32)
    a = UInt32[x, 0, 0]
    p = Ptr{UInt8}(pointer(a))
    GC.@preserve a begin
        r1 = unsafe_load(Ptr{UInt32}(p + 1))
        Base.memset(p + 1, 0, 2)
        Base.memmove(p + 4, p + 1, 2)
        unsafe_store!(Ptr{UInt32}(p + 7), x)
    end
    return (r1, a[1], a[2], a[3])
end
# memories whose elements are not stored as they are laid out (widened, padded)
@noinline load_tuple(p::Ptr{Tuple{UInt8,UInt32}}) = unsafe_load(p)
function widened_ptr(x::UInt32)
    a = [(0x12, x), (0x34, x + 0x1)]
    GC.@preserve a begin
        t = load_tuple(pointer(a, 2))
        b = unsafe_load(Ptr{UInt8}(pointer(a)) + 4)
    end
    return (t, b)
end
# a 128-bit element through a pointer
function ptr128(x::UInt128)
    a = UInt128[x, ~x]
    GC.@preserve a unsafe_load(pointer(a), 2) + unsafe_load(Ptr{UInt64}(pointer(a)), 2)
end
# the bytes of a Ref, copied through pointers (as Random's bulk generator does)
function ref_bytes(x::UInt64, n::Int)
    dst = zeros(UInt8, 8)
    ref = Ref(x)
    GC.@preserve ref dst copy_bytes!(pointer(dst), Ptr{UInt8}(Base.unsafe_convert(Ptr{UInt64}, ref)), n)
    return sum(Int.(dst) .* (1:8))
end

# objects back from their pointers (`unsafe_pointer_to_objref`): in the same function, across a
# call, and through a pointer stored in an array
mutable struct ObjBox; x::Int; s::String; end
@noinline objref_load(p::Ptr{Cvoid}) = (unsafe_pointer_to_objref(p)::ObjBox).x
function objref_roundtrip(n::Int)
    b = ObjBox(n, "a")
    r = Ref(2n)
    GC.@preserve b r begin
        p, q = pointer_from_objref(b), pointer_from_objref(r)
        ps = Ptr{Cvoid}[q, p]
        o = unsafe_pointer_to_objref(ps[n % 2 + 1])
        (unsafe_pointer_to_objref(p)::ObjBox).x += 1
        (unsafe_pointer_to_objref(p) === b, unsafe_pointer_to_objref(q)::Base.RefValue{Int} === r,
         objref_load(p), o isa ObjBox ? -length(o.s) : (o::Base.RefValue{Int})[])
    end
end
# a pointer into an object, or one without owner, traps (natively the result is undefined)
function objref_inside(n::Int)
    b = ObjBox(n, "a")
    GC.@preserve b (unsafe_pointer_to_objref(pointer_from_objref(b) + 8)::ObjBox).x
end
objref_int(n::Int) = (unsafe_pointer_to_objref(Ptr{Cvoid}(n))::ObjBox).x
# moved away and back: the same owner, at its base
function objref_offset(n::Int)
    b = ObjBox(n, "a")
    GC.@preserve b (unsafe_pointer_to_objref((pointer_from_objref(b) + 8n) - 8n)::ObjBox).x
end
# a pointer replaced in a loop: each iteration's object
function objref_loop(n::Int)
    bs = [ObjBox(i, "b") for i in 1:n]
    GC.@preserve bs begin
        s = 0
        p = pointer_from_objref(bs[1])
        for i in 1:n
            s += 10s + (unsafe_pointer_to_objref(p)::ObjBox).x
            p = pointer_from_objref(bs[i])
        end
        s
    end
end
# `jl_value_ptr` declared `(Any,)` of a pointer value: the address of its box natively, which
# the module does not have (not `unsafe_pointer_to_objref` of the pointer)
objref_boxed_ptr(n::Int) = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), Ptr{Cvoid}(n)) != C_NULL

# a constant field index out of a type's fields: a BoundsError at run time, as natively
function field_oob(x::Float64)
    nt = (a=x, b=2x)
    try
        getfield(nt, 3)
    catch e
        e isa BoundsError ? -1.0 : -2.0
    end
end

@testset "fields" begin
    @wtest field_oob(1.5)
end

@testset "pointers" begin
    @wtest objref_roundtrip(3)
    @wtest objref_roundtrip(4)
    for f in (objref_inside, objref_int)
        got = wasm_run(wcompile(f, (Int,)), string(nameof(f)), 8; rettype=Int)
        @test got isa Tuple && got[1] === :trap
    end
    @wtest objref_offset(3)
    @wtest objref_loop(5)
    @test objref_boxed_ptr(8)
    @test_throws WasmCodegen.UnsupportedConstructs wcompile(objref_boxed_ptr, (Int,))
    @wtest union_copy(1)
    @wtest misaligned(0x12345678)
    @wtest widened_ptr(0x12345678)
    @wtest ptr128(0x0102030405060708090a0b0c0d0e0f10)
    @wtest ref_bytes(0x0102030405060708, 5)
    @wtest reinterp_load(3)
    @wtest reinterp_store(0x0102030405060708)
    @wtest ptr_call(5)
    @wtest ptr_memmove(4)
    @wtest ptr_narrow(4)
end

# calls whose results are unused still run when they may throw, and the computation of an
# exception keeps its effects (Codex review)
@noinline check_nonzero(x::Int) = (x == 0 && error("boom"); 1)
unused_throwing(x::Int) = (check_nonzero(x); 2)
const ERR_EFFECT = Ref(0)
@noinline make_error() = (ERR_EFFECT[] = 9; ErrorException("boom"))
@noinline throw_made(x::Int) = x > 0 ? throw(make_error()) : x
function error_effect(x::Int)
    ERR_EFFECT[] = 0
    throw_made(x)
    return ERR_EFFECT[]
end
read_err_effect() = ERR_EFFECT[]

@testset "effects" begin
    @wtest unused_throwing(1)
    @wtest unused_throwing(0)
    @wtest error_effect(0)
    # the trap leaves the effect behind: read it with another export of the same instance
    c = WasmCodegen.compile([(error_effect, (Int,)), (read_err_effect, ())])
    @test wasm_run(c, "error_effect", 1; rettype=Int) isa Tuple
    @test wasm_run(c, "read_err_effect"; rettype=Int) == 9
end

# counting loops keep the signedness and width of their comparison (Codex review)
function count_up(lo, hi)
    i = lo; n = 0
    while i < hi
        n += 1
        i += one(i)
    end
    return n
end
function count_inclusive(lo::Int8, hi::Int8)
    n = 0
    for i in lo:hi
        n += 1
    end
    return n
end

@testset "loops" begin
    @wtest count_up(UInt64(2)^63 - 1, UInt64(2)^63 + 1)
    @wtest count_up(Int8(-2), Int8(1))
    @wtest count_up(UInt8(250), UInt8(255))
    @wtest count_up(-3, 4)
    @wtest count_inclusive(Int8(120), typemax(Int8))
    @wtest count_inclusive(Int8(-128), Int8(-126))
end

# (Codex review) overflow checks that must not trap; tuple indices out of bounds must
dynamic_tuple_index(i::Int) = getfield((1, 2, 3), i)
dynamic_long_tuple_index(i::Int) = getfield((1, 2, 3, 4, 5, 6), i)
smul_overflow(a::Int64, b::Int64) = Base.mul_with_overflow(a, b)

@testset "checks" begin
    @wtest smul_overflow(-1, typemin(Int64))
    @wtest smul_overflow(typemin(Int64), -1)
    @wtest smul_overflow(-1, 5)
    @wtest smul_overflow(0, typemin(Int64))
    @wtest smul_overflow(3, typemax(Int64))
    @wtest dynamic_tuple_index(0)
    @wtest dynamic_tuple_index(3)
    @wtest dynamic_tuple_index(4)
    @wtest dynamic_long_tuple_index(6)
    @wtest dynamic_long_tuple_index(7)
    @wtest dynamic_long_tuple_index(2^32 + 1)
end

# strings and symbols are === by content (Codex review); Base's == of strings is ===
function fresh_string(c::UInt8)
    s = ccall(:jl_alloc_string, Ref{String}, (Csize_t,), 1)
    GC.@preserve s unsafe_store!(pointer(s), c)
    return s
end
strings_egal(c::UInt8, d::UInt8) = fresh_string(c) === fresh_string(d)
strings_eq(n::Int) = string(n) == string(n, base=10) && string(n) != string(n + 1)
function string_vs_any(c::UInt8)
    xs = Any[fresh_string(c), 1, "b"]
    return (xs[1] === "a", xs[2] === "a", xs[3] === "b", count(x -> x === "b", xs))
end
symbols_egal(n::Int) = Symbol("x", n) === Symbol("x", n)
compare_strings(n::Int) = (cmp(string(n), "5"), isless("abc", string(n)), string(n) < "5")

@testset "identity" begin
    @wtest strings_egal(0x61, 0x61)
    @wtest strings_egal(0x61, 0x62)
    @wtest strings_eq(12)
    @wtest string_vs_any(0x61)
    @wtest symbols_egal(3)
    @wtest compare_strings(42)
end

# assignments of global variables (Codex review)
global wasm_counter::Int = 0
set_counter(x::Int) = (global wasm_counter = x; wasm_counter + 1)

@testset "globals" begin
    @wtest set_counter(41)
end
global wasm_uninit::Int
read_uninit() = wasm_uninit
function assign_uninit(x::Int)
    a = @isdefined(wasm_uninit)
    global wasm_uninit = x
    return (a, @isdefined(wasm_uninit), wasm_uninit)
end

@testset "undefined globals" begin
    @wtest read_uninit()
    c = WasmCodegen.compile([(read_uninit, ()), (assign_uninit, (Int,))])
    @test wasm_run(c, "read_uninit"; rettype=Int) isa Tuple
    @test wasm_run(c, "assign_uninit", 5; rettype=Tuple{Bool,Bool,Int}) == (false, true, 5)
    @test wasm_run(c, "read_uninit"; rettype=Int) == 5
end

# type objects are interned: one object per type, whether a constant or a value (Codex review)
const TYPE_REF = Ref{Any}(Int)
type_egal() = TYPE_REF[] === Int
type_isa() = (TYPE_REF[] isa Type{Int}, TYPE_REF[] isa Type{Float64}, TYPE_REF[] isa Union{Type{Int},Type{Bool}})
function type_roundtrip(b::Bool)
    x = Base.inferencebarrier(b ? Int : Float64)::Type
    return (x === Int, x === Float64, x isa Type{Float64})
end

@testset "type objects" begin
    @wtest type_egal()
    @wtest type_isa()
    @wtest type_roundtrip(true)
    @wtest type_roundtrip(false)
end

# tuples of unknown length (arrays) narrowed to and widened from tuples of known length
# (Codex review)
function vararg_narrow(n::Int)
    t = (collect(1:n)...,)
    return t isa Tuple{Int,Int} ? t[1] + t[2] : 0
end
@noinline function vararg_sum(@nospecialize(t::Tuple{Vararg{Int}}))
    s = 0
    for x in t
        s += x
    end
    return s
end
Base.@nospecializeinfer vararg_widen(x::Int) = vararg_sum((x, x + 1, x + 2))

@testset "vararg tuples" begin
    @wtest vararg_narrow(2)
    @wtest vararg_narrow(3)
    @wtest vararg_widen(5)
end
bottom_isa(b::Bool) = (Base.inferencebarrier(b ? Union{} : Int)::Type) isa Type{Union{}}

@testset "type objects: Union{}" begin
    @wtest bottom_isa(true)
    @wtest bottom_isa(false)
end

# fields at indices and names known only at run time (getproperty with a Symbol variable)
struct Fields3
    a::Int
    b::Float64
    c::Bool
end
field_by_index(i::Int) = Float64(getfield(Fields3(1, 2.5, true), i))
field_by_name(s::Symbol) = Float64(getproperty(Fields3(1, 2.5, true), s))
field_by_name_str(i::Int) = field_by_name((:a, :b, :c, :d)[i])

@testset "dynamic fields" begin
    @wtest field_by_index(2)
    @wtest field_by_index(3)
    @wtest field_by_index(4)
    @wtest field_by_name_str(1)
    @wtest field_by_name_str(2)
    @wtest field_by_name_str(4)
end
