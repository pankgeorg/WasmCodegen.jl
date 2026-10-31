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
    config.host in (:js, :wasi) || throw(ArgumentError("Config: host must be :js or :wasi, got $(repr(config.host))"))
    for e in entries
        config.host === :wasi && e.name in WASI_EXPORTS &&
            throw(ArgumentError("the entry point $(e.f) is exported as \"$(e.name)\", a name WASI reserves: give it another (`Entry(f, argtypes; name)`)"))
    end
    # (the module's gensyms continue the build process's: none repeats one the image holds)
    Runtime.sync_gensym_counter!()
    t = time_ns()
    mis = Core.MethodInstance[entry_instance(e.f, e.argtypes; world) for e in entries]
    w = collect_world(mis; world, verify=config.verify)
    progress(config, "collect", t, length(w.order), " functions inferred")
    mode = exception_mode(w)
    local cgm
    while true
        t = time_ns()
        cgm = CGModule(w, config, mode)
        for (e, mi) in zip(entries, mis)
            info = get_function!(cgm, mi)
            add_export!(cgm.mod, e.name, info.func)
        end
        process_worklist!(cgm)
        compile_runtime_cases!(cgm)
        progress(config, "emit", t, length(cgm.funcs), " functions (exceptions: ", mode, "), ",
                 length(cgm.diagnostics), " unsupported constructs";
                 note=string(" (structurizing ", seconds(cgm.structurize_ns), " s)"))
        # the runtime functions the code needed (added to the world as it was emitted) may
        # use exceptions more than the program did: then again, as they need
        m = exception_mode(w)
        EXCEPTION_MODES[m] > EXCEPTION_MODES[mode] || break
        mode = m
    end
    if cgm.config.trim === :safe && !isempty(cgm.diagnostics)
        throw(UnsupportedConstructs(cgm.diagnostics))
    end
    t = time_ns()
    finish_module!(cgm)
    progress(config, "finish", t, "the image and the tables over types")
    t = time_ns()
    bytes = to_bytes(cgm.mod)
    progress(config, "write", t, length(bytes), " bytes")
    if validate
        t = time_ns()
        WasmBuilder.validate(bytes)
        progress(config, "validate", t)
    end
    if config.optimize !== nothing
        t = time_ns()
        bytes = wasm_opt(bytes, config.optimize)
        progress(config, "optimize", t, length(bytes), " bytes after wasm-opt ", join(config.optimize.exec, ' '))
    end
    return Compilation(bytes, w, cgm)
end

# with `config.progress`, a line on stderr: the phase, what it did, the time since `t` (`time_ns()`)
function progress(config::Config, phase::String, t::UInt64, what...; note::String="")
    config.progress || return
    println(stderr, "WasmCodegen: ", phase, ": ", what..., isempty(what) ? "" : ", ",
            seconds(time_ns() - t), " s", note)
    flush(stderr)
end

seconds(ns) = round(ns / 1e9; digits=1)

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
    finish_gensym_counter!(cgm)
    finish_modules!(cgm)
    finish_image!(cgm)
    finish_type_maps!(cgm)
    finish_typeof!(cgm)
    finish_type_isa!(cgm)
    finish_egal!(cgm)
    finish_objectid_any!(cgm)
    finish_tuples!(cgm)
    finish_objectid!(cgm)
    finish_pointers!(cgm)
    finish_types!(cgm)
    finish_subtype!(cgm)
    finish_host!(cgm)
end
