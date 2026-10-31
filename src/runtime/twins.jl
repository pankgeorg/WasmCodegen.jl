# Runtime functions with a native twin: a runtime function `f` the code generator compiles as
# the function `WASM_IMPLS[f]` (with the same arguments), so that natively, in the build
# process, `f` does what Julia does there (reading the process's options, ...) and the patches
# calling it work there too, while the module gets the Wasm implementation. Both are
# `@noinline`, to remain calls (see `overlays.jl`).

"The Wasm implementations of runtime functions with a native twin (see above)."
const WASM_IMPLS = IdDict{Any,Any}()

"The function compiled in place of the runtime function `f`, or `nothing`."
wasm_impl(@nospecialize(f)) = get(WASM_IMPLS, f, nothing)

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
