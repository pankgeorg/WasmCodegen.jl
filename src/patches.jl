# Patches: methods of Base and the standard library redefined for trimmed programs, as
# juliac redefines them in its build process (`src/trim/`, from JuliaC.jl).
#
# They are real method definitions, not overlays: native inference, concrete evaluation
# and effects treat them as the methods they replace, so the code compiled is the code
# juliac compiles. To keep them from affecting the session, they are defined in a new world
# for the compilation only: the program is inferred in that world, while the compiler runs
# in the world before them, and they are deleted afterwards (deleting a method that
# replaced another restores it).

const TRIM_PATCHES = [joinpath(@__DIR__, "trim", "juliac-trim-base.jl"),
                      joinpath(@__DIR__, "trim", "juliac-trim-stdlib.jl"),
                      # the pseudo-runtime: what Wasm has no C runtime for
                      joinpath(@__DIR__, "trim", "wasm-base.jl"),
                      joinpath(@__DIR__, "trim", "wasm-io.jl"),
                      joinpath(@__DIR__, "trim", "wasm-paths.jl"),
                      joinpath(@__DIR__, "trim", "wasm-random.jl"),
                      joinpath(@__DIR__, "trim", "wasm-memory.jl"),
                      joinpath(@__DIR__, "trim", "wasm-versions.jl"),
                      joinpath(@__DIR__, "trim", "wasm-runtime.jl")]

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
        # (the twins of patched functions call the originals natively in this world)
        Runtime.Twins.PRE_PATCH_WORLD[] = w0
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
        Runtime.Twins.PRE_PATCH_WORLD[] = typemax(UInt)
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
