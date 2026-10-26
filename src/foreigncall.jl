# Foreign calls: the few calls into Julia's C runtime that Base's code makes for things
# Wasm does natively (allocation, strings as bytes, copies of memory). Others are
# unsupported; calls into C libraries need runtime functions or host imports.

function foreigncall_name(@nospecialize(x))
    x isa QuoteNode && (x = x.value)
    x isa Symbol && return x
    x isa Tuple && return x[1] isa Symbol ? x[1] : nothing
    # a constant naming the function (`Base.memhash` in Julia 1.12)
    x isa GlobalRef && isconst(x.mod, x.name) && return foreigncall_name(getglobal(x.mod, x.name))
    if x isa Expr && x.head === :call && length(x.args) >= 2
        return foreigncall_name(x.args[2])
    elseif x isa Expr && x.head === :tuple && !isempty(x.args)
        # (name, library) (Julia 1.13)
        return foreigncall_name(x.args[1])
    end
    return nothing
end

function emit_foreigncall!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    name = foreigncall_name(ex.args[1])
    nargs = length(ex.args[3]::Core.SimpleVector)
    args = Any[operand(fc, a) for a in ex.args[6:5+nargs]]
    if name === nothing && is_llvmcall(ex.args[5])
        iname = llvm_intrinsic_name(ex.args[1])
        iname === nothing || return emit_llvm_intrinsic!(fc, iname, args, typ)
    end
    name === nothing && !is_llvmcall(ex.args[5]) && fc.cgm.config.funcref_wrappers &&
        return emit_indirect_ccall!(fc, ex, typ)
    if name === :jl_alloc_genericmemory
        M = args[1]::CGVal
        isconstant(M) || unsupported("allocating a Memory of a type not known at compile time")
        return outlined_memorynew!(fc, constant_value(M), args[2])
    elseif name === :jl_alloc_string
        n = convert_repr(fc, args[1], Int)
        push_val!(fc, n)
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_new_default, array_type!(fc.cgm.types, I8))
        return new_bytes_object!(fc, String)
    elseif name === :jl_string_to_genericmemory
        # a Memory sharing the bytes of the string
        s = args[1]::CGVal
        push_val!(fc, s)
        emit!(fc.b, :struct_get, layout(fc, String).wtype, DATA_FIELD)
        return new_memory_object!(fc, Memory{UInt8})
    elseif name === :jl_genericmemory_to_string
        mem, n = args[1]::CGVal, convert_repr(fc, args[2], Int)
        arr = array_type!(fc.cgm.types, I8)
        dst = new_local!(fc, RefType(arr, true))
        push_val!(fc, n)
        emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_new_default, arr)
        emit!(fc.b, :local_set, dst)
        emit!(fc.b, :local_get, dst); emit!(fc.b, :i32_const, 0)
        push_memory_array!(fc, mem); emit!(fc.b, :i32_const, 0)
        push_val!(fc, n); emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :array_copy, arr, arr)
        emit!(fc.b, :local_get, dst)
        return new_bytes_object!(fc, String)
    elseif name === :jl_symbol_n
        # not interned: symbols are === by their bytes (see `egal_bytes!`)
        return bytes_from_ptr!(fc, args[1], args[2], Symbol)
    elseif name === :jl_pchar_to_string
        return bytes_from_ptr!(fc, args[1], args[2], String)
    elseif name === :jl_object_id
        return emit_objectid!(fc, args[1]::CGVal)
    elseif name === :memchr
        return call_runtime!(fc, Runtime.ptr_memchr, CGVal[byte_ptr(args[1]), convert_repr(fc, args[2], Int32),
                                                            convert_repr(fc, args[3], UInt)])
    elseif name === :memcmp
        return call_runtime!(fc, Runtime.ptr_memcmp, CGVal[byte_ptr(args[1]), byte_ptr(args[2]),
                                                            convert_repr(fc, args[3], UInt)])
    elseif name === :memmove || name === :memcpy
        return emit_memmove!(fc, args[1], args[2], args[3], true)
    elseif name === :jl_genericmemory_copyto
        # (dest memory, dest pointer, src memory, src pointer, n elements)
        emit_memmove!(fc, args[2], args[4], args[5], false)
        return ghost(Nothing, nothing)
    elseif name === :memset
        return emit_memset!(fc, args[1], args[2], args[3])
    elseif name === :jl_get_current_task
        # one task: the module's (its RNG state seeded by the host at start)
        emit!(fc.b, :global_get, current_task_global!(fc.cgm))
        return pop_val!(fc, Task)
    elseif name === :jl_genericmemory_owner
        # a Memory owns itself here (none shares a String's storage as its owner)
        return convert_repr(fc, args[1]::CGVal, typ)
    elseif name === :jl_string_ptr
        return string_ptr!(fc, args[1]::CGVal, typ)
    elseif name === :jl_symbol_name
        return string_ptr!(fc, args[1]::CGVal, typ, Symbol)
    elseif name === :jl_value_ptr
        x = args[1]::CGVal
        if is_ptr_type(x.typ) && fc.cgm.config.funcref_wrappers
            # `unsafe_pointer_to_objref`: the object the pointer points into, its owner
            return CGVal(Any, Boxed, LeafVal[ptr_owner(x)])
        end
        return object_ptr!(fc, x, typ)
    elseif name === :jl_new_structv
        return new_structv!(fc, args[1]::CGVal, args[2]::CGVal)
    elseif name === :jl_new_struct_uninit
        T = args[1]::CGVal
        (isconstant(T) && constant_value(T) isa DataType) ||
            unsupported("a new object of a type not known at compile time")
        return convert_repr(fc, emit_new!(fc, constant_value(T), CGVal[]), Any)
    elseif name in (:jl_gc_disable_finalizers_internal, :jl_gc_enable_finalizers_internal,
                    :jl_cpu_suspend, :jl_cpu_pause, :jl_cpu_wake, :jl_gc_safepoint,
                    :jl_gc_run_pending_finalizers, :jl_threadid, :jl_get_task_tid,
                    :jl_get_task_threadpoolid, :jl_threadpoolid)
        # (one thread: the first, in the pool of id 0, as natively the main thread is; no
        # finalizers run during code)
        return typ === Nothing ? ghost(Nothing, nothing) : const_value(fc, zero(typ))
    elseif name === :jl_hrtime
        # (`time_ns`) the host's monotonic clock
        call!(fc.b, host_import!(fc.cgm, "hrtime", ValType[], ValType[I64]))
        return pop_val!(fc, UInt64)
    elseif name === :jl_module_name
        push_val!(fc, convert_repr(fc, args[1]::CGVal, Module))
        emit!(fc.b, :struct_get, layout(fc, Module).wtype, HEADER_FIELDS)
        return pop_val!(fc, Symbol)
    elseif (r = runtime_ccall(name)) !== nothing
        return emit_runtime_ccall!(fc, r, args, typ)
    elseif name === :jl_get_world_counter || name === :jl_get_tls_world_age
        # the world the code was compiled in: there is one
        return const_value(fc, convert(typ, fc.cgm.world.world))
    elseif name === :jl_rethrow
        return emit_rethrow!(fc)
    elseif name === :jl_rethrow_other
        return emit_rethrow!(fc, args[1])
    elseif name === :jl_current_exception
        return emit_the_exception!(fc)
    elseif typ === Union{}
        unreachable!(fc.b)
        return bottom()
    end
    unsupported("the foreign call ", something(name, ex.args[1]))
end

"""
`jl_new_structv(T, fields, nf)` (`deepcopy` of an immutable value): a new `T` of the values
at the pointer `fields` (an array of them). The first `nf` are given, the rest undefined:
only of types whose fields are all defined, where `nf` is all of them.
"""
function new_structv!(fc::FnCtx, T::CGVal, p::CGVal)
    (isconstant(T) && constant_value(T) isa DataType) ||
        unsupported("a new object of a type not known at compile time")
    S = constant_value(T)
    (isconcretetype(S) && S.name.n_uninitialized == 0) ||
        unsupported("a new ", S, " from fields that may be undefined")
    vals = CGVal[convert_repr(fc, ptr_load!(fc, p, const_value(fc, k), Any), fieldtype(S, k))
                 for k in 1:fieldcount(S)]
    return convert_repr(fc, emit_new!(fc, S, vals), Any)
end

function is_llvmcall(@nospecialize(cc))
    cc isa QuoteNode && (cc = cc.value)
    cc isa Tuple && !isempty(cc) && (cc = cc[1])
    return cc === :llvmcall
end

function llvm_intrinsic_name(@nospecialize(x))
    x isa QuoteNode && (x = x.value)
    x isa String && return startswith(x, "llvm.") ? x : nothing
    x isa Tuple && !isempty(x) && return llvm_intrinsic_name(x[1])
    x isa Expr && x.head === :tuple && !isempty(x.args) && return llvm_intrinsic_name(x.args[1])
    return nothing
end

# LLVM's intrinsics (`llvm.<name>.<type>`) that code calls with `ccall(..., llvmcall, ...)`,
# as the Julia intrinsics that are the same operation
const LLVM_INTRINSICS = Dict("fmuladd" => II.muladd_float, "fma" => II.fma_float,
                             "sqrt" => II.sqrt_llvm, "fabs" => II.abs_float,
                             "copysign" => II.copysign_float, "floor" => II.floor_llvm,
                             "ceil" => II.ceil_llvm, "trunc" => II.trunc_llvm,
                             "rint" => II.rint_llvm)

"""
    emit_llvm_intrinsic!(fc, name, args, typ) -> CGVal

The call of the LLVM intrinsic `name` on floats, or on vectors of them (tuples of
`VecElement`s) element by element.
"""
function emit_llvm_intrinsic!(fc::FnCtx, name::String, args::Vector{Any}, @nospecialize(typ))
    parts = split(name, '.')
    f = length(parts) == 3 ? get(LLVM_INTRINSICS, parts[2], nothing) : nothing
    f === nothing && unsupported("the LLVM intrinsic ", name)
    if typ isa DataType && typ <: Tuple && fieldcount(typ) > 0 && fieldtype(typ, 1) <: VecElement
        E = fieldtype(typ, 1)
        elems = CGVal[]
        for k in 1:fieldcount(typ)
            xs = Any[get_field(fc, get_field(fc, a::CGVal, k), 1) for a in args]
            push!(elems, emit_new!(fc, E, CGVal[emit_intrinsic!(fc, f, xs, fieldtype(E, 1))]))
        end
        return emit_new!(fc, typ, elems)
    end
    return emit_intrinsic!(fc, f, args, typ)
end

"""
    emit_objectid!(fc, x) -> CGVal

`objectid(x)` as Julia's C runtime computes it, where it does not depend on addresses: of a
symbol, its hash; of a string, the hash of its bytes; of an isbits value without padding of
1, 2, 4 or 8 bytes, the hash of its bits mixed with its type's hash (`immut_id_`); of a
singleton, from its type's hash. Hashes of `Dict`s built at compile time depend on these
values. Of another mutable object, a hash of its identity hash (natively of its address).
"""
function emit_objectid!(fc::FnCtx, x::CGVal)
    T = x.typ
    if isconstant(x)
        v = constant_value(x)
        (v isa Symbol || isbits(v)) && return const_value(fc, objectid(v))
    end
    if T === Symbol
        push_val!(fc, x)
        emit!(fc.b, :struct_get, layout(fc, Symbol).wtype, SYMBOL_HASH_FIELD)
        return pop_val!(fc, UInt64)
    elseif T === String
        # of its bytes, as natively
        return call_runtime!(fc, Runtime.memhash, CGVal[x, const_value(fc, 0xedc3b677)])
    elseif T isa DataType && isconcretetype(T) && ismutabletype(T) && layout(fc, T).kind === Boxed
        # natively a hash of its address: of an object of the image, the one it had natively;
        # of others, a hash of their identity hash (see `objectid_mutable_func!`)
        push_val!(fc, convert_repr(fc, x, Any))
        call!(fc.b, objectid_mutable_func!(fc.cgm))
        return pop_val!(fc, UInt64)
    end
    if !(T isa DataType && isconcretetype(T) && !ismutabletype(T))
        # by its type at run time
        push_val!(fc, convert_repr(fc, x, Any))
        call!(fc.b, objectid_any_func!(fc.cgm))
        return pop_val!(fc, UInt64)
    end
    h(fc) = const_value(fc, UInt64(reinterpret(UInt32, getfield(T, :hash))))
    layout(fc, T).kind === Boxed || return immut_id!(fc, x, T, h(fc))
    # an immutable object (which may refer to others of its type): by a helper per type
    return call_outlined!(fc, (:objectid, T), () -> "objectid_" * typename_str(T), CGVal[x], UInt64,
                          (hfc, a) -> immut_id!(hfc, a[1], T, h(hfc)))
end

# `immut_id_(T, x, h)`: the id of the immutable value `x`, from `h`: of its bits where it has
# no padding and no references, else of its fields' ids, mixed in order (a field stored as
# a reference: the id of its value; stored inline: its own `immut_id_` from 0)
function immut_id!(fc::FnCtx, x::CGVal, @nospecialize(T), h::CGVal)
    sz = sizeof(T)
    if sz == 0
        push_val!(fc, h); emit!(fc.b, :i64_const, -1); emit!(fc.b, :i64_xor)
        return pop_val!(fc, UInt64)
    end
    if !Base.datatype_haspadding(T) && Base.datatype_pointerfree(T) &&
       (isprimitivetype(T) || Base.datatype_isbitsegal(T))
        I = sz == 1 ? Int8 : sz == 2 ? Int16 : sz == 4 ? Int32 : sz == 8 ? UInt64 : NTuple{sz,UInt8}
        # (other sizes: memhash of the bytes)
        bits = emit_reinterpret_bits!(fc, I, x, T)
        r = call_runtime!(fc, Runtime.bits_hash, CGVal[bits])
        push_val!(fc, r); push_val!(fc, h); emit!(fc.b, :i64_xor)
        return pop_val!(fc, UInt64)
    end
    for i in 1:fieldcount(T)
        FT = fieldtype(T, i)
        v = get_field(fc, x, i)
        u = !Base.allocatedinline(FT) ? emit_objectid!(fc, v) :
            FT isa Union ? union_immut_id!(fc, v, FT) :
            immut_id!(fc, convert_repr(fc, v, FT), FT, const_value(fc, UInt64(0)))
        h = call_runtime!(fc, Runtime.bitmix, CGVal[h, u])
    end
    return h
end

# `immut_id_` of a field stored inline of a union of types (isbits): of the member it holds
function union_immut_id!(fc::FnCtx, v::CGVal, @nospecialize(U))
    r = new_local!(fc, I64)
    for C in Base.uniontypes(U)
        push_val!(fc, emit_isa!(fc, v, C))
        if!(fc.b)
        push_val!(fc, immut_id!(fc, convert_repr(fc, v, C), C, const_value(fc, UInt64(0))))
        emit!(fc.b, :local_set, r)
        end!(fc.b)
    end
    emit!(fc.b, :local_get, r)
    return pop_val!(fc, UInt64)
end

"A `String` or `Symbol` (`T`) of a copy of the `n` bytes at the pointer `p`."
function bytes_from_ptr!(fc::FnCtx, p::CGVal, n::CGVal, @nospecialize(T))
    n = convert_repr(fc, n, Int)
    arr = array_type!(fc.cgm.types, I8)
    push_val!(fc, n); emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :array_new_default, arr)
    s = new_bytes_object!(fc, String)
    emit_memmove!(fc, string_ptr!(fc, s, Ptr{UInt8}), p, n, true)
    T === String && return s
    h = call_runtime!(fc, Runtime.symbol_hash, CGVal[s])
    push_val!(fc, s); emit!(fc.b, :struct_get, layout(fc, String).wtype, DATA_FIELD)
    return new_bytes_object!(fc, T, h)
end

"""
    new_bytes_object!(fc, T[, hash]) -> CGVal

The `String` (or `Symbol`, with its `hash`, a UInt64) object of type `T` of the bytes on
the stack.
"""
function new_bytes_object!(fc::FnCtx, @nospecialize(T), hash::Union{Nothing,CGVal}=nothing)
    ts = fc.cgm.types
    arr = new_local!(fc, RefType(array_type!(ts, I8), true))
    emit!(fc.b, :local_set, arr)
    emit!(fc.b, :i32_const, typeid!(ts, T))
    emit!(fc.b, :i32_const, 0)
    emit!(fc.b, :local_get, arr)
    T === Symbol && push_val!(fc, hash::CGVal)
    emit!(fc.b, :struct_new, bytes_object_type!(ts, T))
    return pop_val!(fc, T)
end

# the origin of the pointer `p` into the array of a memory, or nothing
function array_origin(p::CGVal)
    o = p.origin
    return o === nothing || is_object_origin(o) ? nothing : o
end

# push the index of the array element the origin `o` points to, or the number of array
# elements of `n` bytes (`count`)
function push_array_index!(fc::FnCtx, o::PtrOrigin, n::Union{Nothing,CGVal}=nothing; elements::Bool=false)
    ml = memory_layout(fc.cgm.types, o.eltype)
    if n === nothing
        push_leaf!(fc, o.index)
    else
        push_val!(fc, n)
        layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    end
    if elements
        ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    elseif byte_addressable(fc, o.eltype)
        s = storage_size(fc, o.eltype)
        s != 1 && (emit!(fc.b, :i32_const, s); emit!(fc.b, :i32_div_u))
    else
        u = elem_unit(o.eltype)
        u != 1 && (emit!(fc.b, :i32_const, u); emit!(fc.b, :i32_div_u))
        ml.stride != 1 && (emit!(fc.b, :i32_const, ml.stride); emit!(fc.b, :i32_mul))
    end
end

# push whether the byte offsets of the origins and the length `n` are multiples of the
# storage size `s` of their arrays' elements (an i32)
function push_aligned!(fc::FnCtx, origins, n::CGVal, s::Int)
    for (k, o) in enumerate(origins)
        push_leaf!(fc, o.index)
        k > 1 && emit!(fc.b, :i32_or)
    end
    push_val!(fc, n)
    layout(fc, n.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_or)
    emit!(fc.b, :i32_const, s - 1); emit!(fc.b, :i32_and)
    emit!(fc.b, :i32_eqz)
end

byte_ptr(p::CGVal) = CGVal(Ptr{UInt8}, Inline, p.leaves)

"""
    emit_memmove!(fc, dst, src, n, bytes) -> CGVal

`memmove` (or `jl_genericmemory_copyto`) of `n` bytes (or elements) from `src` to `dst`:
an `array.copy` between the arrays they point into, if known, of one type, and aligned to
their elements, else a copy byte by byte (`Runtime.ptr_memmove`).
"""
function emit_memmove!(fc::FnCtx, dst, src, n, bytes::Bool)
    dst, src, n = dst::CGVal, src::CGVal, n::CGVal
    od, os = array_origin(dst), array_origin(src)
    ts = fc.cgm.types
    if od !== nothing && os !== nothing
        md, ms = memory_layout(ts, od.eltype), memory_layout(ts, os.eltype)
        ba = byte_addressable(fc, od.eltype) && byte_addressable(fc, os.eltype)
        if md.array == ms.array && (od.eltype === os.eltype || ba)
            # bytes of arrays of bytes, or whole elements (of elements not stored as bytes,
            # pointers to whole elements)
            s = bytes && ba ? storage_size(fc, od.eltype) : 1
            if s > 1
                push_aligned!(fc, (od, os), n, s)
                if!(fc.b)
            end
            push_leaf!(fc, od.array); push_array_index!(fc, od)
            push_leaf!(fc, os.array); push_array_index!(fc, os)
            push_array_index!(fc, od, n; elements=!bytes)
            emit!(fc.b, :array_copy, md.array, md.array)
            if s > 1
                else!(fc.b)
                call_runtime!(fc, Runtime.ptr_memmove, CGVal[byte_ptr(dst), byte_ptr(src), convert_repr(fc, n, UInt)])
                end!(fc.b)
            end
            return bytes ? dst : ghost(Nothing, nothing)
        end
    end
    bytes || unsupported("copying elements between memories not known at compile time")
    call_runtime!(fc, Runtime.ptr_memmove, CGVal[byte_ptr(dst), byte_ptr(src), convert_repr(fc, n, UInt)])
    return dst
end

"""
    emit_memset!(fc, p, val, n) -> CGVal

`memset` of `n` bytes at `p` to the byte `val`: an `array.fill` of the array it points
into (of bytes, or of zeros aligned to its elements), else byte by byte
(`Runtime.ptr_memset`).
"""
function emit_memset!(fc::FnCtx, p, val, n)
    p, val, n = p::CGVal, val::CGVal, n::CGVal
    o = array_origin(p)
    if o !== nothing
        ml = memory_layout(fc.cgm.types, o.eltype)
        bytewise = ml.storage === I8 && ml.stride == 1
        if bytewise || (isconstant(val) && iszero(constant_value(val)))
            s = !bytewise && byte_addressable(fc, o.eltype) ? storage_size(fc, o.eltype) : 1
            if s > 1
                push_aligned!(fc, (o,), n, s)
                if!(fc.b)
            end
            push_leaf!(fc, o.array); push_array_index!(fc, o)
            if bytewise
                push_val!(fc, val)
                layout(fc, val.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
                emit!(fc.b, :i32_const, 0xff); emit!(fc.b, :i32_and)
            else
                st = ml.storage
                push_default!(fc, st isa PackedType ? I32 : st)
            end
            push_array_index!(fc, o, n)
            emit!(fc.b, :array_fill, ml.array)
            if s > 1
                else!(fc.b)
                emit_memset_bytes!(fc, p, val, n)
                end!(fc.b)
            end
            return p
        end
    end
    emit_memset_bytes!(fc, p, val, n)
    return p
end

function emit_memset_bytes!(fc::FnCtx, p::CGVal, val::CGVal, n::CGVal)
    push_val!(fc, val)
    layout(fc, val.typ).leaves[1].type === I64 && emit!(fc.b, :i32_wrap_i64)
    emit!(fc.b, :i32_const, 0xff); emit!(fc.b, :i32_and)
    b = pop_val!(fc, UInt8)
    call_runtime!(fc, Runtime.ptr_memset, CGVal[byte_ptr(p), b, convert_repr(fc, n, UInt)])
end

## C library calls implemented by the runtime

"""
    RuntimeCcall(f, args)

A C function implemented by the runtime function `f`. `args` says how each argument of the
C call becomes an argument of `f`: `:val` (as it is), `:ref` (a pointer to a scalar, as
Fortran passes them: the scalar), `:array` (a pointer into an array: a `MemoryRef`),
`:skip` (dropped, e.g. the hidden lengths of Fortran strings).
"""
struct RuntimeCcall
    f::Any
    args::Vector{Symbol}
end

const RUNTIME_CCALLS = Dict{Symbol,RuntimeCcall}(
    # Unicode properties (libutf8proc, libjulia): tables of the native libraries
    :utf8proc_category => RuntimeCcall(Runtime.UnicodeData.category, [:val]),
    :utf8proc_isupper => RuntimeCcall(Runtime.UnicodeData.isupper, [:val]),
    :utf8proc_charwidth => RuntimeCcall(Runtime.UnicodeData.charwidth, [:val]),
    :utf8proc_islower => RuntimeCcall(Runtime.UnicodeData.islower, [:val]),
    :utf8proc_toupper => RuntimeCcall(Runtime.UnicodeData.toupper, [:val]),
    :utf8proc_tolower => RuntimeCcall(Runtime.UnicodeData.tolower, [:val]),
    :utf8proc_totitle => RuntimeCcall(Runtime.UnicodeData.totitle, [:val]),
    :jl_id_char => RuntimeCcall(Runtime.UnicodeData.id_char, [:val]),
    :jl_id_start_char => RuntimeCcall(Runtime.UnicodeData.id_start_char, [:val]),
    :utf8proc_grapheme_break_stateful =>
        RuntimeCcall(Runtime.UnicodeData.grapheme_break_stateful, [:val, :val, :val]),
    # the C library's float parsing and errno
    :jl_strtod_c => RuntimeCcall(Runtime.Floats.strtod, [:val, :val]),
    :jl_strtof_c => RuntimeCcall(Runtime.Floats.strtof, [:val, :val]),
    :jl_try_substrtod => RuntimeCcall(Runtime.Floats.try_substrtod, [:val, :val, :val]),
    :jl_try_substrtof => RuntimeCcall(Runtime.Floats.try_substrtof, [:val, :val, :val]),
    :jl_set_errno => RuntimeCcall(Runtime.Floats.set_errno, [:val]),
    :jl_errno => RuntimeCcall(Runtime.Floats.get_errno, Symbol[]),
    # C strings: the bytes before a NUL (a string's or symbol's end)
    :strlen => RuntimeCcall(Runtime.ptr_strlen, [:val]),
    :jl_cstr_to_string => RuntimeCcall(Runtime.cstr_to_string, [:val]),
    # identity hash tables (`IdDict`)
    :jl_eqtable_put => RuntimeCcall(Runtime.EqTables.put, [:val, :val, :val, :val]),
    :jl_eqtable_get => RuntimeCcall(Runtime.EqTables.get, [:val, :val, :val]),
    :jl_eqtable_pop => RuntimeCcall(Runtime.EqTables.pop, [:val, :val, :val, :val]),
    :jl_eqtable_nextind => RuntimeCcall(Runtime.EqTables.nextind, [:val, :val]),
    :jl_idtable_rehash => RuntimeCcall(Runtime.EqTables.rehash, [:val, :val]),
    # hashing of strings before Julia 1.13
    :memhash_seed => RuntimeCcall(Runtime.memhash_seed, [:val, :val, :val]),
)

# BLAS (libblastrampoline's ILP64 names, `dgemm_64_`): an argument by reference is loaded
# (`:ref`), an array is passed as a reference to its first element where possible
# (`:array`), the lengths of character arguments Fortran adds are dropped (`:ignore`)
for (p, T) in (("d", Float64), ("s", Float32))
    B = Runtime.BLAS
    r, a, v, x = :ref, :array, :val, :ignore
    for (name, f, kinds) in (
            ("$(p)copy_", B.copy!, [r, a, r, a, r]),
            ("$(p)scal_", B.scal!, [r, r, a, r]),
            ("cblas_$(p)dot", B.dot, [v, a, v, a, v]),
            ("$(p)nrm2_", B.nrm2, [r, a, r]),
            ("$(p)asum_", B.asum, [r, a, r]),
            ("$(p)axpy_", B.axpy!, [r, r, a, r, a, r]),
            ("$(p)axpby_", B.axpby!, [r, r, a, r, r, a, r]),
            ("i$(p)amax_", B.iamax, [r, a, r]),
            ("$(p)gemv_", B.gemv!, [r, r, r, r, a, r, a, r, r, a, r, x]),
            ("$(p)symv_", B.symv!, [r, r, r, a, r, a, r, r, a, r, x]),
            ("$(p)trmv_", B.trmv!, [r, r, r, r, a, r, a, r, x, x, x]),
            ("$(p)trsv_", B.trsv!, [r, r, r, r, a, r, a, r, x, x, x]),
            ("$(p)ger_", B.ger!, [r, r, r, a, r, a, r, a, r]),
            ("$(p)gemm_", B.gemm!, [r, r, r, r, r, r, a, r, a, r, r, a, r, x, x]),
            ("$(p)syrk_", B.syrk!, [r, r, r, r, r, a, r, r, a, r, x, x]),
            ("$(p)symm_", B.symm!, [r, r, r, r, r, a, r, a, r, r, a, r, x, x]),
            ("$(p)trmm_", B.trmm!, [r, r, r, r, r, r, r, a, r, a, r, x, x, x, x]),
            ("$(p)trsm_", B.trsm!, [r, r, r, r, r, r, r, a, r, a, r, x, x, x, x]))
        RUNTIME_CCALLS[Symbol(name, "64_")] = RuntimeCcall(f, kinds)
    end
    # LAPACK (outputs, `info` and pivots, are arrays written through)
    P = Runtime.LAPACK
    for (name, f, kinds) in (
            ("$(p)getrf_", P.getrf!, [r, r, a, r, a, a]),
            ("$(p)getrs_", P.getrs!, [r, r, r, a, r, a, a, r, a, x]),
            ("$(p)getri_", P.getri!, [r, a, r, a, a, r, a]),
            ("$(p)potrf_", P.potrf!, [r, r, a, r, a, x]),
            ("$(p)potrs_", P.potrs!, [r, r, r, a, r, a, r, a, x]),
            ("$(p)trtrs_", P.trtrs!, [r, r, r, r, r, a, r, a, r, a, x, x, x]),
            ("$(p)lacpy_", P.lacpy!, [r, r, r, a, r, a, r, x]),
            ("$(p)geqp3_", P.geqp3!, [r, r, a, r, a, a, a, r, a]),
            ("$(p)ormqr_", P.ormqr!, [r, r, r, r, r, a, r, a, a, r, a, r, a, x, x]),
            ("$(p)tzrzf_", P.tzrzf!, [r, r, a, r, a, a, r, a]),
            ("$(p)ormrz_", P.ormrz!, [r, r, r, r, r, r, a, r, a, a, r, a, r, a, x, x]),
            ("$(p)laic1_", P.laic1!, [r, r, a, r, a, r, a, a, a]),
            ("$(p)geqrt_", P.geqrt!, [r, r, r, a, r, a, r, a, a]),
            ("$(p)gemqrt_", P.gemqrt!, [r, r, r, r, r, r, a, r, a, r, a, r, a, a, x, x]),
            ("$(p)syevr_", P.syevr!, [r, r, r, r, a, r, r, r, r, r, r, a, a, a, r, a, a, r, a, r, a, x, x, x]),
            ("$(p)gesdd_", P.gesdd!, [r, r, r, a, r, a, a, r, a, r, a, r, a, a, x]),
            ("$(p)gesvd_", P.gesvd!, [r, r, r, r, a, r, a, a, r, a, r, a, r, a, x, x]),
            ("$(p)sytrf_", P.sytrf!, [r, r, a, r, a, a, r, a, x]),
            ("$(p)sytrf_rook_", P.sytrf_rook!, [r, r, a, r, a, a, r, a, x]),
            ("$(p)sytrs_", P.sytrs!, [r, r, r, a, r, a, a, r, a, x]),
            ("$(p)sytrs_rook_", P.sytrs_rook!, [r, r, r, a, r, a, a, r, a, x]))
        RUNTIME_CCALLS[Symbol(name, "64_")] = RuntimeCcall(f, kinds)
    end
end

runtime_ccall(name) = name === nothing ? nothing : get(RUNTIME_CCALLS, name, nothing)

function emit_runtime_ccall!(fc::FnCtx, r::RuntimeCcall, args::Vector{Any}, @nospecialize(typ))
    length(args) == length(r.args) ||
        unsupported("a call of ", r.f, " with ", length(args), " arguments")
    vals = CGVal[]
    for (a, kind) in zip(args, r.args)
        a = a::CGVal
        if kind === :val
            push!(vals, a)
        elseif kind === :ref
            push!(vals, ptr_load!(fc, a, const_value(fc, 1), eltype(a.typ)))
        elseif kind === :array
            # a reference to the element, where the pointer is known to point into a memory
            # of its element type; else the pointer
            o = array_origin(a)
            push!(vals, o !== nothing && is_ptr_type(a.typ) && o.eltype === eltype(a.typ) ?
                        element_ref!(fc, o, const_value(fc, 1), o.eltype) : a)
        end
    end
    res = call_runtime!(fc, r.f, vals)
    return res.kind === Ghost ? ghost(Nothing, nothing) : res
end

## function pointers (`Config(funcref_wrappers = true)`, see `runtime/fwrappers.jl`)

const FUNCWRAPPERS_PKG = Base.PkgId(Base.UUID("069b7b12-0de2-55c6-9aab-29f3d0a68a2e"), "FunctionWrappers")
"The `FunctionWrappers` module when it is loaded, else `nothing`."
funcwrappers_module() = Base.maybe_root_module(FUNCWRAPPERS_PKG)

"""
    cfunc_sig!(cgm, rt, argts) -> TypeRef

The Wasm function type of a C signature: the leaves of each argument type (a `Ref` is a
pointer) and of the return type (none for a singleton).
"""
function cfunc_sig!(cgm::CGModule, @nospecialize(rt), argts::Vector{Any})
    params = ValType[]
    for (i, T) in enumerate(argts)
        P = i > 1 && singleton_ref(T) ? Any : T isa Type && T <: Ref ? Ptr{Cvoid} : T
        append!(params, valtypes(cgm, P))
    end
    lr = layout(cgm, rt)
    results = lr.kind === Ghost || lr.kind === Bottom ? ValType[] : valtypes(cgm, rt)
    return WasmBuilder.functype!(cgm.mod, params, results)
end

"The parameter and result value types of the Wasm function type `t`, for diagnostics."
function functype_string(cgm::CGModule, t)
    ft = try cgm.mod.types[t.idx + 1] catch; nothing end
    return ft === nothing ? string(t) : string(ft)
end

"""
    singleton_ref(T) -> Bool

Whether `T` is `Ref{S}` of a singleton type `S`, or of a concrete type `S` not stored inline (a
mutable or boxed object, such as a `Vector`). FunctionWrappers declares such an argument as
`Ref{S}` in the `cfunction` signature and passes it as `Any` in the `ccall` (its
`map_cfunc_argtype`/`map_argtype`: everything not `allocatedinline`), so both sides carry it as a
reference to the object.
"""
singleton_ref(@nospecialize(T)) =
    T isa DataType && T <: Ref && length(T.parameters) == 1 && (S = T.parameters[1];
        Base.issingletontype(S) || (S isa DataType && isconcretetype(S) && !Base.allocatedinline(S)))

"""
    cfunc_trampoline!(cgm, callee, rt, argts) -> FuncInfo

`Runtime.fw_trampoline` compiled for the cfunction `(callee, rt, argts)` of FunctionWrappers'
shape (`argts[1]` a `Ref` of the wrapped object's type, the others passed by value or a `Ref`
of a singleton type), checked to have the C signature's Wasm type.
"""
function cfunc_trampoline!(cgm::CGModule, @nospecialize(callee), @nospecialize(rt), argts::Vector{Any})
    (!isempty(argts) && argts[1] isa DataType && argts[1] <: Ref) ||
        unsupported("a cfunction whose first argument is not a Ref: ", argts)
    objT = argts[1].parameters[1]
    rest = argts[2:end]
    for T in rest
        (T isa Type && T <: Ref && !singleton_ref(T)) &&
            unsupported("a cfunction with an argument passed by reference: ", T)
    end
    lr = layout(cgm, rt)
    (rt isa Type && rt <: Ref) && unsupported("a cfunction returning by reference: ", rt)
    info = if any(singleton_ref, rest)
        mask = Tuple(singleton_ref(T) for T in rest)
        # only the singleton types are read; `Nothing` elsewhere keeps `S` concrete (an `Any` argument
        # would make it abstract, and `Type{S}` a parameter)
        S = Tuple{(singleton_ref(T) ? T.parameters[1] : Nothing for T in rest)...}
        length(rest) <= 8 || unsupported("a cfunction with more than 8 arguments and a singleton one: ", argts)
        runtime_function!(cgm, Runtime.fw_trampoline_singletons,
                          (Type{objT}, Type{S}, Val{mask}, Core.Typeof(callee), Ptr{Cvoid},
                           Any[singleton_ref(T) ? Any : T for T in rest]...))
    else
        runtime_function!(cgm, Runtime.fw_trampoline,
                          (Type{objT}, Core.Typeof(callee), Ptr{Cvoid}, rest...))
    end
    sig = cfunc_sig!(cgm, rt, argts)
    info.func.type == sig ||
        unsupported("a cfunction whose trampoline type differs from its C signature: ", argts, " -> ", rt,
                    " (trampoline ", functype_string(cgm, info.func.type), ", C ", functype_string(cgm, sig), ")")
    return info
end

"The constant instructions of a box owning a reference to `func` (type `sig`)."
function funcptr_box_init(ts::Types, func::Func, sig::TypeRef, hash::Int32)
    box = funcptr_box_type!(ts, sig)
    return Inst[Inst(:i32_const, typeid!(ts, Runtime.FuncPtrBox)), Inst(:i32_const, hash),
                Inst(:ref_func, func), Inst(:struct_new, box)]
end

"""
    funcptr_box!(cgm, info) -> (Global, Int64)

The one box owning the reference to the trampoline `info`, and the address of pointers to it:
its virtual address (its identity hash shifted by 32 bits, as for any pointer owner). Every
pointer to one trampoline is the same pointer and pointers to different trampolines differ.
(Natively, wrappers whose `@cfunction` comes from the same compiled code share a pointer, but a
`@cfunction` compiled at another call site has a pointer of its own.)
"""
function funcptr_box!(cgm::CGModule, info::FuncInfo)
    get!(cgm.helpers, (:funcptr_box, info.func)) do
        ts = cgm.types
        h = image_hash!(cgm.image, hash((:funcptr_box, objectid(info.mi))))
        g = add_global!(cgm.mod, "jl_funcptr_$(length(cgm.helpers))", RefType(funcptr_box_type!(ts, info.func.type), false),
                        false, funcptr_box_init(ts, info.func, info.func.type, h))
        (g, owner_address(h))
    end
end

"The virtual address of an object whose identity hash is `h` (see `push_memory_base!`)."
owner_address(h::Int32) = reinterpret(Int64, UInt64(reinterpret(UInt32, h)) << 32)

"`Expr(:cfunction, Ptr{Cvoid}, f, rt, argts, cc)`: a pointer owned by a box of the trampoline's reference."
function emit_cfunction!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    fc.cgm.config.funcref_wrappers || unsupported("the expression head cfunction")
    f = ex.args[2]
    f isa QuoteNode && (f = f.value)
    if f isa Core.SSAValue || f isa Core.Argument || f isa GlobalRef
        c = operand(fc, f)
        (c isa CGVal && isconstant(c)) || unsupported("a cfunction of a function value not known at compile time")
        f = constant_value(c)
    end
    rt = ex.args[3]
    argts = collect(Any, ex.args[4]::Core.SimpleVector)
    info = cfunc_trampoline!(fc.cgm, f, rt, argts)
    ts = fc.cgm.types
    g, addr = funcptr_box!(fc.cgm, info)
    emit!(fc.b, :global_get, g)
    o = new_local!(fc, jlvalue_ref(ts))
    emit!(fc.b, :local_set, o)
    emit!(fc.b, :i64_const, addr)      # nonzero: never `C_NULL`
    return new_ptr!(fc, typ === Ptr{Cvoid} ? typ : Ptr{Cvoid}, o, nothing)
end

"A `ccall` whose target is a pointer value: `call_ref` of the function its owner box holds."
function emit_indirect_ccall!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    target = operand(fc, ex.args[1])
    (target isa CGVal && is_ptr_type(target.typ)) ||
        unsupported("a foreign call through a value of type ", target isa CGVal ? target.typ : typeof(target))
    rt = ex.args[2]
    argts = collect(Any, ex.args[3]::Core.SimpleVector)
    nargs = length(argts)
    vals = CGVal[operand(fc, a) for a in ex.args[6:5+nargs]]
    sig = cfunc_sig!(fc.cgm, rt, argts)
    ts = fc.cgm.types
    box = funcptr_box_type!(ts, sig)
    fr = new_local!(fc, RefType(sig, true))
    push_leaf!(fc, ptr_owner(target))
    emit!(fc.b, :ref_cast, box)
    emit!(fc.b, :struct_get, box, DATA_FIELD)
    emit!(fc.b, :local_set, fr)
    for (v, T) in zip(vals, argts)
        if T isa Type && T <: Ref
            is_ptr_type(v.typ) || unsupported("a by-reference foreign call argument of type ", v.typ)
            push_val!(fc, v)
        else
            push_val!(fc, convert_repr(fc, v, T))
        end
    end
    emit!(fc.b, :local_get, fr)
    call_ref!(fc.b, sig)
    lr = layout(fc, rt)
    lr.kind === Ghost && return ghost(rt, rt.instance)
    return pop_val!(fc, rt)
end
