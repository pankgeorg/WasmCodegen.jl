# The image: the Julia objects the code refers to, serialized into the module.
#
# Every object is an immutable global of the module, whose initializer (a constant
# expression) builds it: `struct.new` with its fields, `array.new_fixed` with its
# elements. Fields that refer to other objects are `global.get`s of their globals, which
# are emitted first (depth-first postorder). A reference to an object whose global does
# not exist yet (a cycle) is null in the initializer, and set by the module's start
# function. Large arrays of numbers are filled by the start function from data segments.
#
# Objects are keyed by identity (`IdDict`), so that an object referred to from several
# places is one object in the module, as it is in Julia's heap.

"""
    Image

The serialized objects of a module: the global of each object, the objects being
serialized (to detect cycles), and the start function's instructions that complete them.
"""
mutable struct Image
    cgm::Any
    globals::IdDict{Any,Global}
    boxes::IdDict{Any,Global}
    singletons::IdDict{Any,Global}
    inprogress::IdSet{Any}
    "Instructions of the start function: stores of the references of cycles, array fills."
    init::Vector{Inst}
    "References to set by the start function, once every global exists: (global of the
    object, Wasm type, field or element index, value, declared type)."
    patches::Vector{Any}
    "Global variables: (module, name) => the globals of the leaves of its value."
    vars::Dict{Tuple{Module,Symbol},Tuple{Any,Vector{Global},Union{Nothing,Global}}}
    "The globals of the arrays of `Memory`, `String` and `Symbol` objects."
    arrays::IdDict{Any,Global}
    counter::Int
    "The native `objectid`s of the mutable objects, which their headers' hash refers to."
    native_ids::Vector{UInt64}
end

Image(cgm) = Image(cgm, IdDict{Any,Global}(), IdDict{Any,Global}(), IdDict{Any,Global}(),
                   IdSet{Any}(), Inst[], Any[],
                   Dict{Tuple{Module,Symbol},Tuple{Any,Vector{Global},Union{Nothing,Global}}}(), IdDict{Any,Global}(), 0,
                   UInt64[])

"""
    header_hash(img, x) -> Inst

The hash field of the header of the object `x`: of a mutable object, -k for its native
`objectid`, the k-th of `img.native_ids` (so that hash tables built natively find it, see
`objectid_mutable_func!`); of others, 0 (none assigned yet).
"""
function header_hash(img::Image, @nospecialize(x))
    ismutable(x) && !(x isa String) || return Inst(:i32_const, 0)
    push!(img.native_ids, objectid(x))
    return Inst(:i32_const, -Int32(length(img.native_ids)))
end

types(img::Image) = img.cgm.types

"The maximum number of elements of an array built by `array.new_fixed` in an initializer."
const MAX_FIXED_ELEMENTS = 10_000
"The maximum number of bytes of a numeric array built by `array.new_fixed`."
const MAX_FIXED_BYTES = 256

function global_name(img::Image, @nospecialize(x))
    img.counter += 1
    T = typeof(x)
    base = T isa DataType ? string(T.name.name) : "obj"
    return string("jl_", replace(base, r"[^A-Za-z0-9_]" => "_"), "#", img.counter)
end

## constants in code

"""
    const_value(fc, x) -> CGVal

The compile-time constant `x`: a ghost, constant leaves (numbers, and `global.get`s of
the objects an inline value refers to), or a reference to its object in the image.
"""
function const_value(fc::FnCtx, @nospecialize(x))
    T = Core.Typeof(x)
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, x)
    if l.kind === Inline
        return CGVal(T, Inline, const_leaves(fc.cgm.image, x, T), Some{Any}(x))
    end
    g = object_global!(fc.cgm.image, x)
    return CGVal(T, Boxed, LeafVal[Inst(:global_get, g)], Some{Any}(x))
end

function primitive_const(@nospecialize(x), leaves::Vector{Leaf})
    T = typeof(x)
    if T === Float64
        return Inst[Inst(:f64_const, x)]
    elseif T === Float32
        return Inst[Inst(:f32_const, x)]
    end
    sz = sizeof(T)
    if sz == 16
        u = Core.bitcast(UInt128, x)
        return Inst[Inst(:i64_const, reinterpret(Int64, UInt64(u & typemax(UInt64)))),
                    Inst(:i64_const, reinterpret(Int64, UInt64(u >> 64)))]
    elseif sz == 8
        return Inst[Inst(:i64_const, reinterpret(Int64, Core.bitcast(UInt64, x)))]
    elseif sz == 4
        return Inst[Inst(:i32_const, reinterpret(Int32, Core.bitcast(UInt32, x)))]
    elseif sz == 2
        return Inst[Inst(:i32_const, Int32(Core.bitcast(UInt16, x)))]
    elseif sz == 1
        return Inst[Inst(:i32_const, Int32(Core.bitcast(UInt8, x)))]
    end
    unsupported("a constant of the primitive type ", T)
end

"""
    const_leaves(img, x, FT) -> Vector{Inst}

The leaves of the value `x` stored where the declared type is `FT` (a field, an
element): constant instructions, `global.get`s of objects.
"""
function const_leaves(img::Image, @nospecialize(x), @nospecialize(FT))
    ts = types(img)
    lf = layout(ts, FT)
    lf.kind === Ghost && return Inst[]
    if lf.kind === Inline
        T = typeof(x)
        # a pointer from the build process: an address without owner
        is_ptr_type(T) && return Inst[Inst(:i64_const, reinterpret(Int64, UInt64(UInt(x)))),
                                      Inst(:ref_null, ts.jlvalue)]
        isprimitivetype(T) && return primitive_const(x, lf.leaves)
        if is_memoryref_type(T)
            mem = x.mem
            g = object_global!(img, mem)
            return Inst[Inst(:global_get, g), Inst(:global_get, img.arrays[mem]),
                        Inst(:i32_const, Int32(Base.memoryrefoffset(x) - 1))]
        end
        leaves = Inst[]
        for i in 1:fieldcount(T)
            FTi = fieldtype(T, i)
            if isdefined(x, i)
                append!(leaves, const_leaves(img, getfield(x, i), FTi))
            else
                append!(leaves, Inst[default_inst(l.type) for l in field_leaves(ts, FTi)])
            end
        end
        return leaves
    end
    # a reference
    if lf.wtype == ts.jlvalue
        return Inst[Inst(:global_get, boxed_object_global!(img, x))]
    elseif lf.elements !== nothing && layout(ts, typeof(x)).elements === nothing
        # a tuple stored where the declared type is a tuple of unknown length (`VersionNumber`'s
        # `prerelease`): an array object of the declared element type
        g = get!(() -> tuple_array_global!(img, x, lf; register=false), img.boxes, (x, lf.wtype))
        return Inst[Inst(:global_get, g)]
    end
    return Inst[Inst(:global_get, object_global!(img, x))]
end

## objects

"""
    boxed_object_global!(img, x) -> Global

A global holding `x` as a `\$JlValue`: its object if it is one, else a box (for inline
values, ghosts, `Memory` and `String`).
"""
function boxed_object_global!(img::Image, @nospecialize(x))
    ts = types(img)
    T = typeof(x)
    l = layout(ts, T)
    if l.kind === Boxed && is_jlvalue_type(ts, T)
        return object_global!(img, x)
    elseif l.kind === Ghost
        return singleton_global!(img, T)
    end
    # isbits values are boxed once per value; others (Memory, String) per object
    get!(img.boxes, x) do
        box = box_type!(ts, T)
        init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0)]
        append!(init, const_leaves(img, x, T))
        push!(init, Inst(:struct_new, box))
        add_global!(img.cgm.mod, global_name(img, x), RefType(box, false), false, init)
    end
end

"The type `X` (in a `Some`) if `T` is `Type{X}`, the type only `X` is an instance of."
function type_singleton(@nospecialize(T))
    T isa DataType && T <: Type || return nothing
    v = ghost_value(T)
    return v !== nothing && something(v) isa Type ? v : nothing
end

"""
    singleton_global!(img, T) -> Global

The object of the singleton (ghost) type `T`, where it is stored as a `\$JlValue`.
"""
function singleton_global!(img::Image, @nospecialize(T))
    # a type (of type `Type{X}`): its type object, as types are interned
    X = type_singleton(T)
    X === nothing || return object_global!(img, something(X))
    get!(img.singletons, T) do
        ts = types(img)
        box = box_type!(ts, T)
        init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0),
                    Inst(:struct_new, box)]
        add_global!(img.cgm.mod, string("jl_singleton_", img.counter += 1), RefType(box, false),
                    false, init)
    end
end

"""
    object_global!(img, x) -> Global

The global of the object `x` (of a boxed type), serializing it (and the objects it refers
to) on first use.
"""
function object_global!(img::Image, @nospecialize(x))
    g = get(img.globals, x, nothing)
    g === nothing || return g
    x in img.inprogress && unsupported("serializing a cycle of objects through ", typeof(x))
    # types are objects even where their type is a singleton (`Union{}`)
    x isa Type && return type_object_global!(img, x)
    ts = types(img)
    T = typeof(x)
    l = layout(ts, T)
    l.kind === Boxed || unsupported("an object of the inline type ", T)
    if T === String || T === Symbol
        return bytes_object_global!(img, x)
    elseif is_memory_type(T)
        return memory_global!(img, x)
    elseif T === Core.TypeName || T === Module
        st = named_object_type!(ts)
        name = T === Module ? nameof(x) : x.name
        init = Inst[Inst(:i32_const, typeid!(ts, T)), header_hash(img, x),
                    Inst(:global_get, object_global!(img, name)), Inst(:struct_new, st)]
        g = add_global!(img.cgm.mod, (T === Module ? "jl_module_" : "jl_typename_") *
                                     replace(string(name), r"[^A-Za-z0-9_]" => "_"),
                        RefType(st, false), false, init)
        img.globals[x] = g
        return g
    elseif T === Core.SimpleVector
        return tuple_array_global!(img, x, l)
    elseif any(R -> T === R, OPAQUE_RUNTIME_TYPES)
        # an object the program holds but does not read (a CodeInstance kept in a build
        # record): the header only, so that `===` and `typeof` work; a field read of it is
        # reported by get_field
        return opaque_object_global!(img, x)
    elseif any(R -> T === R, RUNTIME_TYPES)
        unsupported("serializing the runtime object ", x, " of type ", T)
    elseif T <: Ptr || T === Ptr
        unsupported("serializing a pointer")
    elseif l.elements !== nothing
        g = tuple_array_global!(img, x, l)
    else
        g = struct_global!(img, x, l)
    end
    return g
end

# a large tuple: its elements in an array (as a Memory's), in an object
# the tuple `x` as an array object of the layout `l` (of its own type, or of the declared
# type of where it is stored)
function tuple_array_global!(img::Image, @nospecialize(x), l::Layout; register::Bool=true)
    ts = types(img)
    T = typeof(x)
    n = x isa Core.SimpleVector ? length(x) : fieldcount(T)
    mem = Memory{(l.elements::MemoryLayout).elem.T}(undef, n)
    for i in 1:n
        mem[i] = x[i]
    end
    memory_global!(img, mem)
    arr = img.arrays[mem]
    init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0), Inst(:global_get, arr),
                Inst(:struct_new, l.wtype)]
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    register && (img.globals[x] = g)
    return g
end

# a type object: its header and the id of the type it is
function type_object_global!(img::Image, @nospecialize(x::Type))
    ts = types(img)
    st = type_object_type!(ts)
    init = Inst[Inst(:i32_const, typeid!(ts, typeof(x))), Inst(:i32_const, 0),
                Inst(:i32_const, typeid!(ts, x)), Inst(:struct_new, st)]
    name = "jl_type_" * replace(string(x), r"[^A-Za-z0-9_]" => "_")
    g = add_global!(img.cgm.mod, name, RefType(st, false), false, init)
    img.globals[x] = g
    return g
end

# a String or Symbol: its bytes, in an object
function bytes_object_global!(img::Image, @nospecialize(x))
    ts = types(img)
    T = typeof(x)
    bytes = Vector{UInt8}(codeunits(x isa Symbol ? String(x) : x))
    arr = array_global!(img, bytes, bytes, UInt8)
    img.arrays[x] = arr
    init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0), Inst(:global_get, arr)]
    # a symbol's hash, computed natively
    x isa Symbol && push!(init, Inst(:i64_const, reinterpret(Int64, objectid(x))))
    push!(init, Inst(:struct_new, bytes_object_type!(ts, T)))
    name = x isa Symbol ? "jl_sym_" * replace(String(x), r"[^A-Za-z0-9_]" => "_") : global_name(img, x)
    g = add_global!(img.cgm.mod, name, RefType(bytes_object_type!(ts, T), false), false, init)
    img.globals[x] = g
    return g
end

# the object of a Memory whose array is the global `arr`
function memory_object_global!(img::Image, mem, arr::Global)
    ts = types(img)
    T = typeof(mem)
    img.arrays[mem] = arr
    st = memory_struct_type!(ts, memory_eltype(T))
    init = Inst[Inst(:i32_const, typeid!(ts, T)), header_hash(img, mem), Inst(:global_get, arr),
                Inst(:struct_new, st)]
    g = add_global!(img.cgm.mod, global_name(img, mem), RefType(st, false), false, init)
    img.globals[mem] = g
    return g
end

# the leaves of the field value `v` (declared type FT) of an object being serialized, with
# null for references to objects being serialized (cycles), recorded in `back`
function field_init!(img::Image, @nospecialize(v), @nospecialize(FT), back::Vector{Any}, slot)
    ts = types(img)
    lf = layout(ts, FT)
    if lf.kind === Boxed
        target = lf.wtype == ts.jlvalue && !(layout(ts, typeof(v)).kind === Boxed &&
                                             is_jlvalue_type(ts, typeof(v))) ? nothing : v
        if target !== nothing && target in img.inprogress
            push!(back, (slot, v, FT))
            return Inst[Inst(:ref_null, lf.leaves[1].type.heap)]
        end
    end
    return const_leaves(img, v, FT)
end

function struct_global!(img::Image, @nospecialize(x), l::Layout)
    ts = types(img)
    T = typeof(x)
    push!(img.inprogress, x)
    back = Any[]
    init = Inst[Inst(:i32_const, typeid!(ts, T)), header_hash(img, x)]
    try
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            if isdefined(x, i)
                append!(init, field_init!(img, getfield(x, i), FT, back, first(l.fields[i]) - 1))
            else
                append!(init, Inst[default_inst(leaf.type) for leaf in field_leaves(ts, FT)])
            end
        end
    finally
        delete!(img.inprogress, x)
    end
    push!(init, Inst(:struct_new, l.wtype))
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    img.globals[x] = g
    if !isempty(back)
        ismutabletype(T) || unsupported("a cycle of objects through the immutable ", T)
        for (wfield, v, FT) in back
            push!(img.patches, (g, :struct, l.wtype, wfield, v, FT))
        end
    end
    return g
end

function memory_global!(img::Image, mem)
    T = typeof(mem)
    E = memory_eltype(T)
    ml = memory_layout(types(img), E)
    el = ml.elem
    if el.kind === Ghost || el.kind === Bottom
        arr = add_array_global!(img, nothing, ml.array, length(mem), Inst[], true)
        return memory_object_global!(img, mem, arr)
    end
    if el.kind === Inline && !ml.boxed && !(ml.storage isa RefType)
        # numbers: the bytes of the leaves
        return memory_object_global!(img, mem, numeric_memory_global!(img, mem, ml))
    end
    # references (to objects, or boxes of inline elements)
    n = length(mem) * ml.stride
    push!(img.inprogress, mem)
    back = Any[]
    elems = Inst[]
    try
        for i in 1:length(mem)
            if !isassigned(mem, i)
                append!(elems, Inst[Inst(:ref_null, (ml.storage::RefType).heap) for _ in 1:ml.stride])
                continue
            end
            v = mem[i]
            if ml.boxed
                push!(elems, Inst(:global_get, boxed_object_global!(img, v)))
            else
                append!(elems, field_init!(img, v, E, back, i - 1))
            end
        end
    finally
        delete!(img.inprogress, mem)
    end
    fixed = n <= MAX_FIXED_ELEMENTS
    g = add_array_global!(img, nothing, ml.array, n, fixed ? elems : Inst[], !fixed)
    obj = memory_object_global!(img, mem, g)
    if !fixed
        # set by the start function, element by element
        for (i, e) in enumerate(elems)
            push!(img.init, Inst(:global_get, g), Inst(:i32_const, i - 1), e,
                  Inst(:array_set, ml.array))
        end
    end
    for (i, v, FT) in back
        push!(img.patches, (g, :array, ml.array, i * ml.stride, v, FT))
    end
    return obj
end

# a global of the array type `arr` with `n` elements: `elems` (array.new_fixed), or
# default ones (array.new_default)
function add_array_global!(img::Image, @nospecialize(x), arr::TypeRef, n::Int,
                           elems::Vector{Inst}, default::Bool)
    init = if default
        Inst[Inst(:i32_const, n), Inst(:array_new_default, arr)]
    else
        Inst[elems..., Inst(:array_new_fixed, arr, n)]
    end
    g = add_global!(img.cgm.mod, x === nothing ? string("jl_array#", img.counter += 1) : global_name(img, x),
                    RefType(arr, false), false, init)
    return g
end

# the bytes of the array elements of a memory of numbers, in the order of the leaves
function leaf_bytes(mem, ml::MemoryLayout)
    io = IOBuffer()
    for i in 1:length(mem)
        insts = const_leaves_bits(mem[i])
        for x in insts
            write_storage_bytes(io, x, ml.storage, ml.widened)
        end
    end
    return take!(io)
end

# the primitive leaves of an isbits value, as Julia values
function const_leaves_bits(@nospecialize(x))
    T = typeof(x)
    if isprimitivetype(T) && sizeof(T) == 16
        # two 64-bit leaves: low, high
        u = Core.bitcast(UInt128, x)
        return Any[UInt64(u & typemax(UInt64)), UInt64(u >> 64)]
    end
    isprimitivetype(T) && return Any[x]
    out = Any[]
    for i in 1:fieldcount(T)
        append!(out, const_leaves_bits(getfield(x, i)))
    end
    return out
end

function write_storage_bytes(io::IO, @nospecialize(x), st::StorageType, widened::Bool=false)
    T = typeof(x)
    if widened
        # zero-extended bits
        sz = sizeof(T)
        u = sz == 8 ? Core.bitcast(UInt64, x) : sz == 4 ? UInt64(Core.bitcast(UInt32, x)) :
            sz == 2 ? UInt64(Core.bitcast(UInt16, x)) : UInt64(Core.bitcast(UInt8, x))
        write(io, htol(u))
    elseif st === I8
        write(io, Core.bitcast(UInt8, x))
    elseif st === I16
        write(io, Core.bitcast(UInt16, x))
    elseif st === I32 || st === F32
        write(io, htol(sizeof(T) == 4 ? Core.bitcast(UInt32, x) : UInt32(Core.bitcast(UInt8, x))))
    elseif st === I64 || st === F64
        write(io, htol(Core.bitcast(UInt64, x)))
    else
        error("storage $st")
    end
end

function numeric_memory_global!(img::Image, mem, ml::MemoryLayout)
    n = length(mem) * ml.stride
    bytes = leaf_bytes(mem, ml)
    if length(bytes) <= MAX_FIXED_BYTES
        elems = Inst[]
        for i in 1:length(mem), x in const_leaves_bits(mem[i])
            st = ml.storage
            if ml.widened
                sz = sizeof(x)
                u = sz == 8 ? Core.bitcast(UInt64, x) : sz == 4 ? UInt64(Core.bitcast(UInt32, x)) :
                    sz == 2 ? UInt64(Core.bitcast(UInt16, x)) : UInt64(Core.bitcast(UInt8, x))
                push!(elems, Inst(:i64_const, reinterpret(Int64, u)))
            elseif st === F64
                push!(elems, Inst(:f64_const, Float64(x)))
            elseif st === F32
                push!(elems, Inst(:f32_const, Float32(x)))
            elseif st === I64
                push!(elems, Inst(:i64_const, reinterpret(Int64, Core.bitcast(UInt64, x))))
            else
                push!(elems, primitive_const(x, Leaf[])[1])
            end
        end
        return add_array_global!(img, nothing, ml.array, n, elems, false)
    end
    return data_array_global!(img, nothing, ml.array, n, bytes)
end

# an array global filled by the start function from a data segment
function data_array_global!(img::Image, @nospecialize(x), arr::TypeRef, n::Int,
                            bytes::Vector{UInt8})
    g = add_array_global!(img, x, arr, n, Inst[], true)
    seg = add_data!(img.cgm.mod, bytes)
    push!(img.init, Inst(:global_get, g), Inst(:i32_const, 0), Inst(:i32_const, 0),
          Inst(:i32_const, n), Inst(:array_init_data, arr, seg))
    return g
end

function array_global!(img::Image, @nospecialize(x), bytes, ::Type{UInt8})
    arr = array_type!(types(img), I8)
    n = length(bytes)
    if n <= MAX_FIXED_BYTES
        elems = Inst[Inst(:i32_const, Int32(b)) for b in bytes]
        return add_array_global!(img, x, arr, n, elems, false)
    end
    return data_array_global!(img, x, arr, n, Vector{UInt8}(bytes))
end

## global variables

"""
    nonconst_global(fc, ref) -> CGVal

A read of the global variable `ref`: mutable globals of the module (one per leaf of its
declared type), initialized with its value at compile time.
"""
function nonconst_global(fc::FnCtx, ref::GlobalRef)
    T, gs, def = global_var!(fc.cgm.image, ref)
    if def !== nothing
        # not assigned yet: an UndefVarError
        emit!(fc.b, :global_get, def); emit!(fc.b, :i32_eqz)
        if!(fc.b); throw_error!(fc, Runtime.throw_undefvar_error, () -> const_value(fc, ref.name)); end!(fc.b)
    end
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    for g in gs
        emit!(fc.b, :global_get, g)
    end
    return pop_val!(fc, T)
end

function global_var!(img::Image, ref::GlobalRef)
    key = (ref.mod, ref.name)
    haskey(img.vars, key) && return img.vars[key]
    T = Base.invoke_in_world(img.cgm.world.world, Core.get_binding_type, ref.mod, ref.name)
    ts = types(img)
    l = layout(ts, T)
    defined = Base.invoke_in_world(img.cgm.world.world, isdefinedglobal, ref.mod, ref.name)
    inits = if defined
        v = Base.invoke_in_world(img.cgm.world.world, getglobal, ref.mod, ref.name)
        const_leaves(img, v, T)
    else
        Inst[default_inst(leaf.type) for leaf in l.leaves]
    end
    gs = Global[]
    for (i, leaf) in enumerate(l.leaves)
        name = string("jl_global_", ref.mod, "_", ref.name, length(l.leaves) > 1 ? "_$i" : "")
        push!(gs, add_global!(img.cgm.mod, name, leaf.type, true, Inst[inits[i]]))
    end
    # a variable without a value at compile time: whether it has one since
    def = defined ? nothing :
          add_global!(img.cgm.mod, string("jl_global_", ref.mod, "_", ref.name, "_defined"),
                      I32, true, Inst[Inst(:i32_const, 0)])
    img.vars[key] = (T, gs, def)
    return (T, gs, def)
end

"`isdefined` of the global variable `ref`."
function isdefined_global!(fc::FnCtx, ref::GlobalRef)
    const_global(fc.cgm.world.world, ref.mod, ref.name) === nothing || return const_value(fc, true)
    _, _, def = global_var!(fc.cgm.image, ref)
    def === nothing && return const_value(fc, true)
    emit!(fc.b, :global_get, def)
    return pop_val!(fc, Bool)
end

"Write the global variable `ref` (a `setglobal!`)."
function set_global_var!(fc::FnCtx, ref::GlobalRef, v::CGVal)
    T, gs, def = global_var!(fc.cgm.image, ref)
    v = convert_repr(fc, v, T)
    v.kind === Bottom && return v
    push_val!(fc, v)
    for g in Iterators.reverse(gs)
        emit!(fc.b, :global_set, g)
    end
    def === nothing || (emit!(fc.b, :i32_const, 1); emit!(fc.b, :global_set, def))
    return v
end

## finishing

"""
    finish_image!(cgm)

Add the start function, which completes the objects of the image (references in cycles,
large arrays).
"""
function finish_image!(cgm::CGModule)
    img = cgm.image
    for (g, kind, wtype, idx, v, FT) in img.patches
        if kind === :struct
            push!(img.init, Inst(:global_get, g))
            append!(img.init, const_leaves(img, v, FT))
            push!(img.init, Inst(:struct_set, wtype, idx))
        else
            push!(img.init, Inst(:global_get, g), Inst(:i32_const, idx))
            append!(img.init, const_leaves(img, v, FT))
            push!(img.init, Inst(:array_set, wtype))
        end
    end
    empty!(img.patches)
    isempty(img.init) && return
    f = add_func!(cgm.mod, "jl_init_image", ValType[], ValType[])
    b = Builder(cgm.mod, f)
    for inst in img.init
        emit!(b, inst.op, inst.imm...)
    end
    finish!(b)
    cgm.mod.start = f
end

# runtime objects serialized with their header only (modules are named objects, above)
const OPAQUE_RUNTIME_TYPES = Any[Core.CodeInstance, Core.MethodInstance, Method]

function opaque_object_global!(img::Image, @nospecialize(x))
    ts = types(img)
    init = Inst[Inst(:i32_const, typeid!(ts, typeof(x))), header_hash(img, x), Inst(:struct_new, ts.jlvalue)]
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(ts.jlvalue, false), false, init)
    img.globals[x] = g
    return g
end
