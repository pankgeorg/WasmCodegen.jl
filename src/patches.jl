# Patches: methods of Base and the standard library redefined for trimmed programs, as
# juliac redefines them in its build process (`src/trim/`, from JuliaC.jl).
#
# They are real method definitions, not overlays: native inference, concrete evaluation
# and effects treat them as the methods they replace, so the code compiled is the code
# juliac compiles. To keep them from affecting the session, they are defined in a new world
# for the compilation only: the program is inferred in that world, while the compiler runs
# in the world before them, and they are deleted afterwards (deleting a method that
# replaced another restores it). A long-lived process can instead install them once, for
# its life (`install_trim_patches!`): then no compilation defines or deletes methods.

const TRIM_PATCHES = [joinpath(@__DIR__, "trim", "juliac-trim-base.jl"),
                      joinpath(@__DIR__, "trim", "juliac-trim-stdlib.jl"),
                      # the pseudo-runtime: what Wasm has no C runtime for
                      joinpath(@__DIR__, "trim", "wasm-base.jl"),
                      joinpath(@__DIR__, "trim", "wasm-io.jl"),
                      joinpath(@__DIR__, "trim", "wasm-paths.jl"),
                      joinpath(@__DIR__, "trim", "wasm-random.jl"),
                      joinpath(@__DIR__, "trim", "wasm-memory.jl"),
                      joinpath(@__DIR__, "trim", "wasm-versions.jl"),
                      joinpath(@__DIR__, "trim", "wasm-show.jl"),
                      joinpath(@__DIR__, "trim", "wasm-print.jl"),
                      joinpath(@__DIR__, "trim", "wasm-specialize.jl"),
                      joinpath(@__DIR__, "trim", "wasm-invokelatest.jl"),
                      joinpath(@__DIR__, "trim", "wasm-fs.jl")]

# the C runtime's scheduler on one thread, for `Config(tasks=:jspi)` (after the others)
const TASK_PATCHES = [joinpath(@__DIR__, "trim", "wasm-tasks.jl")]

# the constants the patches rebind (methods are restored by deleting their replacements)
const PATCHED_CONSTS = [(Base, :invokelatest)]

"""
The world the compiler runs in: the world when WasmCodegen was loaded. The compiler's
own (native) code is compiled for that world and stays valid there whatever is defined
or deleted later (the patches, the program, packages loaded after WasmCodegen), as
GPUCompiler isolates the compiler from the code it compiles. Programs are inferred in
the latest world.
"""
const COMPILER_WORLD = Ref{UInt}(typemax(UInt))

"The patches and bindings of the open session of patches (see `with_trim_patches`), or `nothing`."
const PATCH_SESSION = Ref{Any}(nothing)

latest_global(m::Module, s::Symbol) = Base.invoke_in_world(Base.get_world_counter(), getglobal, m, s)

"""
    with_trim_patches(f; patches=TRIM_PATCHES, bindings=[])

Define the patches in a new world, call `f(compiler_world, program_world)` in the world
before them (`compiler_world`), and remove them afterwards. The program is to be inferred
in `program_world`, where the patches are defined.

Compilations within `f` (calls of [`compile`](@ref)) share the patches: their programs
are inferred in the latest world (with the patches, and whatever `f` defined) and the
compiler runs in `compiler_world`. Defining and deleting the patches invalidates code
that depends on the methods they replace, so a session of several compilations is much
faster than patching each one (as juliac builds in one process).

The patch files are included in a module of their own, where `WasmCodegen` and each
`name => value` of `bindings` (the modules they patch, loaded before) are defined. They
may only define methods: the methods they define are deleted when the session ends,
whether `f` returns or throws, or a patch file throws while it is included (deleting a
method that replaced another restores it). A session within a session shares it, which
must then have the same patches and bindings.
"""
function with_trim_patches(f; patches=TRIM_PATCHES, bindings=Pair{Symbol,Any}[])
    key = (String[abspath(p) for p in patches], Pair{Symbol,Any}[bindings...])
    open_session = PATCH_SESSION[]
    if open_session !== nothing
        open_session[1] == key[1] && length(open_session[2]) == length(key[2]) &&
            all(((a, b),) -> a.first === b.first && a.second === b.second, zip(open_session[2], key[2])) ||
            error("with_trim_patches: a session of patches is open with other patches or bindings " *
                  "(nested sessions must have the same ones)")
        return f(COMPILER_WORLD[], Base.get_world_counter())
    end
    w0 = Base.get_world_counter()
    consts = [(m, s, getglobal(m, s)) for (m, s) in PATCHED_CONSTS]
    sandbox = Module(:WasmCodegenTrimPatches)
    w1 = w0
    try
        Core.eval(sandbox, :(Core.Compiler._verify_trim_world_age[] = $w0))
        # (runtime functions the patches call can call the originals natively in this world)
        Runtime.PRE_PATCH_WORLD[] = w0
        Core.eval(sandbox, :(const WasmCodegen = $(@__MODULE__)))
        for (name, value) in bindings
            Core.eval(sandbox, :(const $name = $(QuoteNode(value))))
        end
        try
            for file in patches
                Base.include(sandbox, file)
            end
        finally
            # (the patches' methods: those of the worlds up to this one)
            w1 = Base.get_world_counter()
        end
        PATCH_SESSION[] = key
        return f(COMPILER_WORLD[], Base.get_world_counter())
    finally
        PATCH_SESSION[] = nothing
        Runtime.PRE_PATCH_WORLD[] = typemax(UInt)
        added = Method[]
        Base.visit(Core.methodtable) do m
            w0 < m.primary_world <= w1 && push!(added, m)
        end
        foreach(Base.delete_method, added)
        # (the binding as of now: this code runs in the world before the patches)
        for (m, s, v) in consts
            latest_global(m, s) === v || Core.eval(m, :(const $s = $v))
        end
    end
end

# These stubs are valid for a closed Wasm program, but a resident native process
# must keep package loading, initialization and world-age switching working.
const NONRESIDENT_TRIM_NAMES = Set((
    :invokelatest_gr, :reinit_stdio, :init_active_project, :set_active_project,
    :start_sigint_listener, :enable_in_core!, :wait_forever,
    :disable_library_threading, :start_profile_listener, :__init__,
    :_artifact_str, :current_logger_for_env, :show_type_name, :show_function, :_show_type,
))

# The function of a method definition (a name, or a qualified `M.name`), including
# definitions wrapped in annotations.
function trim_method_callee(ex)
    ex isa Expr || return nothing
    if ex.head === :macrocall && ex.args[end] isa Expr &&
            ex.args[1] in (Symbol("@inline"), Symbol("@noinline"), Symbol("@assume_effects"))
        return trim_method_callee(ex.args[end])
    end
    ex.head in (:function, :(=)) || return nothing
    sig = ex.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    Meta.isexpr(sig, :call) || return nothing
    return sig.args[1]
end

# The name of a method definition's function.
function trim_method_name(ex)
    name = trim_method_callee(ex)
    Meta.isexpr(name, :.) && (name = name.args[end].value)
    return name isa Symbol ? name : nothing
end

# Applied before macro expansion, so @eval still supplies the original module
# scope and interpolation. Resident-safe definitions are included unchanged.
function resident_trim_expr(ex)
    ex isa Expr || return ex
    # Core.invokelatest is a builtin on supported Julia: preserve its binding.
    # @invokelatest's Julia wrapper below is supplied through WASM_METHODS.
    if ex.head === :const && Meta.isexpr(ex.args[1], :(=)) &&
            ex.args[1].args[1] === :invokelatest
        return nothing
    end
    name = trim_method_name(ex)
    # LazyLibraryPath's restricted implementation also belongs only to Wasm.
    lazy_string = name === :string && occursin("LazyLibraryPath", string(ex.args[1]))
    # Native type repr is executable Julia in package-loader subprocesses;
    # juliac's unqualified names are only valid for Wasm display. The enum
    # printer likewise restricts module contexts that native Julia supports.
    nonresident_show = name === :show &&
        (occursin("T::Type", string(ex.args[1])) || occursin("x::Enums.Enum", string(ex.args[1])))
    if name in NONRESIDENT_TRIM_NAMES || lazy_string || nonresident_show
        overlay = Expr(:macrocall, GlobalRef(Runtime, Symbol("@wasm_method")),
                       LineNumberNode(0), ex)
        # An overlay needs a function to attach to. Some Julia versions have no
        # function of the name natively (CHOLMOD/StyledStrings initializers,
        # `wait_forever` on 1.12): declare it without methods, natively as absent,
        # but for an initializer, which a module's loading calls: a native no-op
        # (the absent hook's behavior), also where a session left the function
        # without its method. Never run the trimmed body natively.
        trim_method_callee(ex) isa Symbol || return overlay
        if name === :__init__
            return quote
                if !(isdefined(@__MODULE__, :__init__) && hasmethod(__init__, Tuple{}))
                    __init__() = nothing
                end
                $overlay
            end
        end
        return quote
            if !isdefined(@__MODULE__, $(QuoteNode(name)))
                function $name end
            end
            $overlay
        end
    end
    return Expr(ex.head, map(resident_trim_expr, ex.args)...)
end

"""
    install_trim_patches!(; patches=TRIM_PATCHES, bindings=[])

Define the patches once, for the life of the process: `compile` and `with_trim_patches` (with
the same patches and bindings) then share this session, and define or delete no method. For
a process that compiles one program after another while its packages stay loaded (a compile
server), or a system image (called from its precompile script, before the workload): a session
per compilation deletes the patches when it ends, which invalidates the native code of
everything that depends on the methods they replace, in every package loaded, and the next
compilation compiles it all again.

The process's own Base is patched for its life. The patches are real methods, as in a session
(inferred as juliac infers them), except those that would break the native process, which are
methods of `Runtime.WASM_METHODS` instead: the startup, initialization, project, artifact and
lazy-library stubs, the logger lookup, `invokelatest_gr`, and the simplified printers of types,
type names, functions and enums (the package loader sends `repr`s of types to precompilation
processes as code). `Base.invokelatest` keeps Core's binding; a program's calls of it compile
to direct calls, as juliac's rebinding makes them. `Runtime.original` calls the world before
the installation.

Calling it again with the same patches and bindings does nothing; with others, or in a session
of `with_trim_patches`, it throws. `TASK_PATCHES` (`Config(tasks = :jspi)`) need a session of
their own. The installation is not undone: if a patch file throws, discard the process.
"""
function install_trim_patches!(; patches=TRIM_PATCHES, bindings=Pair{Symbol,Any}[])
    key = (String[abspath(p) for p in patches], Pair{Symbol,Any}[bindings...])
    any(p -> p in abspath.(TASK_PATCHES), key[1]) &&
        error("install_trim_patches!: TASK_PATCHES require a transient session")
    if PATCH_SESSION[] !== nothing
        PATCH_SESSION[] == key || error("install_trim_patches!: another patch session is open")
        RESIDENT_PATCH_MODULE[] !== nothing ||
            error("install_trim_patches!: cannot make a transient session permanent")
        return nothing
    end
    w0 = Base.get_world_counter()
    sandbox = Module(:WasmCodegenResidentTrimPatches)
    Runtime.PRE_PATCH_WORLD[] = w0
    Core.eval(sandbox, :(Core.Compiler._verify_trim_world_age[] = $w0))
    Core.eval(sandbox, :(const WasmCodegen = $(@__MODULE__)))
    for (name, value) in bindings
        Core.eval(sandbox, :(const $name = $(QuoteNode(value))))
    end
    for file in key[1]
        Base.include(resident_trim_expr, sandbox, file)
    end
    Base.visit(m -> m.primary_world > w0 && push!(RESIDENT_OVERLAYS, m), Runtime.WASM_METHODS)
    if Base.invoke_in_world(Base.get_world_counter(), isdefined, Base, :invokelatest_trimmed)
        DIRECT_INVOKELATEST[] = latest_global(Base, :invokelatest_trimmed)
    end
    RESIDENT_PATCH_MODULE[] = sandbox
    PATCH_SESSION[] = key
    return nothing
end

# Keep the patch module reachable for system-image serialization.
const RESIDENT_PATCH_MODULE = Ref{Union{Nothing,Module}}(nothing)

# the patches installed as methods of `WASM_METHODS` (see `CC.findall(::WasmMethodTable)`)
const RESIDENT_OVERLAYS = Method[]
# what a program's `Core.invokelatest` is, juliac's `invokelatest_trimmed` (see `CC.optimize(::WasmInterpreter, ...)`)
const DIRECT_INVOKELATEST = Ref{Any}(nothing)
is_resident_overlay(m::Method) = !isempty(RESIDENT_OVERLAYS) && any(r -> r === m, RESIDENT_OVERLAYS)
