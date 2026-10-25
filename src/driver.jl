# The driver: from entry points to a module.

"""
    Entry(f, argtypes; name)

An entry point of a module: the function `f` called with arguments of types `argtypes`,
exported as `name`.
"""
struct Entry
    f::Any
    argtypes::Tuple
    name::String
end
Entry(f, argtypes::Tuple; name::AbstractString=string(nameof(f))) = Entry(f, argtypes, String(name))

"""
    Compilation

The result of a compilation: the module's bytes, the closed world, the code generator's
state (for inspection) and its diagnostics.
"""
struct Compilation
    bytes::Vector{UInt8}
    world::ClosedWorld
    cgm::CGModule
end

"""
    compile(entries; config=Config(), validate=true) -> Compilation

Compile the entry points (`Entry`s, or `(f, argtypes)` tuples) and everything they call
to a WebAssembly module, as juliac compiles a program: the closed world of the entry
points is collected, compiled, and the objects it refers to are serialized into the
module.
"""
function compile(entries::Vector; config::Config=Config(), validate::Bool=true,
                 world::Union{Nothing,UInt}=nothing)
    entries = Entry[e isa Entry ? e : Entry(e[1], e[2]) for e in entries]
    run(program_world) = Base.invoke_in_world(COMPILER_WORLD[], compile_in_world, entries,
                                              config, validate, program_world)
    if config.trim_patches && world === nothing
        # the program in the latest world, with juliac's patches
        return with_trim_patches() do _, _
            run(Base.get_world_counter())
        end
    end
    return run(something(world, Base.get_world_counter()))
end

function compile_in_world(entries::Vector{Entry}, config::Config, validate::Bool, world::UInt)
    mis = Core.MethodInstance[entry_instance(e.f, e.argtypes; world) for e in entries]
    w = collect_world(mis; world, verify=config.verify)
    mode = exception_mode(w)
    local cgm
    while true
        cgm = CGModule(w, config, mode)
        for (e, mi) in zip(entries, mis)
            info = get_function!(cgm, mi)
            add_export!(cgm.mod, e.name, info.func)
        end
        process_worklist!(cgm)
        compile_objectid_cases!(cgm)
        # serializing deferred image values can need functions and types of their own: to a fixed
        # point of preparing them, emitting the functions and compiling the objectid cases
        while prepare_image_patches!(cgm) || !isempty(cgm.worklist)
            process_worklist!(cgm)
            compile_objectid_cases!(cgm)
        end
        # the runtime functions the code needed (added to the world as it was emitted) may
        # use exceptions more than the program did: then again, as they need
        m = exception_mode(w)
        EXCEPTION_MODES[m] > EXCEPTION_MODES[mode] || break
        mode = m
    end
    if cgm.config.trim === :safe && !isempty(cgm.diagnostics)
        throw(UnsupportedConstructs(cgm.diagnostics))
    end
    finish_module!(cgm)
    bytes = to_bytes(cgm.mod)
    validate && WasmBuilder.validate(bytes)
    config.optimize === nothing || (bytes = wasm_opt(bytes, config.optimize))
    return Compilation(bytes, w, cgm)
end

compile(f, argtypes::Tuple; kw...) = compile([Entry(f, argtypes)]; kw...)

# the WebAssembly features the code generator uses, for Binaryen
const WASM_FEATURES = `--enable-gc --enable-reference-types --enable-multivalue --enable-bulk-memory
                       --enable-nontrapping-float-to-int --enable-sign-ext
                       --enable-exception-handling --enable-tail-call --enable-mutable-globals`

"""
    wasm_opt(bytes, options) -> Vector{UInt8}

The module optimized by Binaryen's `wasm-opt` (from Binaryen_jll), as a whole program
(`--closed-world`: no type escapes it but through its exports).
"""
function wasm_opt(bytes::Vector{UInt8}, options::Cmd)
    mktempdir() do dir
        src, dst = joinpath(dir, "in.wasm"), joinpath(dir, "out.wasm")
        write(src, bytes)
        run(`$(Binaryen_jll.wasmopt()) $options $WASM_FEATURES --closed-world --type-ssa --gufa $src -o $dst`)
        return read(dst)
    end
end

# (the image first, then the type maps, which add types: the tables over types after them)
function finish_module!(cgm::CGModule)
    finish_image!(cgm)
    finish_type_maps!(cgm)
    finish_type_isa!(cgm)
    finish_egal!(cgm)
    finish_objectid_any!(cgm)
    finish_objectid!(cgm)
    finish_pointers!(cgm)
    finish_types!(cgm)
    finish_subtype!(cgm)
end
