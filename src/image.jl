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
    "Instructions of the start function once the objects are complete: the runtime's state the
    host seeds (`seed_from_host!`), which no field of a shell may overwrite."
    late::Vector{Inst}
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
    "The function being emitted, or whose deferred value is being serialized (else `nothing`)."
    owner::Any
    "Whether a deferred value failed to serialize: the start function then traps."
    failed::Bool
    "Whether the functions being emitted are optional ones (objectid cases), and those functions."
    optional_mode::Bool
    optional::IdSet{Any}
    "The objects an optional function serialized first, and the other functions that reached them."
    created::IdDict{Any,Any}
    dependents::IdDict{Any,Vector{Any}}
    "The optional functions whose deferred values failed."
    failed_owners::IdSet{Any}
    "Per optional function: the errors not reported while it is optional, and the optional
    functions it needed first."
    suppressed::IdDict{Any,Vector{Any}}
    optional_children::IdDict{Any,Vector{Any}}
end

Image(cgm) = Image(cgm, IdDict{Any,Global}(), IdDict{Any,Global}(), IdDict{Any,Global}(),
                   IdSet{Any}(), Inst[], Inst[], Any[],
                   Dict{Tuple{Module,Symbol},Tuple{Any,Vector{Global},Union{Nothing,Global}}}(), IdDict{Any,Global}(), 0,
                   UInt64[], nothing, false, false, IdSet{Any}(), IdDict{Any,Any}(), IdDict{Any,Vector{Any}}(),
                   IdSet{Any}(), IdDict{Any,Vector{Any}}(), IdDict{Any,Vector{Any}}())

"""
    header_hash(img, x) -> Inst

The hash field of the header of the object `x`: of a mutable object, -k for its native
`objectid`, the k-th of `img.native_ids` (so that hash tables built natively find it, see
`objectid_mutable_func!`); of others, 0 (none assigned yet).
"""
function header_hash(img::Image, @nospecialize(x))
    ismutable(x) && !(x isa String) || return Inst(:i32_const, 0)
    return native_id_hash(img, x)
end

# the header hash referring to the native `objectid` of `x`
function native_id_hash(img::Image, @nospecialize(x))
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

## pointers of the build process
#
# As native image serialization writes them (src/staticdata.c, `jl_write_values` and
# `get_replaceable_field`): an address means nothing once the image is loaded, so a `Ptr`
# field of a mutable object (not `const`, from Julia 1.13.3), a `Ptr` boxed in a field of a
# mutable object that is not `const` (or in a reference slot of a value stored inline in such
# a field), and the elements of a memory of `Ptr`s, or boxed in a memory (or in the reference
# slots of its inline elements), are C_NULL, but for the value -1 (`MAP_FAILED`,
# `INVALID_HANDLE_VALUE`), and so is the value of a global variable (a `Core.Binding`'s value).
# E.g. a `Regex`'s compiled pattern is null, and Base compiles it again when the `Regex` is
# first used. The slots are native ones: a value stored inline natively but an object here
# (more than `MAX_INLINE_LEAVES` leaves) is reset as where it is stored (`reset_object_global!`),
# and a tuple's elements, inline natively, are not memory elements here either
# (`tuple_array_global!`). Other pointers (of immutable objects, such as a tuple a field of
# abstract type holds, or of a constant) are written as they are natively, which here is
# unsupported but for null and -1 (`check_build_pointer`); `Config(image_pointer_fields)`
# keeps a field's as it is.

is_cpointer_type(@nospecialize(T)) = T isa DataType && T.name === Ptr.body.name

"The pointer `p` where the image resets pointers (see above): null, but for -1."
reset_pointer(p::Ptr) = reinterpret(UInt, p) == typemax(UInt) ? p : typeof(p)(C_NULL)

"The value of the `i`th field of the object `x` as the image has it: a `Ptr` field of a mutable object reset (see above)."
function image_field(@nospecialize(x), i::Int)
    v = getfield(x, i)
    T = typeof(x)
    # (a `const` one too before Julia 1.13.3)
    # (1.14 development builds before JuliaLang/julia#63886 still reset `const` fields)
    ismutabletype(T) && is_cpointer_type(fieldtype(T, i)) && (VERSION < v"1.13.3" || !isconst(T, i)) &&
        return reset_pointer(v)
    return v
end

"Whether the image resets the pointers boxed in the `i`th field of objects of type `T` (see above)."
resets_boxed_pointers(@nospecialize(T), i::Int) = ismutabletype(T) && !isconst(T, i)

"""
The key of the box or object of the inline value `x` whose reference slots the image resets
(see above), apart from the one of `x` where they are not.
"""
struct ResetPointers
    x::Any
end

"The element `v` of a memory of element type `E` as the image has it: a pointer reset (see above)."
image_element(@nospecialize(E), @nospecialize(v)) =
    v isa Ptr && (is_cpointer_type(E) || !Base.allocatedinline(E)) ? reset_pointer(v) : v

"""
    const_leaves(img, x, FT; reset_pointers=false) -> Vector{Inst}

The leaves of the value `x` stored where the declared type is `FT` (a field, an
element): constant instructions, `global.get`s of objects. With `reset_pointers`, where the
image resets the pointers boxed in reference slots (see `image_field`).
"""
function const_leaves(img::Image, @nospecialize(x), @nospecialize(FT); raw_pointer::Bool=false,
                      reset_pointers::Bool=false)
    ts = types(img)
    lf = layout(ts, FT)
    lf.kind === Ghost && return Inst[]
    if lf.kind === Inline
        T = typeof(x)
        if is_ptr_type(T)
            check_build_pointer(x, raw_pointer)
            return Inst[Inst(:i64_const, reinterpret(Int64, reinterpret(UInt64, x))), Inst(:ref_null, ts.jlvalue)]
        end
        isprimitivetype(T) && return primitive_const(x, lf.leaves)
        if is_memoryref_type(T)
            mem = x.mem
            g = object_global!(img, mem)
            return Inst[Inst(:global_get, g), Inst(:global_get, img.arrays[mem]),
                        Inst(:i32_const, Int32(Base.memoryrefoffset(x) - 1))]
        end
        leaves = Inst[]
        # (as the declared type stores its fields: a tuple's union elements, boxed)
        S = isconcretetype(FT) ? T : FT
        # (the pointers boxed in its reference slots are reset where it is stored inline
        # natively too, not where it is an object of its own)
        reset_inner = reset_pointers && Base.allocatedinline(FT)
        for i in 1:fieldcount(T)
            FTi = fieldtype(S, i)
            if isdefined(x, i)
                raw = (T, fieldname(T, i)) in img.cgm.config.image_pointer_fields
                append!(leaves, const_leaves(img, getfield(x, i), FTi; raw_pointer=raw,
                                             reset_pointers=reset_inner && !raw))
            else
                append!(leaves, Inst[default_inst(l.type) for l in field_leaves(ts, FTi)])
            end
        end
        return leaves
    end
    # a reference
    if lf.wtype == ts.jlvalue
        # (a pointer in a reference slot natively too)
        reset_pointers && x isa Ptr && !Base.allocatedinline(FT) && (x = reset_pointer(x))
        return Inst[Inst(:global_get, boxed_object_global!(img, x; raw_pointer))]
    elseif lf.elements !== nothing && layout(ts, typeof(x)).wtype != lf.wtype
        # a tuple stored where the declared type is a tuple of unknown length (`VersionNumber`'s
        # `prerelease`) of another storage of its elements: an array object of the declared
        # element type
        key = (x, lf.wtype)
        haskey(img.boxes, key) && (note_reach!(img, key); return Inst[Inst(:global_get, img.boxes[key])])
        note_created!(img, key)
        g = get!(() -> tuple_array_global!(img, x, lf; register=false), img.boxes, key)
        return Inst[Inst(:global_get, g)]
    end
    # (stored inline natively, where the image resets the pointers boxed in it)
    reset_pointers && Base.allocatedinline(FT) && !isbits(x) && !ismutable(x) &&
        return Inst[Inst(:global_get, reset_object_global!(img, x))]
    return Inst[Inst(:global_get, object_global!(img, x))]
end

# A pointer from the build process: an address without owner, which means nothing in Wasm.
# Only a null pointer, -1 (not an address: `MAP_FAILED`, `INVALID_HANDLE_VALUE`), or one in a
# field allowlisted by `Config(image_pointer_fields)`, is serialized (as its address); where the
# image resets pointers, they are null already (see `image_field`).
function check_build_pointer(@nospecialize(x), raw_pointer::Bool)
    addr = reinterpret(UInt64, x)
    addr == 0 || addr == typemax(UInt64) || raw_pointer ||
        unsupported("a pointer of the build process in the image (a ", typeof(x), " of address 0x",
                    string(addr, base=16), "): serialize it as C_NULL (sanitize the global ",
                    "before compiling) or allowlist its field with Config(image_pointer_fields)")
    return nothing
end

## objects

"""
    boxed_object_global!(img, x) -> Global

A global holding `x` as a `\$JlValue`: its object if it is one, else a box (for inline
values, ghosts, `Memory` and `String`). With `reset_pointers`, the box of an inline value
natively inline where the image resets pointers (an element of a memory: see `image_field`).
"""
function boxed_object_global!(img::Image, @nospecialize(x); raw_pointer::Bool=false,
                              reset_pointers::Bool=false)
    ts = types(img)
    T = typeof(x)
    l = layout(ts, T)
    if l.kind === Boxed
        return reset_pointers && !isbits(x) && !ismutable(x) ? reset_object_global!(img, x) : object_global!(img, x)
    elseif l.kind === Ghost
        return singleton_global!(img, T)
    end
    # (a pointer, where it is boxed: checked at each use, as equal pointers share a box)
    is_ptr_type(T) && check_build_pointer(x, raw_pointer)
    # isbits values are boxed once per value; others (Memory, String) per object (and per
    # whether the pointers in their reference slots are reset)
    key = reset_pointers && !isbits(x) ? ResetPointers(x) : x
    haskey(img.boxes, key) && (note_reach!(img, key); return img.boxes[key])
    note_created!(img, key)
    get!(img.boxes, key) do
        box = box_type!(ts, T)
        init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0)]
        append!(init, const_leaves(img, x, T; raw_pointer, reset_pointers))
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
    # The build's root task is the module's own, as a native image has it: the loading process's
    # root task, not a copy (src/staticdata.c, `TagRef` 0). Its fields (task-local storage, ...)
    # are not serialized: a value that refers to it (the key of a per-task cache, a WeakRef) does
    # not bring them in.
    x === Base.roottask && return root_task_global!(img.cgm)
    g = get(img.globals, x, nothing)
    if g !== nothing
        note_reach!(img, x)
        return g
    end
    note_created!(img, x)
    return new_object_global!(img, x)
end

"""
    reset_object_global!(img, x) -> Global

The global of the immutable `x`, an object here, where natively it is stored inline in a slot
whose boxed pointers the image resets (a field of a mutable object, a memory's element: see
`image_field`): with the pointers boxed in its reference slots reset.
"""
function reset_object_global!(img::Image, @nospecialize(x))
    key = ResetPointers(x)
    g = get(img.globals, key, nothing)
    g === nothing || (note_reach!(img, key); return g)
    note_created!(img, key)
    l = layout(types(img), typeof(x))
    g = l.elements !== nothing ? tuple_array_global!(img, x, l; register=false, reset_pointers=true) :
                                 struct_global!(img, x, l; register=false, reset_pointers=true)
    img.globals[key] = g
    return g
end

# `x` (an object, a box's value or a global variable's key) serialized first by an optional function
note_created!(img::Image, @nospecialize(x)) =
    img.owner in img.optional && !haskey(img.created, x) && (img.created[x] = img.owner)

# an object, box or global variable serialized before by another function: an optional function's
# makes the function reaching it depend on that one's deferred values
function note_reach!(img::Image, @nospecialize(x))
    c = get(img.created, x, nothing)
    (c === nothing || c === img.owner) && return
    c in img.failed_owners &&
        unsupported("a value whose deferred value could not be serialized (reached first by ", c.mi, ")")
    push!(get!(() -> Any[], img.dependents, c), img.owner)
    return
end

function new_object_global!(img::Image, @nospecialize(x))
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
    elseif T === Task
        # (the root task is the module's own, `object_global!`) as natively: "Task cannot be
        # serialized" (src/staticdata.c, `jl_queue_for_serialization`)
        unsupported("serializing a Task of the build (other than its root task)")
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
# type of where it is stored); its elements are the tuple's, inline natively (not a memory's:
# a pointer is kept), with the pointers boxed in their reference slots reset with
# `reset_pointers` (see `image_field`)
function tuple_array_global!(img::Image, @nospecialize(x), l::Layout; register::Bool=true,
                             reset_pointers::Bool=false)
    ts = types(img)
    T = typeof(x)
    n = x isa Core.SimpleVector ? length(x) : fieldcount(T)
    mem = Memory{(l.elements::MemoryLayout).elem.T}(undef, n)
    for i in 1:n
        mem[i] = x[i]
    end
    memory_global!(img, mem; tuple_reset=reset_pointers)
    arr = img.arrays[mem]
    init = Inst[Inst(:i32_const, typeid!(ts, T)), Inst(:i32_const, 0), Inst(:global_get, arr),
                Inst(:struct_new, l.wtype)]
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    register && (img.globals[x] = g)
    return g
end

# a type object: its header and the id of the type it is (the module's one object of the
# type it represents, whose `objectid` is the native one: see `is_type_object_type`)
function type_object_global!(img::Image, @nospecialize(x::Type))
    ts = types(img)
    st = type_object_type!(ts)
    init = Inst[Inst(:i32_const, typeid!(ts, typeof(x))), native_id_hash(img, x),
                Inst(:i32_const, typeid!(ts, x)), Inst(:struct_new, st)]
    name = string("jl_type_", replace(typename_str(x), r"[^A-Za-z0-9_]" => "_"), "_", typeid!(ts, x))
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
# null for references to objects being serialized (cycles), recorded in `back` (with whether
# the image resets the pointers boxed in them)
function field_init!(img::Image, @nospecialize(v), @nospecialize(FT), back::Vector{Any}, slot;
                     raw_pointer::Bool=false, reset_pointers::Bool=false)
    ts = types(img)
    lf = layout(ts, FT)
    if lf.kind === Boxed
        target = lf.wtype == ts.jlvalue && layout(ts, typeof(v)).kind !== Boxed ? nothing : v
        if target !== nothing && target in img.inprogress
            push!(back, (slot, v, FT, reset_pointers))
            return Inst[Inst(:ref_null, lf.leaves[1].type.heap)]
        end
    end
    return const_leaves(img, v, FT; raw_pointer, reset_pointers)
end

# (`reset_pointers`: an immutable stored inline natively where the image resets the pointers
# boxed in it: see `reset_object_global!`)
function struct_global!(img::Image, @nospecialize(x), l::Layout; register::Bool=true,
                        reset_pointers::Bool=false)
    ts = types(img)
    T = typeof(x)
    img.cgm.config.shell_first_mutables && ismutabletype(T) && return mutable_global!(img, x, l)
    push!(img.inprogress, x)
    back = Any[]
    init = Inst[Inst(:i32_const, typeid!(ts, T)), header_hash(img, x)]
    try
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            if isdefined(x, i)
                raw = (T, fieldname(T, i)) in img.cgm.config.image_pointer_fields
                append!(init, field_init!(img, raw ? getfield(x, i) : image_field(x, i), FT, back,
                                          first(l.fields[i]) - 1; raw_pointer=raw,
                                          reset_pointers=!raw && (reset_pointers || resets_boxed_pointers(T, i))))
            else
                append!(init, Inst[default_inst(leaf.type) for leaf in field_leaves(ts, FT)])
            end
        end
    finally
        delete!(img.inprogress, x)
    end
    push!(init, Inst(:struct_new, l.wtype))
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    register && (img.globals[x] = g)
    if !isempty(back)
        ismutabletype(T) || unsupported("a cycle of objects through the immutable ", T)
        for (wfield, v, FT, reset) in back
            push!(img.patches, (g, :struct, l.wtype, wfield, v, FT, img.owner, reset))
        end
    end
    return g
end

# (`tuple_reset`: the array of a tuple, see `tuple_array_global!`)
function memory_global!(img::Image, mem; tuple_reset::Union{Nothing,Bool}=nothing)
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
            # (a tuple's pointer elements are inline natively: kept)
            reset = tuple_reset === nothing ? (v = image_element(E, v); true) : tuple_reset && !(v isa Ptr)
            if ml.boxed
                push!(elems, Inst(:global_get, boxed_object_global!(img, v; reset_pointers=reset && Base.allocatedinline(E))))
            else
                append!(elems, field_init!(img, v, E, back, i - 1; reset_pointers=reset))
            end
        end
    finally
        delete!(img.inprogress, mem)
    end
    fixed = n <= MAX_FIXED_ELEMENTS
    g = add_array_global!(img, nothing, ml.array, n, fixed ? elems : Inst[], !fixed)
    obj = memory_object_global!(img, mem, g)
    if !fixed
        # set by the start function, element by element, but for the null references:
        # array.new_default created every slot null (a hash table's unused slots stay so)
        for (i, e) in enumerate(elems)
            e.op === :ref_null && continue
            push!(img.init, Inst(:global_get, g), Inst(:i32_const, i - 1), e,
                  Inst(:array_set, ml.array))
        end
    end
    for (i, v, FT, reset) in back
        push!(img.patches, (g, :array, ml.array, i * ml.stride, v, FT, img.owner, reset))
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
        # not assigned yet (or never declared): an UndefVarError of the name in the module it
        # is read from (an import's, not the original's), as natively
        emit!(fc.b, :global_get, def); emit!(fc.b, :i32_eqz)
        if!(fc.b)
        throw_error!(fc, Runtime.throw_undefvar_error, () -> const_value(fc, ref.name), () -> const_value(fc, ref.mod))
        end!(fc.b)
    end
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    for g in gs
        emit!(fc.b, :global_get, g)
    end
    return pop_val!(fc, T)
end

"""
    canonical_ref(world, ref) -> GlobalRef

The binding `ref` is in `world`: the original of an imported one (`using M: x as y`, or an
implicit `using`), through every import, else itself. (Only a partition of a kind importing
a binding links to one: a constant's restriction is its value, which may be a binding.)
"""
function canonical_ref(world::UInt, ref::GlobalRef)
    b = convert(Core.Binding, ref)
    seen = IdSet{Core.Binding}()
    while true
        b in seen && error("WasmCodegen: a cycle of imports at ", b.globalref)
        push!(seen, b)
        p = Base.invoke_in_world(world, Base.lookup_binding_partition, world, b)
        # (as the compiler's `walk_binding_partition`)
        Base.is_some_binding_imported(Base.binding_kind(p)) || break
        b = Base.partition_restriction(p)::Core.Binding
    end
    return b.globalref
end

function global_var!(img::Image, ref::GlobalRef)
    # (a binding imported into a module, maybe renamed, is the original's: one variable)
    ref = canonical_ref(img.cgm.world.world, ref)
    key = (ref.mod, ref.name)
    haskey(img.vars, key) && (note_reach!(img, key); return img.vars[key])
    note_created!(img, key)
    T = Base.invoke_in_world(img.cgm.world.world, Core.get_binding_type, ref.mod, ref.name)
    ts = types(img)
    l = layout(ts, T)
    defined = Base.invoke_in_world(img.cgm.world.world, isdefinedglobal, ref.mod, ref.name)
    inits = if defined
        v = Base.invoke_in_world(img.cgm.world.world, getglobal, ref.mod, ref.name)
        # (a pointer reset, as natively in the binding's value: see `image_field`)
        const_leaves(img, v isa Ptr ? reset_pointer(v) : v, T)
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
large arrays): for WASI, the exported `_initialize` instead (`host.jl`).
"""
function finish_image!(cgm::CGModule)
    img = cgm.image
    ts = types(img)
    isempty(img.init) && isempty(img.patches) && isempty(img.late) && !img.failed && return
    f = add_func!(cgm.mod, "jl_init_image", ValType[], ValType[])
    b = Builder(cgm.mod, f)
    ninit = length(img.init)
    for k in 1:ninit
        inst = img.init[k]
        emit!(b, inst.op, inst.imm...)
    end
    # field and element values set once every global exists (cycles, shells of mutable objects);
    # serializing a value may add patches of its own to the end
    i = 0
    while i < length(img.patches)
        i += 1
        p = img.patches[i]
        g, kind, wtype, idx, v, FT = p
        kind === :failed && continue
        if kind === :struct || kind === :struct_insts
            leaves = kind === :struct_insts ? v : const_leaves(img, v, FT; reset_pointers=length(p) >= 8 && p[8]::Bool)
            lf = layout(ts, FT)
            if lf.kind === Boxed || length(lf.leaves) == 1
                emit!(b, :global_get, g)
                for inst in leaves; emit!(b, inst.op, inst.imm...); end
                emit!(b, :struct_set, wtype, idx)
            else
                # an inline value of several leaves: through locals, one struct.set per leaf
                locals = [add_local!(f, leaf.type) for leaf in lf.leaves]
                for inst in leaves; emit!(b, inst.op, inst.imm...); end
                for k in length(locals):-1:1; emit!(b, :local_set, locals[k]); end
                for k in 1:length(locals)
                    emit!(b, :global_get, g)
                    emit!(b, :local_get, locals[k])
                    emit!(b, :struct_set, wtype, idx + k - 1)
                end
            end
        else
            emit!(b, :global_get, g)
            emit!(b, :i32_const, idx)
            for inst in (kind === :array_insts ? v : const_leaves(img, v, FT; reset_pointers=length(p) >= 8 && p[8]::Bool))
                emit!(b, inst.op, inst.imm...)
            end
            emit!(b, :array_set, wtype)
        end
    end
    empty!(img.patches)
    # what serializing the values of the patches added to the start function (the fields of the
    # root task, the elements of a large memory), after them: they only store into objects
    for k in ninit+1:length(img.init)
        inst = img.init[k]
        emit!(b, inst.op, inst.imm...)
    end
    for inst in img.late
        emit!(b, inst.op, inst.imm...)
    end
    img.failed && unreachable!(b)
    finish!(b)
    if cgm.config.host === :wasi
        add_export!(cgm.mod, "_initialize", f)
    else
        cgm.mod.start = f
    end
end

# With `Config(shell_first_mutables = true)` a mutable object exists before its fields: its global
# holds a shell (header and default fields), so that any object reached from its fields may refer
# back to it, and the start function sets its fields.
function mutable_global!(img::Image, @nospecialize(x), l::Layout)
    ts = types(img)
    T = typeof(x)
    init = Inst[Inst(:i32_const, typeid!(ts, T)), header_hash(img, x)]
    for i in 1:fieldcount(T)
        append!(init, Inst[default_inst(leaf.type) for leaf in field_leaves(ts, fieldtype(T, i))])
    end
    push!(init, Inst(:struct_new, l.wtype))
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(l.wtype, false), false, init)
    img.globals[x] = g
    for i in 1:fieldcount(T)
        isdefined(x, i) || continue
        FT = fieldtype(T, i)
        isempty(field_leaves(ts, FT)) && continue
        if (T, fieldname(T, i)) in img.cgm.config.image_pointer_fields
            # (an allowlisted pointer keeps its address, as when the object is serialized whole)
            push!(img.patches, (g, :struct_insts, l.wtype, first(l.fields[i]) - 1,
                                const_leaves(img, getfield(x, i), FT; raw_pointer=true), FT, img.owner))
        else
            # (with whether the pointers boxed in it are reset, as when the object is serialized whole)
            push!(img.patches, (g, :struct, l.wtype, first(l.fields[i]) - 1, image_field(x, i), FT, img.owner,
                                resets_boxed_pointers(T, i)))
        end
    end
    return g
end

"""
    prepare_image_patches!(cgm) -> Bool

Serialize the values of the image's pending field and element patches into instructions now,
while functions and types can still be added: an object reached only through a patch may need a
function or a type id (and its objectid case) of its own. Returns whether any patch was prepared.
Patches the serialization adds are prepared too.
"""
# `f()` with `owner` as the function that the values deferred meanwhile are attributed to
function with_image_owner(f, img::Image, @nospecialize(owner))
    prev = img.owner
    img.owner = owner
    try
        return f()
    finally
        img.owner = prev
    end
end

function prepare_image_patches!(cgm::CGModule)
    img = cgm.image
    prepared = false
    i = 0
    while i < length(img.patches)
        i += 1
        p = img.patches[i]
        g, kind, wtype, idx, v, FT = p
        (kind === :struct || kind === :array) || continue
        owner = length(p) >= 7 ? p[7] : nothing
        reset = length(p) >= 8 && p[8]::Bool
        leaves = try
            with_image_owner(() -> const_leaves(img, v, FT; reset_pointers=reset), img, owner)
        catch err
            err isa Unsupported || rethrow()
            deferred_value_failed!(cgm, err, owner, FT)
            nothing
        end
        img.patches[i] = leaves === nothing ? (g, :failed, wtype, idx, nothing, FT) :
                         (g, kind === :struct ? :struct_insts : :array_insts, wtype, idx, leaves, FT)
        prepared = true
    end
    return prepared
end

# A deferred value that cannot be serialized is an unsupported construct of the function that reached
# its object, as a statement's is (a diagnostic, and the function traps), and the start function
# traps: the object may be shared. A failure of an optional function (an objectid case) traps that
# function only, as its statements' do, and fails the functions that reached its objects.
function deferred_value_failed!(cgm::CGModule, err::Unsupported, @nospecialize(owner), @nospecialize(FT))
    push!(err.context, string("the value of a field of declared type ", FT, ", set by the start function"))
    fail_owner!(cgm, err, owner)
    return nothing
end

function fail_owner!(cgm::CGModule, err::Unsupported, @nospecialize(owner))
    img = cgm.image
    owner === nothing && throw(err)
    owner in img.failed_owners && return
    trap_function!(cgm, owner)
    push!(img.failed_owners, owner)
    owner in img.optional && push!(get!(() -> Any[], img.suppressed, owner), owner.mi => err)
    if !(owner in img.optional)
        push!(err.context, owner.mi)
        push!(cgm.diagnostics, owner.mi => err)
        img.failed = true
    end
    for d in get(img.dependents, owner, Any[])
        fail_owner!(cgm, err, d)
    end
end

function trap_function!(cgm::CGModule, info)
    empty!(info.func.body)
    empty!(info.func.locals)
    b = Builder(cgm.mod, info.func)
    unreachable!(b)
    finish!(b)
end

# runtime objects serialized with their header only (modules are named objects, above): a
# `GlobalRef`'s binding too (whose `globalref` refers back to it)
const OPAQUE_RUNTIME_TYPES = Any[Core.CodeInstance, Core.MethodInstance, Method, Core.Binding]

function opaque_object_global!(img::Image, @nospecialize(x))
    ts = types(img)
    init = Inst[Inst(:i32_const, typeid!(ts, typeof(x))), header_hash(img, x), Inst(:struct_new, ts.jlvalue)]
    g = add_global!(img.cgm.mod, global_name(img, x), RefType(ts.jlvalue, false), false, init)
    img.globals[x] = g
    return g
end
