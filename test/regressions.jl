# Programs that were compiled wrong: identity, layouts, pointers, undefined values, tuples of
# unknown length, and LAPACK's extreme magnitudes

using LinearAlgebra

@noinline rg_id(x) = x
const RI = Core.Intrinsics

# type objects keep their native objectid: keys of an IdDict built at compile time
const RG_TYPEKEYS = IdDict{Any,Int}(Int => 1, Union{Int,Nothing} => 2, Vector => 3, Union{} => 4)
const RG_TYPES = Any[Int, Union{Int,Nothing}, Vector, Union{}, Float64]
rg_typekeys(i::Int) = (get(RG_TYPEKEYS, RG_TYPES[i], -1), objectid(RG_TYPES[i]) == objectid(RG_TYPES[min(i + 1, 5)]))

# a Bool is one bit for the intrinsics (true is -1 signed)
rg_bool(x::Bool, y::Bool) = (RI.sext_int(Int64, x), RI.slt_int(x, y), RI.sitofp(Float64, x), RI.ctlz_int(x),
                             RI.checked_sadd_int(x, y), RI.shl_int(x, 1), RI.ashr_int(x, 5))
rg_bool_sdiv(x::Bool, y::Bool) = try RI.checked_sdiv_int(x, y) catch e; e isa DivideError ? false : true end

# pointers: === by address, clearing references through them
struct RGPtr; p::Ptr{UInt8}; n::Int; end
function rg_ptr_egal(i::Int)
    a = UInt8[1, 2, 3]
    GC.@preserve a begin
        p, q = pointer(a, i), Ptr{UInt8}(UInt(pointer(a, 2)))
        v = Any[p, q, RGPtr(p, 1), RGPtr(q, 1)]
        (v[1] === v[2], v[3] === v[4])
    end
end
function rg_null_store(i::Int)
    a = Any[1, 2, 3]
    m = Union{String,Vector{Int}}["a", [1], "c"]
    GC.@preserve a m begin
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(a)), C_NULL, i)
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(m)) + 8 * (i - 1), C_NULL)
    end
    (isassigned(a, 1), isassigned(a, 2), isassigned(a, 3), isassigned(m, 2), Int(pointer(m, 3) - pointer(m, 1)))
end

# memset and memmove of parts of elements stored with padding
function rg_memset(n::Int)
    a = [(UInt8(17), UInt64(123))]
    b = [ntuple(_ -> (Int8(1), Int16(2)), 3), ntuple(_ -> (Int8(1), Int16(2)), 3)]
    GC.@preserve a b begin
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), pointer(a), 0, n)
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), pointer(b), 0, n)
    end
    (a[1], b[1][1], b[1][3], b[2][1])
end
function rg_memmove(n::Int)
    a = [(UInt8(17), UInt64(123))]
    b = [(UInt8(5), UInt64(6))]
    GC.@preserve a b unsafe_copyto!(Ptr{UInt8}(pointer(b)), Ptr{UInt8}(pointer(a)), n)
    b[1]
end

# a typed global of a tuple with a union element (stored boxed)
global rg_utuple::Tuple{Union{Int,Nothing},Tuple{Union{Float64,Nothing},Int}} = (nothing, (2.5, 3))
rg_union_tuple_global(i::Int) = (rg_utuple[1] === nothing, rg_utuple[2][1]::Float64 + i, rg_utuple[2][2])

# values never stored: zero bits where Julia stores them inline without references, else
# undefined (UndefRefError); (memories of isbits elements are not zeroed natively, but those
# of unions are)
struct RGS; x::Int; s::String; end
mutable struct RGM; x::Union{Nothing,Int}; y::String; z::Some{Union{Nothing,Int}}; RGM() = new(); end
struct RGI; a::Int; u::Union{Nothing,Float64}; RGI(a) = new(a); end
rg_undef_ref(n::Int) = (try Vector{RGS}(undef, n)[1].x catch e; e isa UndefRefError ? -1 : -2 end,
                        try Vector{Tuple{String,String}}(undef, n)[1]; 0 catch e; e isa UndefRefError ? -1 : -2 end)
rg_undef_zero(n::Int) = (isassigned(Vector{Ptr{Cvoid}}(undef, n), 1), (Vector{Ptr{Cvoid}}(undef, n)[1]; true),
                         ismissing(Vector{Union{Missing,Float64}}(undef, n)[n]),
                         count(isnothing, Vector{Union{Nothing,Int}}(undef, n)),
                         Vector{Some{Union{Nothing,Int}}}(undef, n)[1].value === nothing,
                         typeof(Vector{Union{Int8,Int32}}(undef, n)[1]) === Int8)
rg_undef_fields(i::Int) = (m = RGM(); (isdefined(m, :x), isdefined(m, :z), isdefined(m, :y),
                                         try m.y; 0 catch e; e isa UndefRefError ? i : -1 end))
# (fields of unions `new` is not given: zero bits from Julia 1.13 on, uninitialized before)
rg_unset_union_fields(i::Int) = (m = RGM(); s = rg_id(RGI(i)); (m.x === nothing, m.z.value === nothing, s.u === nothing))

# errors of memory sizes, and shifts by 128-bit counts
rg_memsize(n::Int) = try length(Vector{Int}(undef, n)) catch e; e isa ArgumentError ? -1 : -2 end
rg_shift128(x::Int64, n::UInt128) = (x << n, x >> n, x >>> n, Int8(x) << n)

# tuples of unknown length (from splatting) as objects: of their concrete types
rg_vt_isa(n::Int) = (x = rg_id(Any[(collect(1:n)...,)])[1];
                     (x isa Tuple{Int,Int}, x isa NTuple{3,Int}, x isa Tuple{Vararg{Int}}, x === (1, 2), x === (1, 2, 3)))
rg_vt_egal(n::Int) = (v = collect(1:n); w = collect(1:3); (tuple(v...) === (1, 2, 3), tuple(v...) === tuple(w...)))
rg_vt_abstract(i::Int) = (x = rg_id(Any[(i, "x"), (1.5,), ("y", 2)])[i];
                          (x isa Tuple ? length(x) : -1, x isa Tuple{Int,Vararg} ? x[1] : -1,
                           x isa Tuple ? objectid(x) == objectid((i, "x")) : false))
rg_vt_vararg(i::Int) = (u = rg_id(Any[(i, 2.5, 3.5), (i, 2.5, "x"), (i,), ("s", 1.0)])[i]::Tuple;
                        (u isa Tuple{Int,Vararg{Float64}}, u isa Tuple{Int,Vararg{String}}, u isa Tuple{Any,Any,Vararg{Any}}))
rg_vt_iddict(n::Int) = (d = IdDict{Any,Int}(); d[(collect(1:n)...,)] = 4;
                        (get(d, (collect(1:n)...,), -1), get(d, (collect(1:n+1)...,), -1)))
rg_vt_large(n::Int) = (x = rg_id(Any[(collect(1:n)...,)])[1]; (x isa NTuple{70,Int}, x === ntuple(identity, 70)))
# (of concrete types the module does not have: objects of `Tuple`, whatever their elements'
# storage, tested and converted by their elements)
rg_vt_absent(n::Int) = (x = rg_id(Any[tuple(collect(1:n)...)])[1];
                        (x isa Tuple{Int,Vararg{Int}}, x isa Tuple{Vararg{Real}}, x isa Tuple{Vararg{String}},
                         length(x::Tuple), (y = x::Tuple{Vararg{Int}}; s = 0; for i in 1:length(y); s += y[i]; end; s)))
rg_vt_absent_egal(n::Int) = (v = Vector{Any}(undef, 2); v[1] = tuple(collect(1:n)...); v[2] = tuple(Vector{Any}(collect(1:n))...);
                             v = rg_id(v); (v[1] === v[2], objectid(v[1]) == objectid(v[2])))
# (large tuples as tuples of unknown length of other storage, and back; in the image)
const RG_BIG = ntuple(identity, 70)
global rg_big::Tuple = ntuple(identity, 70)
rg_vt_storage(n::Int) = (x = tuple(Vector{Any}(collect(1:n))...)::NTuple{70,Int};
                         (length(rg_id(Any[RG_BIG])[1]::Tuple), x[1] + x[70], length(rg_big), rg_big[70]::Int))
# (a field of a tuple type of unknown length, from the image and made at run time)
struct RGVt; t::Tuple{Vararg{Union{Int,String}}}; end
const RG_VT = RGVt((3, "a"))
rg_vt_field(n::Int) = (a = rg_id(Any[RGVt((n, "a"))])[1]; b = rg_id(Any[RG_VT])[1]; (a === b, objectid(a) == objectid(b)))

# singular values and symmetric eigenvalues of extreme magnitudes (scaled, as LAPACK does)
rg_svd(x::Float64) = (s = svdvals([x 2x; 3x 4x]); (s[1] / x, s[2] / x, svdvals(fill(x, 1, 1))[1] / x))
rg_eig(x::Float64) = (e = eigvals(Symmetric([2x x 0; x 3x x; 0 x 4x])); (e[1] / x, e[2] / x, e[3] / x))

# closures capturing a variable inferred as a small Union: `apply_type` and `new` of a type
# known only to be one of a few (as Pkg's registry and download functions have)
@noinline rg_callit(g) = g()
@noinline rg_pick(flag::Bool) = flag ? [1, 2, 3] : ["a", "b"]
@noinline rg_maybe_str(n::Int) = n > 0 ? string("s", n) : nothing
@noinline rg_maybe_tup(n::Int) = n > 0 ? (SubString("abcd", 1, n), Dict(1 => n)) : nothing
function rg_closure_vec(flag::Bool)
    v = rg_pick(flag)
    return rg_callit(() -> length(v) * 10 + (v isa Vector{Int} ? 1 : 2))
end
function rg_closure_nothing(n::Int)
    s = string("ab", "c"^max(n, 0))
    m = rg_maybe_str(n)
    k = n + 1
    return rg_callit(() -> (m === nothing ? 0 : length(m)) + length(s) * k)
end
function rg_closure_tuple(n::Int)
    t = rg_maybe_tup(n)
    return rg_callit(() -> t === nothing ? -1 : length(t[1]) + t[2][1])
end
# a `new` of one of a few types whose field is not correlated with the choice: a TypeError
# where the field does not fit, as natively
struct RGUnionBox{T}; x::T; end
mutable struct RGMutableBox{T}; x::T; end
@noinline rg_unionpick(flag::Bool) = flag ? 42 : 2.5
@generated function rg_unionfield(flag::Bool, pick::Bool)
    newex = Expr(:new, :(flag ? RGUnionBox{Int} : RGUnionBox{Float64}), :x)
    quote
        x = rg_unionpick(pick)
        b = $newex
        b isa RGUnionBox{Int} ? (1, Float64(b.x)) : (2, b.x)
    end
end
@generated rg_mutable(flag::Bool, x::Float64) =
    Expr(:new, :(flag ? RGMutableBox{Int} : RGMutableBox{Float64}), :x)
function rg_mutablefield(flag::Bool, x::Float64)
    b = rg_mutable(flag, x)
    return b isa RGMutableBox{Int} ? Float64(b.x) : b.x
end
# (caught, with a `finally`)
function rg_catch_new(flag::Bool, pick::Bool)
    cleaned = Ref(0)
    r = try
        try
            rg_unionfield(flag, pick)[1]
        finally
            cleaned[] += 1
        end
    catch e
        e isa TypeError ? (e.func === :new ? 10 : 20) + (e.expected === Int ? 1 : e.expected === Float64 ? 2 : 3) : 30
    end
    return (r, cleaned[])
end
function rg_catch_mutable(flag::Bool, x::Float64)
    try
        rg_mutablefield(flag, x)
    catch e
        e isa TypeError && e.func === :new && e.got === x ? -1.0 : -2.0
    end
end
@testset "regressions" begin
    @wtest rg_unionfield(true, true)
    @wtest rg_unionfield(false, false)
    @wtest rg_mutablefield(false, 2.5)
    for flag in (true, false), pick in (true, false)
        @wtest rg_catch_new(flag, pick)
    end
    @wtest rg_catch_mutable(true, 2.5)
    @wtest rg_catch_mutable(false, 2.5)
    # (a union of type objects other than `Type{T}`s is not split)
    @test WasmCodegen.split_types(Union{DataType,UnionAll}) === nothing
    @test WasmCodegen.split_types(Union{Type{Int},Type{Float64}}) == Any[Int, Float64] ||
          WasmCodegen.split_types(Union{Type{Int},Type{Float64}}) == Any[Float64, Int]
    for flag in (true, false)
        @wtest rg_closure_vec(flag)
    end
    for n in (-1, 0, 3)
        @wtest rg_closure_nothing(n)
        @wtest rg_closure_tuple(n)
    end
    for i in 1:5
        @wtest rg_typekeys(i)
    end
    for (x, y) in ((true, false), (true, true), (false, true))
        @wtest rg_bool(x, y)
        @wtest rg_bool_sdiv(x, y)
    end
    @wtest rg_ptr_egal(1); @wtest rg_ptr_egal(2)
    @wtest rg_null_store(2); @wtest rg_null_store(3)
    for n in (1, 9, 12, 13, 16)
        @wtest rg_memset(n)
    end
    @wtest rg_memmove(1); @wtest rg_memmove(16)
    @wtest rg_union_tuple_global(1)
    @wtest rg_undef_ref(2)
    @wtest rg_undef_zero(3)
    @wtest rg_undef_fields(3)
    VERSION >= v"1.13-" && @wtest rg_unset_union_fields(3)
    @wtest rg_memsize(-1); @wtest rg_memsize(3)
    @wtest rg_shift128(-5, UInt128(2)); @wtest rg_shift128(-5, UInt128(1) << 70)
    for n in 2:3
        @wtest rg_vt_isa(n)
        @wtest rg_vt_egal(n)
        @wtest rg_vt_iddict(n)
    end
    for i in 1:3
        @wtest rg_vt_abstract(i)
    end
    for i in 1:4
        @wtest rg_vt_vararg(i)
    end
    @wtest rg_vt_large(70); @wtest rg_vt_large(3)
    @wtest rg_vt_absent(2); @wtest rg_vt_absent(17)
    @wtest rg_vt_absent_egal(17)
    @wtest rg_vt_storage(70)
    @wtest rg_vt_field(3); @wtest rg_vt_field(4)
    for x in (1.0, 1e100, 1e-100, 1e200, 1e-200, 1e300, 1e-300)
        @wtest_approx rg_svd(x)
        @wtest_approx rg_eig(x)
    end
end
