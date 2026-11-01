# Copies and fills of bytes through pointers whose origin the code generator does not know
# (see `pointers.jl`): its loads and stores of bytes find the memory from the pointer's
# owner at run time.

"`memmove(dst, src, n)`: the `n` bytes at `src` copied to `dst`, which may overlap."
function ptr_memmove(dst::Ptr{UInt8}, src::Ptr{UInt8}, n::UInt)
    if dst > src
        i = n
        while i > 0
            unsafe_store!(dst, unsafe_load(src, i), i)
            i -= 1
        end
    else
        i = UInt(1)
        while i <= n
            unsafe_store!(dst, unsafe_load(src, i), i)
            i += 1
        end
    end
    return dst
end

"`memset(p, b, n)`: the `n` bytes at `p` set to `b`."
function ptr_memset(p::Ptr{UInt8}, b::UInt8, n::UInt)
    i = UInt(1)
    while i <= n
        unsafe_store!(p, b, i)
        i += 1
    end
    return p
end

"`memcmp(a, b, n)`: the sign of the first difference of the `n` bytes at `a` and `b`."
function ptr_memcmp(a::Ptr{UInt8}, b::Ptr{UInt8}, n::UInt)
    i = UInt(1)
    while i <= n
        x, y = unsafe_load(a, i), unsafe_load(b, i)
        x == y || return x < y ? Int32(-1) : Int32(1)
        i += 1
    end
    return Int32(0)
end

"`memchr(p, c, n)`: the first of the `n` bytes at `p` equal to `c`, or a null pointer."
function ptr_memchr(p::Ptr{UInt8}, c::Int32, n::UInt)
    b = c % UInt8
    i = UInt(1)
    while i <= n
        unsafe_load(p, i) == b && return p + (i - 1)
        i += 1
    end
    return Ptr{UInt8}(0)
end

"`strlen(p)`: the number of bytes at `p` before a NUL."
function ptr_strlen(p::Ptr{UInt8})
    n = UInt(0)
    while unsafe_load(p, n + 1) != 0x00
        n += 1
    end
    return n
end

ptr_strlen(p::Cstring) = ptr_strlen(convert(Ptr{UInt8}, p))

"`jl_cstr_to_string(p)`: a String of the bytes at `p` before a NUL."
cstr_to_string(p::Ptr{UInt8}) = unsafe_string(p, ptr_strlen(p))
cstr_to_string(p::Cstring) = cstr_to_string(convert(Ptr{UInt8}, p))

"""
    unset_element!(r::MemoryRef)

Makes the element `r` refers to undefined, as Base's `_unsetindex!` does to an element
stored inline that holds references (by storing null pointers over it). A primitive of the
code generator: the element's box, or each of its reference leaves, becomes null (Wasm has
no pointers into it); natively, Base's stores. Only for such elements (`trim/wasm-memory.jl`).
"""
@noinline function unset_element!(r::MemoryRef{T}) where {T}
    mem = r.mem
    t = Base.@_gc_preserve_begin mem
    p = Ptr{Ptr{Cvoid}}(pointer(r))
    for j = 1:Core.sizeof(Ptr{Cvoid}):Base.datatype_layoutsize(typeof(mem))
        Core.Intrinsics.atomic_pointerset(p + j - 1, C_NULL, :monotonic)
    end
    Base.@_gc_preserve_end t
    return nothing
end

"""
The value of type `S`, stored inline, that a `cfunction` argument of type `Ref{S}` refers to:
the pointer `p`, whose owner is `o`, into a `Ref` of it, or to its bytes when it has no references.
"""
function c_ref_value(::Type{S}, p::Ptr{Cvoid}, @nospecialize(o)) where {S}
    o isa Base.RefValue{S} && return o.x
    isbitstype(S) && return unsafe_load(Ptr{S}(p))
    throw(ArgumentError("a cfunction argument of type Ref{$S} that is not a pointer to a Ref of it"))
end
