# Runtime functions with a native twin: a runtime function `f` the code generator compiles as
# the function `WASM_IMPLS[f]` (with the same arguments), so that natively, in the build
# process, `f` does what Julia does there (reading the process's options, ...) and the patches
# calling it work there too, while the module gets the Wasm implementation. Both are
# `@noinline`, to remain calls (see `overlays.jl`).

"The Wasm implementations of runtime functions with a native twin (see above)."
const WASM_IMPLS = IdDict{Any,Any}()

"""
The Wasm implementations of runtime functions for an extension of the host (see
`Config(host_extensions = ...)`): `EXTENSION_IMPLS[ext][f]` is compiled in place of `f` only
in modules whose host provides `ext`, before `WASM_IMPLS`. (A function whose default
implementation is right for hosts without the extension, `FS.path_mode` and the like.)
"""
const EXTENSION_IMPLS = Dict{Symbol,IdDict{Any,Any}}()

"""
    wasm_impl(f, extensions=()) -> Union{Nothing,Function}

The function compiled in place of the runtime function `f`, in a module whose host provides
the extensions `extensions`, or `nothing`.
"""
function wasm_impl(@nospecialize(f), extensions=())
    for ext in extensions
        impls = get(EXTENSION_IMPLS, ext, nothing)
        impls === nothing && continue
        impl = get(impls, f, nothing)
        impl === nothing || return impl
    end
    return get(WASM_IMPLS, f, nothing)
end

"""
    Twins

Natively, a patched function's twin calls the method the patch replaced: `Twins.original(f,
args...)` is `f(args...)` in the world before the patches of the open session (see
`with_trim_patches`).
"""
module Twins

"The world before the patches of the open session (see `with_trim_patches`)."
const PRE_PATCH_WORLD = Ref{UInt}(typemax(UInt))

original(f, args...; kw...) = Base.invoke_in_world(PRE_PATCH_WORLD[], f, args...; kw...)

end
