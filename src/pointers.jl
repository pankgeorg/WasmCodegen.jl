# Pointers. Wasm has no addresses: a `Ptr` is two leaves, a virtual address and the object
# it points into, its *owner* (a Memory, a String, a Ref), or null for a pointer made from
# an integer, which cannot be dereferenced. Each owner has a range of virtual addresses,
# from its identity hash shifted by 32 bits (`push_memory_base!`), so that comparisons and
# differences of pointers behave as natively; arithmetic changes the address and keeps
# the owner.
#
# A load or store through a pointer is compiled from its origin when it is known
# statically (it was made in the same function): the array of the owner, the byte offset
# into it, and the type of its elements. Otherwise it dispatches on the owner's kind at run
# time (`jl_ptr_load_byte`/`jl_ptr_store_byte`, generated once the module's types are
# known). The memory is addressed by bytes as Julia lays it out, so a pointer may
# reinterpret it (`Ptr{UInt64}` into bytes, bytes of `UInt32`s).

# `Ptr`s, and C strings (pointers by another type)
is_ptr_type(@nospecialize(T)) = T isa DataType && (T.name === Ptr.body.name || T === Cstring || T === Cwstring)

"The address of the pointer `p`, as a UInt64."
ptr_address(p::CGVal) = CGVal(UInt64, Inline, LeafVal[p.leaves[1]], nothing)

"The owner (an object, or null) of the pointer `p`."
ptr_owner(p::CGVal) = p.leaves[2]

"""
    new_ptr!(fc, T, owner, origin) -> CGVal

The pointer of type `T` whose address is on the stack, into `owner` (a leaf).
"""
function new_ptr!(fc::FnCtx, @nospecialize(T), owner::LeafVal, origin::Union{Nothing,PtrOrigin})
    a = new_local!(fc, I64)
    emit!(fc.b, :local_set, a)
    return CGVal(T, Inline, LeafVal[a, owner], nothing, origin)
end

## making pointers

"The pointer to the first element of the Memory `mem` (`mem.ptr`)."
function memory_ptr!(fc::FnCtx, mem::CGVal, @nospecialize(T))
    E = memory_eltype(mem.typ)
    owner = materialize!(fc, mem)
    push_memory_base!(fc, mem)
    push_memory_array!(fc, mem)
    arr = new_local!(fc, RefType(memory_array_type!(fc.cgm.types, E), true))
    emit!(fc.b, :local_set, arr)
    return new_ptr!(fc, T, owner, PtrOrigin(owner, arr, Inst(:i32_const, 0), E))
end

"""
    memoryref_ptr!(fc, r) -> CGVal

The `ptr_or_offset` of the MemoryRef `r`: the index for elements of zero size or unions
(as natively), else a pointer to the element.
"""
function memoryref_ptr!(fc::FnCtx, r::CGVal)
    E = ref_eltype(r.typ)
    sz = elem_unit(E)
    push_leaf!(fc, r.leaves[3])
    emit!(fc.b, :i64_extend_i32_u)
    if !index_ptr(E)
        emit!(fc.b, :i64_const, sz)
        emit!(fc.b, :i64_mul)
        push_memory_base!(fc, CGVal(memory_type(r.typ), Boxed, LeafVal[r.leaves[1]]))
        emit!(fc.b, :i64_add)
    end
    # the byte offset of the element
    off = new_local!(fc, I32)
    push_leaf!(fc, r.leaves[3])
    sz != 1 && (emit!(fc.b, :i32_const, sz); emit!(fc.b, :i32_mul))
    emit!(fc.b, :local_set, off)
    return new_ptr!(fc, Ptr{Cvoid}, r.leaves[1], PtrOrigin(r.leaves[1], r.leaves[2], off, E))
end

# whether the "pointers" to elements of a memory of `E` are their indices (as natively: of
# isbits unions and elements of no size)
index_ptr(@nospecialize(E)) = Base.isbitsunion(E) || Base.aligned_sizeof(E) == 0

# the bytes of an element of a memory of `E` in pointer offsets (1 for `index_ptr` ones)
elem_unit(@nospecialize(E)) = index_ptr(E) ? 1 : Base.aligned_sizeof(E)

"""The pointer to the bytes of the String `s` (`jl_string_ptr`), or of the name of the
Symbol `s` (`jl_symbol_name`, with `S = Symbol`)."""
function string_ptr!(fc::FnCtx, s::CGVal, @nospecialize(T), @nospecialize(S=String))
    s = convert_repr(fc, s, S)
    owner = materialize!(fc, s)
    push_memory_base!(fc, s)
    push_val!(fc, s)
    emit!(fc.b, :struct_get, layout(fc, S).wtype, DATA_FIELD)
    arr = new_local!(fc, RefType(array_type!(fc.cgm.types, I8), true))
    emit!(fc.b, :local_set, arr)
    return new_ptr!(fc, T, owner, PtrOrigin(owner, arr, Inst(:i32_const, 0), UInt8, true))
end

"The pointer to the mutable object `x` (`jl_value_ptr`): to its first field."
function object_ptr!(fc::FnCtx, x::CGVal, @nospecialize(T))
    lx = layout(fc, x.typ)
    (lx.kind === Boxed && ismutabletype(x.typ) && !isempty(lx.fields)) ||
        unsupported("the address of a value of type ", x.typ)
    owner = materialize!(fc, x)
    push_memory_base!(fc, x)
    return new_ptr!(fc, T, owner, PtrOrigin(owner, nothing, nothing, x.typ))
end

"""
The object the pointer `p` points to (`unsafe_pointer_to_objref`): its owner. Traps when `p`
has no owner (it was made from an integer, or lost its owner) or is not at the owner's base
address. As the owner follows the pointer, not its address, a pointer moved by arithmetic from
one object to another (`p + (q - p)` keeps `p`'s owner) traps, where natively it gives the
object at that address. The pointers to the data of a String, a Symbol's name or a Memory have
that base too, so they give the String, Symbol or Memory (natively they do not point to an
object, and the result is undefined).
"""
function pointer_object!(fc::FnCtx, p::CGVal)
    o = new_local!(fc, jlvalue_ref(fc.cgm.types))
    push_leaf!(fc, ptr_owner(p))
    emit!(fc.b, :local_tee, o)
    emit!(fc.b, :ref_is_null)
    if!(fc.b); unreachable!(fc.b); end!(fc.b)
    x = CGVal(Any, Boxed, LeafVal[o])
    push_leaf!(fc, p.leaves[1])
    push_memory_base!(fc, x)
    emit!(fc.b, :i64_ne)
    if!(fc.b); unreachable!(fc.b); end!(fc.b)
    return x
end

"`p + off` (or `p - off`): the same owner, the address moved."
function ptr_offset!(fc::FnCtx, p::CGVal, off::CGVal, add::Bool)
    push_leaf!(fc, p.leaves[1])
    push_val!(fc, off)
    prim_wtype(fc, off.typ) === I32 && emit!(fc.b, :i64_extend_i32_s)
    emit!(fc.b, add ? :i64_add : :i64_sub)
    o = p.origin
    if o !== nothing && !is_object_origin(o)
        b = new_local!(fc, I32)
        push_leaf!(fc, o.index)
        push_val!(fc, off)
        prim_wtype(fc, off.typ) === I64 && emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, add ? :i32_add : :i32_sub)
        emit!(fc.b, :local_set, b)
        o = PtrOrigin(o.mem, o.array, b, o.eltype, o.terminated)
    else
        o = nothing
    end
    return new_ptr!(fc, p.typ, ptr_owner(p), o)
end

"A pointer from an integer: an address without owner."
function int_ptr!(fc::FnCtx, @nospecialize(T), x::CGVal)
    push_val!(fc, x)
    prim_wtype(fc, x.typ) === I32 && emit!(fc.b, :i64_extend_i32_u)
    return new_ptr!(fc, T, Inst(:ref_null, fc.cgm.types.jlvalue), nothing)
end

## loads and stores

"""
    bit_leaves(T) -> Vector{Tuple{Any,Int}}

The leaves of an isbits value of type `T`, in order, as the primitive type each holds and
its byte offset in the value: 128-bit primitives are two `UInt64` leaves, and a pointer is
its address and its owner (`:owner`, which has no bytes).
"""
function bit_leaves(@nospecialize(T), base::Int=0, out=Tuple{Any,Int}[])
    if is_ptr_type(T)
        push!(out, (UInt64, base), (:owner, base))
    elseif isprimitivetype(T) && sizeof(T) == 16
        push!(out, (UInt64, base), (UInt64, base + 8))
    elseif isprimitivetype(T)
        push!(out, (T, base))
    else
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            sizeof(FT) == 0 && continue
            isbitstype(FT) || unsupported("the bytes of a value of type ", T, " with references")
            bit_leaves(FT, base + Int(fieldoffset(T, i)), out)
        end
    end
    return out
end

nbytes(@nospecialize(P)) = P === :owner ? 0 : sizeof(P)

# the leaves of an inline value of the isbits type `T`
function bits_value_leaves(fc::FnCtx, x::CGVal, @nospecialize(T))
    x = convert_repr(fc, x, T)
    bl = bit_leaves(T)
    (x.kind === Inline && length(x.leaves) == length(bl)) ||
        unsupported("the bytes of a value of type ", T)
    return zip(bl, x.leaves)
end

"""
    emit_reinterpret_bits!(fc, Out, x) -> CGVal

The bytes of the isbits value `x` as a value of the isbits type `Out` of the same size
(`Runtime.reinterpret_bits`): its leaves made of the bits of the leaves of `x` they
overlap.
"""
function emit_reinterpret_bits!(fc::FnCtx, @nospecialize(Out), x::CGVal, @nospecialize(In))
    ins = Tuple{Int,Int,Int}[]
    for ((P, off), leaf) in bits_value_leaves(fc, x, In)
        P === :owner && continue
        push!(ins, (off, nbytes(P), leaf_to_bits!(fc, leaf, P)))
    end
    leaves = LeafVal[]
    for (P, off) in bit_leaves(Out)
        if P === :owner
            push!(leaves, Inst(:ref_null, fc.cgm.types.jlvalue))
            continue
        end
        n = nbytes(P)
        acc = new_local!(fc, I64)
        emit!(fc.b, :i64_const, 0)
        for (ioff, isz, bits) in ins
            lo, hi = max(off, ioff), min(off + n, ioff + isz)
            lo < hi || continue
            emit!(fc.b, :local_get, bits)
            lo > ioff && (emit!(fc.b, :i64_const, 8(lo - ioff)); emit!(fc.b, :i64_shr_u))
            hi - lo < 8 && (emit!(fc.b, :i64_const, (Int64(1) << 8(hi - lo)) - 1); emit!(fc.b, :i64_and))
            lo > off && (emit!(fc.b, :i64_const, 8(lo - off)); emit!(fc.b, :i64_shl))
            emit!(fc.b, :i64_or)
        end
        emit!(fc.b, :local_set, acc)
        push!(leaves, bits_to_leaf!(fc, acc, P))
    end
    l = layout(fc, Out)
    (l.kind === Inline && length(l.leaves) == length(leaves)) ||
        unsupported("reinterpreting as a value of type ", Out)
    return CGVal(Out, Inline, leaves)
end

# whether the elements of a memory of `E` are stored as Julia lays them out, so that its
# array is addressable by bytes: primitives, and inline values of primitives of one size
# without padding (a uniform array)
function byte_addressable(ts::Types, @nospecialize(E))
    isprimitivetype(E) && !is_ptr_type(E) && sizeof(E) <= 8 && return true
    isbitstype(E) || return false
    ml = memory_layout(ts, E)
    return !ml.boxed && !ml.widened && ml.storage isa Union{NumType,PackedType} &&
           sum(nbytes(P) for (P, _) in bit_leaves(E); init=0) == sizeof(E)
end
byte_addressable(fc::FnCtx, @nospecialize(E)) = byte_addressable(fc.cgm.types, E)

# the byte size of the storage of the array elements of the memory of `E`
function storage_size(fc::FnCtx, @nospecialize(E))
    st = memory_layout(fc.cgm.types, E).storage
    return st === I8 ? 1 : st === I16 ? 2 : st === I32 || st === F32 ? 4 : 8
end

"""
    ptr_load!(fc, p, i, T) -> CGVal

`unsafe_load(p, i)`: the value of type `T` at the `i`-th element (1-based) from `p`.
"""
function ptr_load!(fc::FnCtx, p::CGVal, i::CGVal, @nospecialize(T))
    o = p.origin
    if o !== nothing && is_object_origin(o) && isconstant(i) && constant_value(i) == 1 &&
       fieldcount(o.eltype) >= 1 && fieldtype(o.eltype, 1) === T
        # the first field of a `Ref`
        return get_field(fc, CGVal(o.eltype, Boxed, LeafVal[o.mem]), 1)
    end
    if o !== nothing && !is_object_origin(o) && T === o.eltype && !byte_addressable(fc, T)
        # a whole element of a memory whose elements are not stored as bytes
        return outlined_memoryrefget!(fc, element_ref!(fc, o, i, T), const_value(fc, false), T)
    end
    isbitstype(T) || unsupported("a load of a ", T, " through a pointer")
    byte = byte_offset!(fc, p, i, T)
    leaves = LeafVal[]
    for (P, off) in bit_leaves(T)
        if P === :owner
            # a pointer loaded from memory: an address without owner
            push!(leaves, Inst(:ref_null, fc.cgm.types.jlvalue))
            continue
        end
        bits = load_bits!(fc, p, byte, off, nbytes(P))
        push!(leaves, bits_to_leaf!(fc, bits, P))
    end
    l = layout(fc, T)
    (l.kind === Inline && length(l.leaves) == length(leaves)) ||
        unsupported("a load of a ", T, " through a pointer")
    return CGVal(T, Inline, leaves)
end

"""
    ptr_store!(fc, p, v, i) -> CGVal

`unsafe_store!(p, v, i)`.
"""
function ptr_store!(fc::FnCtx, p::CGVal, v::CGVal, i::CGVal)
    T = v.typ
    o = p.origin
    if o !== nothing && !is_object_origin(o) && memory_layout(fc.cgm.types, o.eltype).storage isa RefType
        # a memory of references: only clearing (storing a null pointer) is meaningful
        (isconstant(v) && constant_value(v) == C_NULL && !Base.allocatedinline(o.eltype)) ||
            unsupported("storing a ", v.typ, " through a pointer into a memory of ", o.eltype)
        ml = memory_layout(fc.cgm.types, o.eltype)
        push_leaf!(fc, o.array)
        push_leaf!(fc, o.index)
        emit!(fc.b, :i32_const, elem_unit(o.eltype)); emit!(fc.b, :i32_div_u)
        if !(isconstant(i) && constant_value(i) == 1)
            # (the `i`-th pointer: the `i`-th reference)
            push_val!(fc, convert_repr(fc, i, Int)); emit!(fc.b, :i32_wrap_i64)
            emit!(fc.b, :i32_const, 1); emit!(fc.b, :i32_sub); emit!(fc.b, :i32_add)
        end
        emit!(fc.b, :ref_null, (ml.storage::RefType).heap)
        emit!(fc.b, :array_set, ml.array)
        return p
    end
    if o !== nothing && !is_object_origin(o) && T === o.eltype && !byte_addressable(fc, T)
        outlined_memoryrefset!(fc, element_ref!(fc, o, i, T), v, const_value(fc, false))
        return p
    end
    isbitstype(T) || unsupported("a store of a ", T, " through a pointer")
    byte = byte_offset!(fc, p, i, T)
    for ((P, off), leaf) in bits_value_leaves(fc, v, T)
        P === :owner && continue
        bits = leaf_to_bits!(fc, leaf, P)
        store_bits!(fc, p, byte, off, nbytes(P), bits)
    end
    return p
end

# the MemoryRef of the element at the byte offset of the origin, plus `i - 1` elements
function element_ref!(fc::FnCtx, o::PtrOrigin, i::CGVal, @nospecialize(T))
    R = MemoryRef{o.eltype}
    sz = elem_unit(o.eltype)
    idx = new_local!(fc, I32)
    push_leaf!(fc, o.index); emit!(fc.b, :i32_const, sz); emit!(fc.b, :i32_div_u)
    push_val!(fc, convert_repr(fc, i, Int)); emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_add); emit!(fc.b, :i32_const, 1); emit!(fc.b, :i32_sub)
    emit!(fc.b, :local_set, idx)
    mem = something(o.mem, Inst(:ref_null, layout(fc, memory_type(R)).wtype))
    return CGVal(R, Inline, LeafVal[mem, o.array, idx])
end

# the byte offset of the `i`-th T from `p`: into its origin's array (an i32), or for a
# pointer without origin, the address (an i64)
function byte_offset!(fc::FnCtx, p::CGVal, i::CGVal, @nospecialize(T))
    o = p.origin
    # an origin whose elements are not stored as bytes is read through its owner
    static = o !== nothing && !is_object_origin(o) && byte_addressable(fc, o.eltype)
    sz = sizeof(T)
    if static
        r = new_local!(fc, I32)
        push_leaf!(fc, o.index)
        if !(isconstant(i) && constant_value(i) == 1)
            push_val!(fc, convert_repr(fc, i, Int)); emit!(fc.b, :i32_wrap_i64)
            emit!(fc.b, :i32_const, 1); emit!(fc.b, :i32_sub)
            emit!(fc.b, :i32_const, sz); emit!(fc.b, :i32_mul)
            emit!(fc.b, :i32_add)
        end
        emit!(fc.b, :local_set, r)
        return (:static, r)
    end
    r = new_local!(fc, I64)
    push_leaf!(fc, p.leaves[1])
    if !(isconstant(i) && constant_value(i) == 1)
        push_val!(fc, convert_repr(fc, i, Int))
        emit!(fc.b, :i64_const, 1); emit!(fc.b, :i64_sub)
        emit!(fc.b, :i64_const, sz); emit!(fc.b, :i64_mul)
        emit!(fc.b, :i64_add)
    end
    emit!(fc.b, :local_set, r)
    return (:dynamic, r)
end

# the `n` bytes at `byte + off` (little-endian), as an i64 local
function load_bits!(fc::FnCtx, p::CGVal, byte, off::Int, n::Int)
    kind, b = byte
    acc = new_local!(fc, I64)
    if kind === :static
        o = p.origin
        s = storage_size(fc, o.eltype)
        if s == n
            # a whole array element, if aligned to it
            if s > 1
                push_misaligned!(fc, b, off, s)
                if!(fc.b)
                load_static_bytes!(fc, o, b, off, n, s, acc)
                else!(fc.b)
            end
            push_array_elem_bits!(fc, o, b, off, s)
            emit!(fc.b, :local_set, acc)
            s > 1 && end!(fc.b)
        else
            load_static_bytes!(fc, o, b, off, n, s, acc)
        end
        return acc
    end
    view = byte_view!(fc, ptr_owner(p))
    if view !== nothing
        # within the bytes of the owner's view: read from its array
        arr, base, len = view
        boff = new_local!(fc, I64)
        emit!(fc.b, :local_get, b)
        off != 0 && (emit!(fc.b, :i64_const, off); emit!(fc.b, :i64_add))
        emit!(fc.b, :local_get, base); emit!(fc.b, :i64_sub)
        emit!(fc.b, :local_tee, boff)
        emit!(fc.b, :local_get, len); emit!(fc.b, :i64_lt_u)
        if n > 1
            emit!(fc.b, :local_get, len); emit!(fc.b, :local_get, boff); emit!(fc.b, :i64_sub)
            emit!(fc.b, :i64_const, n); emit!(fc.b, :i64_ge_u)
            emit!(fc.b, :i32_and)
        end
        if!(fc.b)
        at = array_type!(fc.cgm.types, I8)
        for j in 0:n-1
            emit!(fc.b, :local_get, arr)
            emit!(fc.b, :local_get, boff); emit!(fc.b, :i32_wrap_i64)
            j > 0 && (emit!(fc.b, :i32_const, j); emit!(fc.b, :i32_add))
            emit!(fc.b, :array_get_u, at)
            emit!(fc.b, :i64_extend_i32_u)
            j > 0 && (emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shl); emit!(fc.b, :i64_or))
        end
        emit!(fc.b, :local_set, acc)
        else!(fc.b)
    end
    # through the owner, at run time, byte by byte
    emit!(fc.b, :i64_const, 0); emit!(fc.b, :local_set, acc)
    loadb = ptr_byte_helper!(fc.cgm, :load)
    for j in 0:n-1
        emit!(fc.b, :local_get, b); emit!(fc.b, :i64_const, off + j); emit!(fc.b, :i64_add)
        push_leaf!(fc, ptr_owner(p))
        call!(fc.b, loadb)
        emit!(fc.b, :i64_extend_i32_u)
        if j > 0
            emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shl)
        end
        emit!(fc.b, :local_get, acc); emit!(fc.b, :i64_or); emit!(fc.b, :local_set, acc)
    end
    view === nothing || end!(fc.b)
    return acc
end

"""
    byte_view!(fc, owner) -> Union{Nothing,NTuple{3,Int}}

The locals `(array, base, len)` of the byte view of the owner leaf `owner` of a pointer
without a static origin: the byte array holding the owner's bytes, the base address of the
owner and the number of bytes in the array, for owners whose bytes are the shared byte array
(Strings, Symbols, and memories whose elements are stored as bytes in it); else a null array
and length 0. They are kept
per owner local and refreshed (`jl_ptr_byte_view`) only when the owner differs from the one
they were made for. `nothing` for a constant owner.
"""
function byte_view!(fc::FnCtx, owner::LeafVal)
    owner isa Int || return nothing
    ts = fc.cgm.types
    cown, arr, base, len = get!(fc.byteviews, owner) do
        (new_local!(fc, jlvalue_ref(ts)), new_local!(fc, RefType(array_type!(ts, I8), true)),
         new_local!(fc, I64), new_local!(fc, I64))
    end
    emit!(fc.b, :local_get, owner); emit!(fc.b, :local_get, cown); emit!(fc.b, :ref_eq)
    emit!(fc.b, :i32_eqz)
    if!(fc.b)
    emit!(fc.b, :local_get, owner)
    call!(fc.b, ptr_byte_helper!(fc.cgm, :view))
    emit!(fc.b, :local_set, len); emit!(fc.b, :local_set, base); emit!(fc.b, :local_set, arr)
    emit!(fc.b, :local_get, owner); emit!(fc.b, :local_set, cown)
    end!(fc.b)
    return (arr, base, len)
end

# push whether the byte offset `b + off` is not a multiple of `s` (an i32)
function push_misaligned!(fc::FnCtx, b::Int, off::Int, s::Int)
    emit!(fc.b, :local_get, b)
    off != 0 && (emit!(fc.b, :i32_const, off); emit!(fc.b, :i32_add))
    emit!(fc.b, :i32_const, s - 1); emit!(fc.b, :i32_and)
end

# load the `n` bytes at `b + off` from the array elements of `s` bytes holding them, into
# the i64 local `acc`
function load_static_bytes!(fc::FnCtx, o::PtrOrigin, b::Int, off::Int, n::Int, s::Int, acc::Int)
    emit!(fc.b, :i64_const, 0); emit!(fc.b, :local_set, acc)
    for j in 0:n-1
        # the byte at b + off + j: of the element (b+off+j) ÷ s, shifted
        push_array_elem_bits!(fc, o, b, off + j, s)
        emit!(fc.b, :local_get, b); emit!(fc.b, :i32_const, off + j); emit!(fc.b, :i32_add)
        emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_rem_u)
        emit!(fc.b, :i32_const, 8); emit!(fc.b, :i32_mul)
        emit!(fc.b, :i64_extend_i32_u)
        emit!(fc.b, :i64_shr_u)
        emit!(fc.b, :i64_const, 0xff); emit!(fc.b, :i64_and)
        if j > 0
            emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shl)
        end
        emit!(fc.b, :local_get, acc); emit!(fc.b, :i64_or); emit!(fc.b, :local_set, acc)
    end
end

# store the `n` low bytes of the i64 local `bits` at `byte + off`
function store_bits!(fc::FnCtx, p::CGVal, byte, off::Int, n::Int, bits::Int)
    kind, b = byte
    if kind === :static
        o = p.origin
        s = storage_size(fc, o.eltype)
        if s == n
            # a whole array element, if aligned to it
            if s > 1
                push_misaligned!(fc, b, off, s)
                if!(fc.b)
                store_static_bytes!(fc, o, b, off, n, s, bits)
                else!(fc.b)
            end
            set_array_elem_bits!(fc, o, b, off, s, bits)
            s > 1 && end!(fc.b)
        else
            store_static_bytes!(fc, o, b, off, n, s, bits)
        end
        return
    end
    storeb = ptr_byte_helper!(fc.cgm, :store)
    for j in 0:n-1
        emit!(fc.b, :local_get, b); emit!(fc.b, :i64_const, off + j); emit!(fc.b, :i64_add)
        push_leaf!(fc, ptr_owner(p))
        emit!(fc.b, :local_get, bits)
        j > 0 && (emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shr_u))
        emit!(fc.b, :i32_wrap_i64)
        call!(fc.b, storeb)
    end
end

# store the `n` low bytes of the i64 local `bits` at `b + off` into the array elements of
# `s` bytes holding them
function store_static_bytes!(fc::FnCtx, o::PtrOrigin, b::Int, off::Int, n::Int, s::Int, bits::Int)
    if s == 1
        for j in 0:n-1
            part = new_local!(fc, I64)
            emit!(fc.b, :local_get, bits)
            j > 0 && (emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shr_u))
            emit!(fc.b, :local_set, part)
            set_array_elem_bits!(fc, o, b, off + j, 1, part)
        end
        return
    end
    for j in 0:n-1
        # read-modify-write the element holding the byte
        cur = new_local!(fc, I64)
        push_array_elem_bits!(fc, o, b, off + j, s)
        emit!(fc.b, :local_set, cur)
        sh = new_local!(fc, I64)
        emit!(fc.b, :local_get, b); emit!(fc.b, :i32_const, off + j); emit!(fc.b, :i32_add)
        emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_rem_u)
        emit!(fc.b, :i32_const, 8); emit!(fc.b, :i32_mul)
        emit!(fc.b, :i64_extend_i32_u); emit!(fc.b, :local_set, sh)
        emit!(fc.b, :local_get, cur)
        emit!(fc.b, :i64_const, 0xff); emit!(fc.b, :local_get, sh); emit!(fc.b, :i64_shl)
        emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_xor); emit!(fc.b, :i64_and)
        emit!(fc.b, :local_get, bits)
        j > 0 && (emit!(fc.b, :i64_const, 8j); emit!(fc.b, :i64_shr_u))
        emit!(fc.b, :i64_const, 0xff); emit!(fc.b, :i64_and)
        emit!(fc.b, :local_get, sh); emit!(fc.b, :i64_shl)
        emit!(fc.b, :i64_or)
        emit!(fc.b, :local_set, cur)
        set_array_elem_bits!(fc, o, b, off + j, s, cur)
    end
end

# push the array and index of the array element of `s` bytes holding the byte `b + off`
function push_elem_address!(fc::FnCtx, o::PtrOrigin, b::Int, off::Int, s::Int)
    push_leaf!(fc, o.array)
    emit!(fc.b, :local_get, b)
    off != 0 && (emit!(fc.b, :i32_const, off); emit!(fc.b, :i32_add))
    emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_div_u)
end

# push the bits of an array element, zero-extended to i64
function push_array_elem_bits!(fc::FnCtx, o::PtrOrigin, b::Int, off::Int, s::Int)
    ml = memory_layout(fc.cgm.types, o.eltype)
    if o.terminated
        # the byte past a string's end: its NUL
        emit!(fc.b, :local_get, b)
        off != 0 && (emit!(fc.b, :i32_const, off); emit!(fc.b, :i32_add))
        emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_div_u)
        push_leaf!(fc, o.array); emit!(fc.b, :array_len)
        emit!(fc.b, :i32_eq)
        if!(fc.b, I64)
        emit!(fc.b, :i64_const, 0)
        else!(fc.b)
    end
    push_elem_address!(fc, o, b, off, s)
    st = ml.storage
    emit!(fc.b, st isa PackedType ? :array_get_u : :array_get, ml.array)
    st === F64 && emit!(fc.b, :i64_reinterpret_f64)
    st === F32 && emit!(fc.b, :i32_reinterpret_f32)
    (st === I32 || st === F32 || st isa PackedType) && emit!(fc.b, :i64_extend_i32_u)
    o.terminated && end!(fc.b)
end

# set an array element from the bits of the i64 local `bits`
function set_array_elem_bits!(fc::FnCtx, o::PtrOrigin, b::Int, off::Int, s::Int, bits::Int)
    ml = memory_layout(fc.cgm.types, o.eltype)
    push_elem_address!(fc, o, b, off, s)
    emit!(fc.b, :local_get, bits)
    st = ml.storage
    (st === I32 || st === F32 || st isa PackedType) && emit!(fc.b, :i32_wrap_i64)
    st === F64 && emit!(fc.b, :f64_reinterpret_i64)
    st === F32 && emit!(fc.b, :f32_reinterpret_i32)
    emit!(fc.b, :array_set, ml.array)
end

# a primitive leaf of type P from the bits in the i64 local `bits`
function bits_to_leaf!(fc::FnCtx, bits::Int, @nospecialize(P))
    t = prim_wtype(fc, P)
    emit!(fc.b, :local_get, bits)
    if t === I32 || t === F32
        emit!(fc.b, :i32_wrap_i64)
        t === F32 && emit!(fc.b, :f32_reinterpret_i32)
    elseif t === F64
        emit!(fc.b, :f64_reinterpret_i64)
    end
    r = new_local!(fc, t)
    emit!(fc.b, :local_set, r)
    return r
end

# the bits of a primitive leaf of type P, in an i64 local
function leaf_to_bits!(fc::FnCtx, leaf::LeafVal, @nospecialize(P))
    t = prim_wtype(fc, P)
    push_leaf!(fc, leaf)
    t === F64 && emit!(fc.b, :i64_reinterpret_f64)
    t === F32 && emit!(fc.b, :i32_reinterpret_f32)
    (t === I32 || t === F32) && emit!(fc.b, :i64_extend_i32_u)
    r = new_local!(fc, I64)
    emit!(fc.b, :local_set, r)
    return r
end

## the run-time helpers

"""
    ptr_byte_helper!(cgm, kind) -> Func

`jl_ptr_load_byte(address, owner) -> i32` or `jl_ptr_store_byte(address, owner, byte)`:
a byte of the memory a pointer without a static origin points into, found from its
owner's kind at run time; or `jl_ptr_byte_view(owner) -> (array, base, len)`, the byte view
of an owner (`byte_view!`). Their bodies are generated with the module's types
(`finish_pointers!`).
"""
function ptr_byte_helper!(cgm::CGModule, kind::Symbol)
    get!(cgm.helpers, (:ptr, kind)) do
        jl = jlvalue_ref(cgm.types)
        kind === :load ? add_func!(cgm.mod, "jl_ptr_load_byte", ValType[I64, jl], ValType[I32]) :
        kind === :store ? add_func!(cgm.mod, "jl_ptr_store_byte", ValType[I64, jl, I32], ValType[]) :
        add_func!(cgm.mod, "jl_ptr_byte_view", ValType[jl],
                  ValType[RefType(array_type!(cgm.types, I8), true), I64, I64])
    end
end

# the owners whose bytes are addressable, by the Wasm types of their objects (object struct
# type, array type, element storage) => their type ids: memories whose elements are stored
# as Julia lays them out, strings and symbols
function byte_owners(cgm::CGModule)
    ts = cgm.types
    owners = Dict{Tuple{TypeRef,TypeRef,StorageType},Vector{Int32}}()
    for (id, T) in enumerate(copy(ts.typelist))
        if T === String || T === Symbol
            key = (bytes_object_type!(ts, T), array_type!(ts, I8), I8)
        elseif is_memory_type(T) && byte_addressable(ts, memory_eltype(T))
            ml = memory_layout(ts, memory_eltype(T))
            key = (memory_struct_type!(ts, memory_eltype(T)), ml.array, ml.storage)
        else
            continue
        end
        push!(get!(Vector{Int32}, owners, key), Int32(id))
    end
    return owners
end

"""
    ObjectLeaf

A leaf of the isbits fields of a mutable object, `n` bytes at byte offset `off` of the
object: its value is reached from the object by `steps`, (struct type, 0-based field)
pairs, each but the first applied to the reference the previous one read (cast to its
struct type), and has storage `storage`. A field of more than `MAX_INLINE_LEAVES` leaves is
one reference: to a boxed immutable value (more steps) or to a large tuple's array
(`elem` = (array type, element size): the byte's element is found at run time). With
`steps === nothing` its bytes are not addressable (a pointer access traps).
"""
struct ObjectLeaf
    steps::Union{Nothing,Vector{Tuple{TypeRef,Int}}}
    storage::StorageType
    off::Int
    n::Int
    elem::Union{Nothing,Tuple{TypeRef,Int}}
end

# the leaves of a value of the isbits type `FT` at byte offset `off`, stored in the Wasm
# fields `ws` (1-based) of the struct type `st` reached by `steps`
function object_leaves!(out::Vector{ObjectLeaf}, ts::Types, @nospecialize(FT), off::Int,
                        st::TypeRef, ws, steps::Vector{Tuple{TypeRef,Int}})
    fields = (typedef(ts.mod, st).comp::StructType).fields
    l = layout(ts, FT)
    if l.kind === Ghost || l.kind === Bottom
        return out
    elseif l.kind === Inline && (isprimitivetype(FT) || is_ptr_type(FT))
        bl = bit_leaves(FT, off)
        length(bl) == length(ws) || return push!(out, ObjectLeaf(nothing, I8, off, sizeof(FT), nothing))
        for ((P, poff), w) in zip(bl, ws)
            P === :owner && continue
            push!(out, ObjectLeaf([steps; (st, w - 1)], fields[w].storage, poff, nbytes(P), nothing))
        end
    elseif l.kind === Inline
        for j in 1:fieldcount(FT)
            FTj = fieldtype(FT, j)
            sizeof(FTj) == 0 && continue
            object_leaves!(out, ts, FTj, off + Int(fieldoffset(FT, j)), st, ws[l.fields[j]], steps)
        end
    elseif l.kind === Boxed && length(ws) == 1
        # a large immutable value: a reference to its box, or to its tuple's array
        inner = [steps; (st, only(ws) - 1)]
        if l.elements !== nothing
            ml = l.elements
            E = fieldtype(FT, 1)
            if isprimitivetype(E) && !ml.boxed && ml.storage isa Union{NumType,PackedType} &&
               storage_bytes(ml.storage) >= sizeof(E) && !(E <: Ptr)
                push!(out, ObjectLeaf([inner; (l.wtype, HEADER_FIELDS)], ml.storage, off,
                                      sizeof(FT), (ml.array, sizeof(E))))
            else
                push!(out, ObjectLeaf(nothing, I8, off, sizeof(FT), nothing))
            end
        else
            for j in 1:fieldcount(FT)
                FTj = fieldtype(FT, j)
                sizeof(FTj) == 0 && continue
                object_leaves!(out, ts, FTj, off + Int(fieldoffset(FT, j)), l.wtype, l.fields[j], inner)
            end
        end
    else
        push!(out, ObjectLeaf(nothing, I8, off, sizeof(FT), nothing))
    end
    return out
end

# the mutable objects whose bytes are addressable (a `Ref` a pointer was taken to), by
# type id: their Wasm struct type and the leaves of their isbits fields
function object_owners(cgm::CGModule)
    ts = cgm.types
    owners = Tuple{Int32,TypeRef,Vector{ObjectLeaf}}[]
    for (id, T) in enumerate(copy(ts.typelist))
        (T isa DataType && isconcretetype(T) && ismutabletype(T) && !is_memory_type(T) &&
         !(T <: Task) && !any(R -> T === R, RUNTIME_TYPES)) || continue
        l = layout(ts, T)
        l.kind === Boxed || continue
        leaves = ObjectLeaf[]
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            off = Int(fieldoffset(T, i))
            if isbitstype(FT) && sizeof(FT) > 0
                object_leaves!(leaves, ts, FT, off, l.wtype, l.fields[i], Tuple{TypeRef,Int}[])
            elseif Base.allocatedinline(FT)
                # stored inline but not as isbits leaves (a union of isbits types and its
                # selector byte, a struct holding references): its bytes are not addressable
                n = (i < fieldcount(T) ? Int(fieldoffset(T, i + 1)) : sizeof(T)) - off
                n > 0 && push!(leaves, ObjectLeaf(nothing, I8, off, n, nothing))
            end
        end
        isempty(leaves) || push!(owners, (Int32(id), l.wtype, leaves))
    end
    return owners
end

# the memories of isbits elements not stored as bytes (widened, padded), by type id: their
# Wasm struct and array types, element storage, element size and stride, and the leaves of
# an element as (index among its array elements, byte offset, byte size)
function leaf_memory_owners(cgm::CGModule)
    ts = cgm.types
    owners = Tuple{Int32,TypeRef,TypeRef,StorageType,Int,Int,Vector{Tuple{Int,Int,Int}}}[]
    for (id, T) in enumerate(copy(ts.typelist))
        is_memory_type(T) || continue
        E = memory_eltype(T)
        (isbitstype(E) && sizeof(E) > 0 && !byte_addressable(ts, E)) || continue
        ml = memory_layout(ts, E)
        (ml.boxed || !(ml.storage isa Union{NumType,PackedType})) && continue
        leaves = Tuple{Int,Int,Int}[]
        for (j, (P, off)) in enumerate(bit_leaves(E))
            P === :owner || push!(leaves, (j - 1, off, nbytes(P)))
        end
        push!(owners, (Int32(id), memory_struct_type!(ts, E), ml.array, ml.storage,
                       Base.aligned_sizeof(E), ml.stride, leaves))
    end
    return owners
end

storage_bytes(st::StorageType) = st === I8 ? 1 : st === I16 ? 2 : st === I32 || st === F32 ? 4 : 8

# convert the value of storage `st` on the stack (as read) to its bits as an i64, or back
function storage_to_bits!(b::Builder, st::StorageType)
    st === F64 && emit!(b, :i64_reinterpret_f64)
    st === F32 && emit!(b, :i32_reinterpret_f32)
    (st === I32 || st === F32 || st isa PackedType) && emit!(b, :i64_extend_i32_u)
end
function bits_to_storage!(b::Builder, st::StorageType)
    (st === I32 || st === F32 || st isa PackedType) && emit!(b, :i32_wrap_i64)
    st === F64 && emit!(b, :f64_reinterpret_i64)
    st === F32 && emit!(b, :f32_reinterpret_i32)
end

# with the bits of a value of `n` bytes on the stack (an i64) and the byte offset `boff`
# into it (an i64 local): the bits with that byte replaced by the byte in local 2
function replace_byte!(b::Builder, boff::Int)
    emit!(b, :i64_const, 0xff); emit!(b, :local_get, boff); emit!(b, :i64_const, 8); emit!(b, :i64_mul)
    emit!(b, :i64_shl)
    emit!(b, :i64_const, -1); emit!(b, :i64_xor); emit!(b, :i64_and)
    emit!(b, :local_get, 2); emit!(b, :i64_extend_i32_u)
    emit!(b, :i64_const, 0xff); emit!(b, :i64_and)
    emit!(b, :local_get, boff); emit!(b, :i64_const, 8); emit!(b, :i64_mul)
    emit!(b, :i64_shl)
    emit!(b, :i64_or)
end

# push the value a leaf's steps reach from the object in the local `obj` (the last read
# as storage `stg` when it is the leaf's value)
function push_leaf_steps!(b::Builder, obj::Int, steps, stg::Union{Nothing,StorageType})
    emit!(b, :local_get, obj)
    for (k, (sst, w)) in enumerate(steps)
        k > 1 && emit!(b, :ref_cast, sst)
        emit!(b, k == length(steps) && stg isa PackedType ? :struct_get_u : :struct_get, sst, w)
    end
end

# the byte at offset `off` of a mutable object of struct type `st` (local 1), among its
# isbits leaves; a padding byte reads as zero. A byte of a large immutable field (in a box
# or a tuple's array, which other values may share) is read there; storing into it, or
# accessing a byte whose field isn't addressable, traps
function object_byte_access!(b::Builder, f::Func, kind::Symbol, off::Int, boff::Int,
                             st::TypeRef, leaves::Vector{ObjectLeaf}, objs::Dict{TypeRef,Int})
    obj = get!(() -> add_local!(f, RefType(st, true)), objs, st)
    emit!(b, :local_get, 1); emit!(b, :ref_cast, st); emit!(b, :local_set, obj)
    for lf in leaves
        stg = lf.storage
        # the byte offset into the leaf, if within it
        emit!(b, :local_get, off); emit!(b, :i64_const, lf.off); emit!(b, :i64_sub)
        emit!(b, :local_set, boff)
        emit!(b, :local_get, boff); emit!(b, :i64_const, lf.n); emit!(b, :i64_lt_u)
        if!(b)
        if lf.steps === nothing || (kind === :store && (length(lf.steps) > 1 || lf.elem !== nothing))
            unreachable!(b)
        elseif kind === :load && lf.elem !== nothing
            at, s = lf.elem
            push_leaf_steps!(b, obj, lf.steps, nothing)
            emit!(b, :ref_cast, at)
            emit!(b, :local_get, boff)
            s != 1 && (emit!(b, :i64_const, s); emit!(b, :i64_div_u))
            emit!(b, :i32_wrap_i64)
            get_elem_bits!(b, at, stg)
            push_byte_shift!(b, boff, s)
            emit!(b, :i64_shr_u)
            emit!(b, :i32_wrap_i64); emit!(b, :i32_const, 0xff); emit!(b, :i32_and)
        elseif kind === :load
            push_leaf_steps!(b, obj, lf.steps, stg)
            storage_to_bits!(b, stg)
            emit!(b, :local_get, boff); emit!(b, :i64_const, 8); emit!(b, :i64_mul)
            emit!(b, :i64_shr_u)
            emit!(b, :i32_wrap_i64); emit!(b, :i32_const, 0xff); emit!(b, :i32_and)
        else
            sst, w = only(lf.steps)
            emit!(b, :local_get, obj)
            emit!(b, :local_get, obj)
            emit!(b, stg isa PackedType ? :struct_get_u : :struct_get, sst, w)
            storage_to_bits!(b, stg)
            replace_byte!(b, boff)
            bits_to_storage!(b, stg)
            emit!(b, :struct_set, sst, w)
        end
        lf.steps === nothing || (kind === :store && (length(lf.steps) > 1 || lf.elem !== nothing)) || return!(b)
        end!(b)
    end
    kind === :load && emit!(b, :i32_const, 0)
    return!(b)
end

# push the index of the array element (in the local `a`) holding the byte at offset `off`
function push_byte_elem!(b::Builder, a::Int, off::Int, s::Int)
    emit!(b, :local_get, a)
    emit!(b, :local_get, off)
    s != 1 && (emit!(b, :i64_const, s); emit!(b, :i64_div_u))
    emit!(b, :i32_wrap_i64)
end

# push the shift of the byte at offset `off` in its element (an i64)
function push_byte_shift!(b::Builder, off::Int, s::Int)
    emit!(b, :local_get, off)
    emit!(b, :i64_const, s); emit!(b, :i64_rem_u)
    emit!(b, :i64_const, 8); emit!(b, :i64_mul)
end

# push the bits of the array element on the stack (array, index), as an i64
function get_elem_bits!(b::Builder, at::TypeRef, st::StorageType)
    emit!(b, st isa PackedType ? :array_get_u : :array_get, at)
    storage_to_bits!(b, st)
end

# the body of `jl_ptr_byte_view`: of the owners whose bytes are an array of bytes, the array,
# the base address and the array's length; of others, a null array and length 0
function finish_byte_view!(cgm::CGModule, f::Func, owners)
    ts = cgm.types
    at = array_type!(ts, I8)
    b = Builder(cgm.mod, f)
    tid = add_local!(f, I32)
    arr = add_local!(f, RefType(at, true))
    emit!(b, :local_get, 0); emit!(b, :ref_is_null)
    if!(b); emit!(b, :ref_null, at); emit!(b, :i64_const, 0); emit!(b, :i64_const, 0); return!(b); end!(b)
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
    for ((st, a, stg), ids) in owners
        (a == at && stg === I8) || continue
        for (k, id) in enumerate(ids)
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            k > 1 && emit!(b, :i32_or)
        end
        if!(b)
        emit!(b, :local_get, 0); emit!(b, :ref_cast, st)
        emit!(b, :struct_get, st, DATA_FIELD)
        emit!(b, :local_tee, arr)
        emit!(b, :local_get, 0); call!(b, object_hash_func!(cgm))
        emit!(b, :i64_extend_i32_u); emit!(b, :i64_const, 32); emit!(b, :i64_shl)
        emit!(b, :local_get, arr); emit!(b, :array_len); emit!(b, :i64_extend_i32_u)
        return!(b)
        end!(b)
    end
    emit!(b, :ref_null, at); emit!(b, :i64_const, 0); emit!(b, :i64_const, 0)
    finish!(b)
end

function finish_pointers!(cgm::CGModule)
    owners = objects = leafmems = nothing
    view = get(cgm.helpers, (:ptr, :view), nothing)
    view === nothing || finish_byte_view!(cgm, view, byte_owners(cgm))
    for kind in (:load, :store)
        f = get(cgm.helpers, (:ptr, kind), nothing)
        f === nothing && continue
        if owners === nothing
            owners, objects, leafmems = byte_owners(cgm), object_owners(cgm), leaf_memory_owners(cgm)
        end
        b = Builder(cgm.mod, f)
        off = add_local!(f, I64)
        tid = add_local!(f, I32)
        boff = add_local!(f, I64)
        arrays = Dict{TypeRef,Int}()
        # a pointer without owner cannot be dereferenced
        emit!(b, :local_get, 1); emit!(b, :ref_is_null)
        if!(b); unreachable!(b); end!(b)
        # the offset into the owner: the address minus its base
        emit!(b, :local_get, 0)
        emit!(b, :local_get, 1)
        call!(b, object_hash_func!(cgm))
        emit!(b, :i64_extend_i32_u); emit!(b, :i64_const, 32); emit!(b, :i64_shl)
        emit!(b, :i64_sub)
        emit!(b, :local_set, off)
        emit!(b, :local_get, 1); emit!(b, :struct_get, cgm.types.jlvalue, 0)
        emit!(b, :local_set, tid)
        for ((st, at, stg), ids) in owners
            s = storage_bytes(stg)
            a = get!(() -> add_local!(f, RefType(at, true)), arrays, at)
            for (k, id) in enumerate(ids)
                emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
                k > 1 && emit!(b, :i32_or)
            end
            if!(b)
            emit!(b, :local_get, 1); emit!(b, :ref_cast, st)
            emit!(b, :struct_get, st, DATA_FIELD)
            emit!(b, :local_set, a)
            if kind === :load
                if any(id -> cgm.types.typelist[id] === String || cgm.types.typelist[id] === Symbol, ids)
                    # the byte past the end of a string or symbol: its NUL terminator
                    emit!(b, :local_get, off)
                    emit!(b, :local_get, a); emit!(b, :array_len); emit!(b, :i64_extend_i32_u)
                    emit!(b, :i64_eq)
                    if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
                end
                push_byte_elem!(b, a, off, s)
                get_elem_bits!(b, at, stg)
                push_byte_shift!(b, off, s); emit!(b, :i64_shr_u)
                emit!(b, :i32_wrap_i64); emit!(b, :i32_const, 0xff); emit!(b, :i32_and)
            else
                push_byte_elem!(b, a, off, s)
                push_byte_elem!(b, a, off, s)
                get_elem_bits!(b, at, stg)
                emit!(b, :local_get, off); emit!(b, :i64_const, s); emit!(b, :i64_rem_u)
                emit!(b, :local_set, boff)
                replace_byte!(b, boff)
                bits_to_storage!(b, stg)
                emit!(b, :array_set, at)
            end
            return!(b)
            end!(b)
        end
        idx = add_local!(f, I64)
        for (id, st, at, stg, esz, stride, leaves) in leafmems
            a = get!(() -> add_local!(f, RefType(at, true)), arrays, at)
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b)
            emit!(b, :local_get, 1); emit!(b, :ref_cast, st)
            emit!(b, :struct_get, st, DATA_FIELD)
            emit!(b, :local_set, a)
            # the first array element of the element at the offset
            emit!(b, :local_get, off); emit!(b, :i64_const, esz); emit!(b, :i64_div_u)
            emit!(b, :i64_const, stride); emit!(b, :i64_mul)
            emit!(b, :local_set, idx)
            for (j, loff, n) in leaves
                emit!(b, :local_get, off); emit!(b, :i64_const, esz); emit!(b, :i64_rem_u)
                emit!(b, :i64_const, loff); emit!(b, :i64_sub)
                emit!(b, :local_set, boff)
                emit!(b, :local_get, boff); emit!(b, :i64_const, n); emit!(b, :i64_lt_u)
                if!(b)
                push_elem() = (emit!(b, :local_get, a); emit!(b, :local_get, idx);
                               emit!(b, :i64_const, j); emit!(b, :i64_add); emit!(b, :i32_wrap_i64))
                if kind === :load
                    push_elem(); get_elem_bits!(b, at, stg)
                    emit!(b, :local_get, boff); emit!(b, :i64_const, 8); emit!(b, :i64_mul)
                    emit!(b, :i64_shr_u)
                    emit!(b, :i32_wrap_i64); emit!(b, :i32_const, 0xff); emit!(b, :i32_and)
                else
                    push_elem(); push_elem(); get_elem_bits!(b, at, stg)
                    replace_byte!(b, boff)
                    bits_to_storage!(b, stg)
                    emit!(b, :array_set, at)
                end
                return!(b)
                end!(b)
            end
            # padding
            kind === :load && emit!(b, :i32_const, 0)
            return!(b)
            end!(b)
        end
        objs = Dict{TypeRef,Int}()
        for (id, st, leaves) in objects
            emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
            if!(b)
            object_byte_access!(b, f, kind, off, boff, st, leaves, objs)
            end!(b)
        end
        # an owner whose bytes are not addressable (a Ref, a memory of references or of
        # elements stored otherwise than as Julia lays them out)
        unreachable!(b)
        finish!(b)
    end
end
