# Methods the module compiles in place of the native ones: the Wasm interpreter's overlay
# method table (`interpreter.jl`). Natively, in the build process, a function with such a
# method does what Julia does there (reads the process's options, ...); inference for Wasm
# finds the method of `WASM_METHODS` instead, so the module runs it. They are defined with
# `@wasm_method`, as `Base.Experimental.@overlay` defines methods of a GPU's method table.

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

"The world before the patches of the open session (see `with_trim_patches`)."
const PRE_PATCH_WORLD = Ref{UInt}(typemax(UInt))

"""
    original(f, args...; kw...)

`f(args...; kw...)` in the world before the patches of the open session: natively, a runtime
function a patch calls can call the method the patch replaced.
"""
original(f, args...; kw...) = Base.invoke_in_world(PRE_PATCH_WORLD[], f, args...; kw...)

"""
The implementations of runtime functions for an extension of the host (see
`Config(host_extensions = ...)`): `EXTENSION_IMPLS[ext][f]` is compiled in place of `f` only
in modules whose host provides `ext`. (A function whose default implementation is right for
hosts without the extension, `FS.path_mode` and the like.)
"""
const EXTENSION_IMPLS = Dict{Symbol,IdDict{Any,Any}}()

"""
    extension_impl(f, extensions) -> Union{Nothing,Function}

The function compiled in place of the runtime function `f`, in a module whose host provides
the extensions `extensions`, or `nothing`.
"""
function extension_impl(@nospecialize(f), extensions)
    for ext in extensions
        impls = get(EXTENSION_IMPLS, ext, nothing)
        impls === nothing && continue
        impl = get(impls, f, nothing)
        impl === nothing || return impl
    end
    return nothing
end
