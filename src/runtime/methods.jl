# Methods the module compiles in place of the native ones: the Wasm interpreter's overlay
# method table (`interpreter.jl`). Natively, in the build process, a function with such a
# method does what Julia does there (reads the process's options, ...); inference for Wasm
# finds the method of `WASM_METHODS` instead, so the module runs it. They are defined with
# `@wasm_method`, as `Base.Experimental.@overlay` defines methods of a GPU's method table. An
# extension of the host has a table of its own (`EXTENSION_METHODS`), consulted before this one
# in modules whose host provides it.

"The methods the module compiles in place of the native ones (see above)."
Base.Experimental.@MethodTable(WASM_METHODS)

"""
    @wasm_method f(args...) = body

Define a method of `f` that the module compiles in place of the native one of the same
signature (a method of the overlay method table `WASM_METHODS`).

Inference still evaluates calls at compile time with the native methods (`WasmMethodTable`),
so a method must be no more `:consistent` than the native one it replaces: where the native
method reads state (the process's options, a clock, the C runtime's memory), the method reads
state too, rather than computing a constant, so that no call of it is folded with the build
process's answer. (The test `methods of WASM_METHODS` checks it.) As natively, where code that
precompiles folds such a call with the precompiling process's answer, an `@assume_effects`
annotation claiming `:consistent` over such state is taken at its word: a call of it is folded
with the build process's.
"""
macro wasm_method(def)
    return esc(:(Base.Experimental.@overlay $(GlobalRef(@__MODULE__, :WASM_METHODS)) $def))
end

"The world before the transient or resident patches (see `with_trim_patches`, `install_trim_patches!`)."
const PRE_PATCH_WORLD = Ref{UInt}(typemax(UInt))

"""
    original(f, args...; kw...)

`f(args...; kw...)` in the world before the transient or resident patches: natively, a runtime
function a patch calls can call the method the patch replaced.
"""
original(f, args...; kw...) = Base.invoke_in_world(PRE_PATCH_WORLD[], f, args...; kw...)

"""
The method tables of the host's extensions (`Config(host_extensions)`): the methods of
`EXTENSION_METHODS[ext]` are compiled in place of the native ones, and of those of
`WASM_METHODS`, only in modules whose host provides `ext` (where a function's method for other
hosts is right without the extension: `FS.path_mode` and the like). They are defined with
`Base.Experimental.@overlay`, under the rule of `@wasm_method`.
"""
const EXTENSION_METHODS = Dict{Symbol,Core.MethodTable}()

"The extensions of `extensions` that have a method table, each once, in order."
table_extensions(extensions) = unique!(Symbol[ext for ext in extensions if haskey(EXTENSION_METHODS, ext)])

"""
    overlay_tables(extensions) -> Vector{Core.MethodTable}

The overlay method tables of a module whose host provides `extensions`, in the order they are
consulted: the extensions' (in the order given), then `WASM_METHODS`.
"""
function overlay_tables(extensions)
    tables = Core.MethodTable[EXTENSION_METHODS[ext] for ext in table_extensions(extensions)]
    return push!(tables, WASM_METHODS)
end

"Whether `m` is a method of `WASM_METHODS` or of an extension's table."
overlay_method(m::Method) = isdefined(m, :external_mt) &&
    (m.external_mt === WASM_METHODS || any(mt -> mt === m.external_mt, values(EXTENSION_METHODS)))
