# SIMD vectors and WebAssembly SIMD128.
#
# `WasmCodegen.SIMD128`'s operations on vectors of 16 bytes (`NTuple{2,VecElement{Float64}}`,
# `NTuple{4,VecElement{Float32}}`) and of 8 bytes (`NTuple{2,VecElement{Float32}}`, the low lanes
# of an f32x4) compile to `v128` instructions; natively, and for every other vector type, each is
# the same operation lane by lane. Packages whose vector types are such tuples (SIMD.jl's `Vec`,
# through WasmCompat's overlays of its intrinsics) call them.
#
# Representation: a vector keeps its layout of N scalar leaves, so all other code (tuples,
# fields, arrays, calls) is unchanged. A vector an operation below defines also has a `v128`
# local holding the same lanes, cached per function by its leaf locals (`fc.v128s`). Both are
# set at the definition, and its leaves are fresh locals assigned only there, so wherever the
# leaves are valid (dominated by the definition) the v128 is valid too. An operand without a
# cached v128 (an argument, a loop carry, a tuple built from scalars, a constant) is built at
# its use with splat and replace_lane (wasm-opt folds constants into `v128.const`), and that
# build is not cached. The lanes are extracted into the leaves at the definition; wasm-opt
# removes the extractions nothing reads.
#
# The operations reach the code generator as foreign calls `wasm_simd_<shape>_<op>`, which the
# overlays below make in WasmCodegen's method table.

"""
    WasmCodegen.SIMD128

Operations on SIMD vectors of type `NTuple{2,VecElement{Float64}}`, `NTuple{4,VecElement{Float32}}`
or `NTuple{2,VecElement{Float32}}` that compile to WebAssembly SIMD128 instructions: `add`, `sub`,
`mul`, `div`, `neg`, `abs`, `sqrt`, `muladd` (as `relaxed_madd` with `Config(relaxed_simd = true)`,
fused where the hardware has FMA, as `Base.muladd` may be), `splat`, `shuffle` (lanes known at
compile time), `vload` and `vstore` through a pointer. Natively each is the same operation lane by
lane.
"""
module SIMD128

import ..Runtime: WASM_METHODS

const F64x2 = NTuple{2,VecElement{Float64}}
const F32x4 = NTuple{4,VecElement{Float32}}
const F32x2 = NTuple{2,VecElement{Float32}}

@inline _map(f, x::NTuple{N,VecElement{T}}) where {N,T} = ntuple(i -> VecElement(f(x[i].value)), Val(N))
@inline _map(f, x::NTuple{N,VecElement{T}}, y::NTuple{N,VecElement{T}}) where {N,T} =
    ntuple(i -> VecElement(f(x[i].value, y[i].value)), Val(N))
@inline _map(f, x::NTuple{N,VecElement{T}}, y::NTuple{N,VecElement{T}}, z::NTuple{N,VecElement{T}}) where {N,T} =
    ntuple(i -> VecElement(f(x[i].value, y[i].value, z[i].value)), Val(N))

"Lanewise `x + y`."
@inline add(x::V, y::V) where {V<:NTuple{<:Any,VecElement}} = _map(Base.add_float, x, y)
"Lanewise `x - y`."
@inline sub(x::V, y::V) where {V<:NTuple{<:Any,VecElement}} = _map(Base.sub_float, x, y)
"Lanewise `x * y`."
@inline mul(x::V, y::V) where {V<:NTuple{<:Any,VecElement}} = _map(Base.mul_float, x, y)
"Lanewise `x / y`."
@inline div(x::V, y::V) where {V<:NTuple{<:Any,VecElement}} = _map(Base.div_float, x, y)
"Lanewise `-x`."
@inline neg(x::NTuple{<:Any,VecElement}) = _map(Base.neg_float, x)
"Lanewise `abs(x)`."
@inline abs(x::NTuple{<:Any,VecElement}) = _map(Base.abs, x)
"Lanewise `sqrt(x)` (NaN for negative lanes, as LLVM's `llvm.sqrt`)."
@inline sqrt(x::NTuple{<:Any,VecElement}) = _map(Base.sqrt_llvm, x)
"Lanewise `muladd(a, b, c)`: `a * b + c`, fused or not."
@inline muladd(a::V, b::V, c::V) where {V<:NTuple{<:Any,VecElement}} = _map(Base.muladd, a, b, c)
"The vector of type `V` whose lanes are all `x`."
@inline splat(::Type{NTuple{N,VecElement{T}}}, x::T) where {N,T} = ntuple(_ -> VecElement(x), Val(N))
"""
    shuffle(x, Val(I)), shuffle(x, y, Val(I))

The vector whose lane `j` is lane `I[j]` (0-based) of `x`, or of the lanes of `x` followed by those
of `y`. `I` has as many lanes as `x`.
"""
@inline shuffle(x::NTuple{N,VecElement{T}}, ::Val{I}) where {N,T,I} =
    (length(I) == N || throw(ArgumentError("a shuffle keeps the number of lanes")); ntuple(j -> x[I[j]+1], Val(N)))
@inline shuffle(x::NTuple{N,VecElement{T}}, y::NTuple{N,VecElement{T}}, ::Val{I}) where {N,T,I} =
    (length(I) == N || throw(ArgumentError("a shuffle keeps the number of lanes"));
     ntuple(j -> I[j] < N ? x[I[j]+1] : y[I[j]-N+1], Val(N)))
"The vector of type `V` of the `N` elements at `p`."
@inline vload(::Type{NTuple{N,VecElement{T}}}, p::Ptr{T}) where {N,T} = ntuple(i -> VecElement(unsafe_load(p, i)), Val(N))
"Store the lanes of `x` at `p`."
@generated function vstore(x::NTuple{N,VecElement{T}}, p::Ptr{T}) where {N,T}
    quote
        $([:(unsafe_store!(p, x[$i].value, $i)) for i in 1:N]...)
        nothing
    end
end

# in Wasm: the foreign calls the code generator lowers (`emit_simd!`)
for (V, s) in ((F64x2, "f64x2"), (F32x4, "f32x4"), (F32x2, "f32x2"))
    T = fieldtype(fieldtype(V, 1), 1)
    N = fieldcount(V)
    q(op) = QuoteNode(Symbol("wasm_simd_", s, "_", op))
    for op in (:add, :sub, :mul, :div)
        @eval Base.Experimental.@overlay WASM_METHODS @inline $op(x::$V, y::$V) = ccall($(q(op)), $V, ($V, $V), x, y)
    end
    for op in (:neg, :abs, :sqrt)
        @eval Base.Experimental.@overlay WASM_METHODS @inline $op(x::$V) = ccall($(q(op)), $V, ($V,), x)
    end
    lanes(k) = [:(I[$j]) for j in 1:k]
    @eval begin
        Base.Experimental.@overlay WASM_METHODS @inline muladd(a::$V, b::$V, c::$V) =
            ccall($(q(:madd)), $V, ($V, $V, $V), a, b, c)
        Base.Experimental.@overlay WASM_METHODS @inline splat(::Type{$V}, x::$T) = ccall($(q(:splat)), $V, ($T,), x)
        Base.Experimental.@overlay WASM_METHODS @inline vload(::Type{$V}, p::Ptr{$T}) = ccall($(q(:load)), $V, (Ptr{$T},), p)
        Base.Experimental.@overlay WASM_METHODS @inline vstore(x::$V, p::Ptr{$T}) =
            ccall($(q(:store)), Cvoid, ($V, Ptr{$T}), x, p)
        Base.Experimental.@overlay WASM_METHODS @inline shuffle(x::$V, ::Val{I}) where {I} =
            (length(I) == $N || throw(ArgumentError("a shuffle keeps the number of lanes"));
             ccall($(q(:shuffle1)), $V, ($V, $(fill(Int, N)...)), x, $(lanes(N)...)))
        Base.Experimental.@overlay WASM_METHODS @inline shuffle(x::$V, y::$V, ::Val{I}) where {I} =
            (length(I) == $N || throw(ArgumentError("a shuffle keeps the number of lanes"));
             ccall($(q(:shuffle2)), $V, ($V, $V, $(fill(Int, N)...)), x, y, $(lanes(N)...)))
    end
end

end # module SIMD128

## the instructions

function leb128(x::Integer)
    out = UInt8[]
    while true
        b = UInt8(x & 0x7f); x >>= 7
        x == 0 ? (push!(out, b); break) : push!(out, b | 0x80)
    end
    return out
end

# the SIMD instructions used (prefix 0xfd), added to WasmBuilder's table on first use: name =>
# (opcode, immediates, params, results). A lane index or shuffle lane (< 32) is a `u32`
# immediate, whose LEB128 encoding is the one byte the format has.
const SIMD_INSTRUCTIONS = Dict{Symbol,Tuple{Int,Tuple,Tuple,Tuple}}(
    :i8x16_shuffle => (0x0d, ntuple(_ -> :u32, 16), (V128, V128), (V128,)),
    :f32x4_splat => (0x13, (), (F32,), (V128,)), :f64x2_splat => (0x14, (), (F64,), (V128,)),
    :f32x4_extract_lane => (0x1f, (:u32,), (V128,), (F32,)), :f32x4_replace_lane => (0x20, (:u32,), (V128, F32), (V128,)),
    :f64x2_extract_lane => (0x21, (:u32,), (V128,), (F64,)), :f64x2_replace_lane => (0x22, (:u32,), (V128, F64), (V128,)),
    :f32x4_abs => (0xe0, (), (V128,), (V128,)), :f32x4_neg => (0xe1, (), (V128,), (V128,)),
    :f32x4_sqrt => (0xe3, (), (V128,), (V128,)),
    :f32x4_add => (0xe4, (), (V128, V128), (V128,)), :f32x4_sub => (0xe5, (), (V128, V128), (V128,)),
    :f32x4_mul => (0xe6, (), (V128, V128), (V128,)), :f32x4_div => (0xe7, (), (V128, V128), (V128,)),
    :f64x2_abs => (0xec, (), (V128,), (V128,)), :f64x2_neg => (0xed, (), (V128,), (V128,)),
    :f64x2_sqrt => (0xef, (), (V128,), (V128,)),
    :f64x2_add => (0xf0, (), (V128, V128), (V128,)), :f64x2_sub => (0xf1, (), (V128, V128), (V128,)),
    :f64x2_mul => (0xf2, (), (V128, V128), (V128,)), :f64x2_div => (0xf3, (), (V128, V128), (V128,)),
    :f32x4_relaxed_madd => (0x105, (), (V128, V128, V128), (V128,)),
    :f64x2_relaxed_madd => (0x107, (), (V128, V128, V128), (V128,)))

# emit the SIMD instruction `name` with the immediates `imms`
function simd!(fc::FnCtx, name::Symbol, imms...)
    if !haskey(WasmBuilder.INSTRUCTIONS, name)
        code, ik, params, results = SIMD_INSTRUCTIONS[name]
        WasmBuilder.definst!(name, UInt8[0xfd; leb128(code)], ik;
                             sig=(ValType[params...], ValType[results...]))
    end
    emit!(fc.b, name, imms...)
end

## lowering

# the shape of a vector type: (instruction prefix, lanes, lane type, lane Wasm type), or nothing
function simd_shape(@nospecialize(V))
    V isa DataType && V <: Tuple && fieldcount(V) in (2, 4) || return nothing
    E = fieldtype(V, 1)
    E isa DataType && E <: VecElement || return nothing
    T = fieldtype(E, 1); N = fieldcount(V)
    V === NTuple{N,VecElement{T}} || return nothing
    T === Float64 && N == 2 && return (:f64x2, 2, Float64, F64)
    T === Float32 && (N == 4 || N == 2) && return (:f32x4, N, Float32, F32)
    return nothing
end

simd_name(sh, op) = Symbol(sh[1], "_", op)

v128_key(v::CGVal) = all(l -> l isa Int, v.leaves) ? Int[l for l in v.leaves] : nothing

"Push the v128 of the vector `v` (of shape `sh`): its cached local, else built from its lanes."
function push_v128!(fc::FnCtx, v::CGVal, sh)
    key = v128_key(v)
    r = key === nothing ? nothing : get(fc.v128s, key, nothing)
    if r !== nothing
        emit!(fc.b, :local_get, r)
        return
    end
    N = sh[2]
    push_leaf!(fc, v.leaves[1])
    simd!(fc, simd_name(sh, :splat))
    for k in 2:N
        v.leaves[k] == v.leaves[1] && continue
        push_leaf!(fc, v.leaves[k])
        simd!(fc, simd_name(sh, :replace_lane), k - 1)
    end
end

"The vector of type `V` of the v128 on the stack: a new local, cached, its lanes extracted into new leaves."
function v128_result!(fc::FnCtx, @nospecialize(V), sh)
    r = new_local!(fc, V128)
    emit!(fc.b, :local_set, r)
    leaves = LeafVal[]
    for k in 0:sh[2]-1
        emit!(fc.b, :local_get, r)
        simd!(fc, simd_name(sh, :extract_lane), k)
        l = new_local!(fc, sh[4])
        emit!(fc.b, :local_set, l)
        push!(leaves, l)
    end
    v = CGVal(V, Inline, leaves)
    fc.v128s[v128_key(v)] = r
    return v
end

"""
    emit_simd!(fc, op, args, typ) -> CGVal

The foreign call `wasm_simd_<op>` (`op` = `<shape>_<operation>`, made by `SIMD128`'s overlays).
"""
function emit_simd!(fc::FnCtx, op::String, args::Vector{Any}, @nospecialize(typ))
    _, what = split(op, '_'; limit=2)
    V = what == "store" ? (args[1]::CGVal).typ : typ
    sh = simd_shape(V)
    sh === nothing && unsupported("wasm_simd_", op, " of ", V)
    for a in args
        a isa CGVal && simd_shape(a.typ) !== nothing && a.typ !== V &&
            unsupported("wasm_simd_", op, " of ", a.typ, " to ", V)
    end
    _, N, T, wt = sh
    if what in ("add", "sub", "mul", "div")
        push_v128!(fc, args[1], sh); push_v128!(fc, args[2], sh)
        simd!(fc, simd_name(sh, what))
        return v128_result!(fc, typ, sh)
    elseif what in ("neg", "abs", "sqrt")
        push_v128!(fc, args[1], sh)
        simd!(fc, simd_name(sh, what))
        return v128_result!(fc, typ, sh)
    elseif what == "madd"
        push_v128!(fc, args[1], sh); push_v128!(fc, args[2], sh)
        if fc.cgm.config.relaxed_simd
            push_v128!(fc, args[3], sh)
            simd!(fc, simd_name(sh, :relaxed_madd))
        else
            simd!(fc, simd_name(sh, :mul))
            push_v128!(fc, args[3], sh)
            simd!(fc, simd_name(sh, :add))
        end
        return v128_result!(fc, typ, sh)
    elseif what == "splat"
        push_val!(fc, convert_repr(fc, args[1]::CGVal, T))
        simd!(fc, simd_name(sh, :splat))
        return v128_result!(fc, typ, sh)
    elseif what == "shuffle1" || what == "shuffle2"
        two = what == "shuffle2"
        idx = args[(two ? 3 : 2):end]
        all(a -> a isa CGVal && isconstant(a), idx) || unsupported("a shuffle with lanes not known at compile time")
        sz = sizeof(T); P = 16 ÷ sz     # lanes of the v128 (an 8-byte vector uses the low half)
        bytes = Int[]
        for a in idx, j in 0:sz-1
            s = Int(constant_value(a))
            0 <= s < (two ? 2N : N) || unsupported("a shuffle lane out of range")
            push!(bytes, (s < N ? s : s - N + P) * sz + j)
        end
        append!(bytes, zeros(Int, 16 - length(bytes)))
        push_v128!(fc, args[1], sh)
        if two
            push_v128!(fc, args[2], sh)
        else
            t = new_local!(fc, V128); emit!(fc.b, :local_tee, t); emit!(fc.b, :local_get, t)
        end
        simd!(fc, :i8x16_shuffle, bytes...)
        return v128_result!(fc, typ, sh)
    elseif what == "load"
        p = args[1]::CGVal
        if fused_vector_access(p, T)
            vector_load!(fc, p, sh)
        else
            # lane by lane, then one v128
            leaves = LeafVal[]
            for k in 1:N
                append!(leaves, ptr_load!(fc, p, const_value(fc, k), T).leaves)
            end
            push_v128!(fc, CGVal(typ, Inline, leaves), sh)
        end
        return v128_result!(fc, typ, sh)
    elseif what == "store"
        x, p = args[1]::CGVal, args[2]::CGVal
        if fused_vector_access(p, T)
            vector_store!(fc, x, p, sh)
        else
            for k in 1:N
                ptr_store!(fc, p, CGVal(T, Inline, LeafVal[x.leaves[k]]), const_value(fc, k))
            end
        end
        return ghost(Nothing, nothing)
    end
    unsupported("wasm_simd_", op)
end

## vector loads and stores through pointers without a static origin

# the fused path: one check of the vector's bytes in the owner's typed view, then an array access
# per lane; through the typed helpers per lane otherwise
fused_vector_access(p::CGVal, @nospecialize(T)) =
    p.origin === nothing && ptr_owner(p) isa Int && view_storage(T) !== nothing

# the locals (array, byte offset) and on the stack whether the `nbytes` bytes at the address of
# `p` are in its owner's typed view and aligned to its elements (an i32)
function vector_view_check!(fc::FnCtx, p::CGVal, stg, nbytes::Int)
    arr, base, len = typed_view!(fc, ptr_owner(p)::Int, stg)
    n = storage_bytes(stg)
    boff = new_local!(fc, I64)
    push_leaf!(fc, p.leaves[1])
    emit!(fc.b, :local_get, base); emit!(fc.b, :i64_sub)
    emit!(fc.b, :local_tee, boff)
    emit!(fc.b, :local_get, len); emit!(fc.b, :i64_lt_u)
    emit!(fc.b, :local_get, len); emit!(fc.b, :local_get, boff); emit!(fc.b, :i64_sub)
    emit!(fc.b, :i64_const, nbytes); emit!(fc.b, :i64_ge_u)
    emit!(fc.b, :i32_and)
    emit!(fc.b, :local_get, boff); emit!(fc.b, :i64_const, n - 1); emit!(fc.b, :i64_and); emit!(fc.b, :i64_eqz)
    emit!(fc.b, :i32_and)
    return (arr, boff)
end

# push the array, the index of lane `k` of the vector at byte offset `boff`
function push_lane_elem!(fc::FnCtx, arr::Int, boff::Int, @nospecialize(T), k::Int)
    emit!(fc.b, :local_get, arr)
    emit!(fc.b, :local_get, boff); emit!(fc.b, :i64_const, trailing_zeros(sizeof(T))); emit!(fc.b, :i64_shr_u)
    emit!(fc.b, :i32_wrap_i64)
    k > 0 && (emit!(fc.b, :i32_const, k); emit!(fc.b, :i32_add))
end

# push the address of lane `k` and the owner of `p`
function push_lane_ptr!(fc::FnCtx, p::CGVal, @nospecialize(T), k::Int)
    push_leaf!(fc, p.leaves[1])
    k > 0 && (emit!(fc.b, :i64_const, k * sizeof(T)); emit!(fc.b, :i64_add))
    push_leaf!(fc, ptr_owner(p))
end

# push the v128 of the vector at `p`
function vector_load!(fc::FnCtx, p::CGVal, sh)
    _, N, T, wt = sh
    stg = view_storage(T)
    at = array_type!(fc.cgm.types, stg)
    arr, boff = vector_view_check!(fc, p, stg, N * sizeof(T))
    r = new_local!(fc, V128)
    if!(fc.b)
    for k in 0:N-1
        push_lane_elem!(fc, arr, boff, T, k)
        emit!(fc.b, :array_get, at)
        k == 0 ? simd!(fc, simd_name(sh, :splat)) : simd!(fc, simd_name(sh, :replace_lane), k)
    end
    emit!(fc.b, :local_set, r)
    else!(fc.b)
    for k in 0:N-1
        push_lane_ptr!(fc, p, T, k)
        call!(fc.b, ptr_byte_helper!(fc.cgm, sizeof(T) == 8 ? :load8 : :load4))
        sizeof(T) == 4 && emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, sizeof(T) == 8 ? :f64_reinterpret_i64 : :f32_reinterpret_i32)
        k == 0 ? simd!(fc, simd_name(sh, :splat)) : simd!(fc, simd_name(sh, :replace_lane), k)
    end
    emit!(fc.b, :local_set, r)
    end!(fc.b)
    emit!(fc.b, :local_get, r)
end

# store the lanes of the vector `x` at `p`
function vector_store!(fc::FnCtx, x::CGVal, p::CGVal, sh)
    _, N, T, wt = sh
    stg = view_storage(T)
    at = array_type!(fc.cgm.types, stg)
    arr, boff = vector_view_check!(fc, p, stg, N * sizeof(T))
    if!(fc.b)
    for k in 0:N-1
        push_lane_elem!(fc, arr, boff, T, k)
        push_leaf!(fc, x.leaves[k+1])
        emit!(fc.b, :array_set, at)
    end
    else!(fc.b)
    for k in 0:N-1
        push_lane_ptr!(fc, p, T, k)
        push_leaf!(fc, x.leaves[k+1])
        emit!(fc.b, sizeof(T) == 8 ? :i64_reinterpret_f64 : :i32_reinterpret_f32)
        sizeof(T) == 4 && emit!(fc.b, :i64_extend_i32_u)
        call!(fc.b, ptr_byte_helper!(fc.cgm, sizeof(T) == 8 ? :store8 : :store4))
    end
    end!(fc.b)
end
