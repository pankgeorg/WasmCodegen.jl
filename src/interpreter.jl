# The abstract interpreter that infers code for Wasm: Julia's native inference, with its own
# code cache. What Wasm needs replaced is mostly replaced by method definitions in a newer
# world (`patches.jl`), as juliac does, so inference (and its concrete evaluation) is the
# native one. The methods of `Runtime.WASM_METHODS` (an overlay method table, `methods.jl`),
# and of the tables of the host's extensions the module has, replace those whose native method
# the build process needs itself (`WasmMethodTable`).

"""
The owner of the CodeInstances inferred for Wasm in Julia's code cache, for the overlay method
tables of the host's extensions `extensions` and `Runtime.WASM_METHODS` as they are: how many
methods were defined in them, and how many are in force. Code inferred for other extensions, or
before a method was defined or deleted, is not reused, since that does not invalidate it (a
caller that found the native method has no backedge to an overlay method table).
"""
struct WasmCacheOwner
    extensions::Tuple{Vararg{Symbol}}
    defined::Int
    in_force::Int
end

function WasmCacheOwner(extensions=())
    defined = in_force = 0
    for mt in Runtime.overlay_tables(extensions)
        Base.visit(mt) do m
            defined += 1
            m.dispatch_status == 0 || (in_force += 1)
        end
    end
    return WasmCacheOwner(Tuple(Runtime.table_extensions(extensions)), defined, in_force)
end

"""
    CodegenSources

The optimized sources of CodeInstances that `CC.compile!` reads (`interp.codegen`): those
stashed by inference, and, for CodeInstances of the Wasm cache inferred by an earlier
interpreter, their cached source, uncompressed on demand. (For an owner other than
native code, `CC.ci_has_source` accepts a cached CodeInstance by its `inferred` field
without putting its source here, which `CC.compile!` requires.)
"""
struct CodegenSources <: AbstractDict{Core.CodeInstance,Core.CodeInfo}
    owner::WasmCacheOwner
    dict::IdDict{Core.CodeInstance,Core.CodeInfo}
end
CodegenSources(owner::WasmCacheOwner) = CodegenSources(owner, IdDict{Core.CodeInstance,Core.CodeInfo}())

function cached_source(d::CodegenSources, ci::Core.CodeInstance)
    src = get(d.dict, ci, nothing)
    src === nothing || return src
    ci.owner === d.owner || return nothing
    inf = @atomic :monotonic ci.inferred
    inf isa String && (inf = CC._uncompressed_ir(ci, inf))
    inf isa Core.CodeInfo || return nothing
    d.dict[ci] = inf
    return inf
end

Base.get(d::CodegenSources, ci::Core.CodeInstance, default) =
    something(cached_source(d, ci), Some(default))
Base.haskey(d::CodegenSources, ci::Core.CodeInstance) = cached_source(d, ci) !== nothing
Base.getindex(d::CodegenSources, ci::Core.CodeInstance) =
    something(cached_source(d, ci), Some(nothing))::Core.CodeInfo
Base.setindex!(d::CodegenSources, src::Core.CodeInfo, ci::Core.CodeInstance) = (d.dict[ci] = src; d)
Base.length(d::CodegenSources) = length(d.dict)
Base.iterate(d::CodegenSources, s...) = iterate(d.dict, s...)

"""
    WasmMethodTable(world, extensions=())

The methods of `world`, with those of the overlay method tables of a module whose host has the
extensions `extensions` in place of the native ones they replace: the extensions' tables, then
`Runtime.WASM_METHODS` (`Runtime.overlay_tables`), each falling back to the next and the last
to the native methods, as `CC.OverlayMethodTable` falls back. Reported as not overlaid:
inference evaluates calls at compile time with the native methods, as for native code.
(Compiler does not evaluate code an overlay method table could reach, which includes every
dynamic call, so reflection code evaluated at compile time would no longer be.) That is sound
because no method of these tables is more `:consistent` than the native one it replaces (see
`@wasm_method`).
"""
struct WasmMethodTable <: CC.MethodTableView
    world::UInt
    tables::Vector{Core.MethodTable}
end
WasmMethodTable(world::UInt, extensions=()) = WasmMethodTable(world, Runtime.overlay_tables(extensions))

# (`CC.OverlayMethodTable`'s, for a list of tables: the matches of each table but those a
# match of an earlier table covers, up to the first table whose last match covers `sig`)
function CC.findall(@nospecialize(sig::Type), t::WasmMethodTable; limit::Int=-1)
    matches = Any[]
    min_world, max_world = typemin(UInt), typemax(UInt)
    ambig = false
    for mt in Union{Nothing,Core.MethodTable}[t.tables; nothing]
        result = CC._findall(sig, mt, t.world, limit)
        result === nothing && return nothing
        earlier = length(matches)
        for match in result.matches
            dominated = any(i -> (match::Core.MethodMatch).method.sig <: (matches[i]::Core.MethodMatch).method.sig,
                            1:earlier)
            dominated || push!(matches, match)
        end
        min_world = max(min_world, result.valid_worlds.min_world)
        max_world = min(max_world, result.valid_worlds.max_world)
        ambig |= result.ambig
        nr = length(result)
        nr ≥ 1 && result[nr].fully_covers && break
    end
    return CC.MethodLookupResult(matches, CC.WorldRange(min_world, max_world), ambig)
end

# (the match of the first table that has one)
function CC.findsup(@nospecialize(sig::Type), t::WasmMethodTable)
    min_world, max_world = typemin(UInt), typemax(UInt)
    for mt in Union{Nothing,Core.MethodTable}[t.tables; nothing]
        match, valid_worlds = CC._findsup(sig, mt, t.world)
        min_world = max(min_world, valid_worlds.min_world)
        max_world = min(max_world, valid_worlds.max_world)
        match === nothing || return match, CC.WorldRange(min_world, max_world)
    end
    return nothing, CC.WorldRange(min_world, max_world)
end
CC.isoverlayed(::WasmMethodTable) = false

"""
    WasmInterpreter(; world, extensions=())

Julia's native inference and optimization in `world`, with its own code cache and the
methods of `Runtime.WASM_METHODS` and of the tables of the host's extensions `extensions`.
"""
struct WasmInterpreter <: CC.AbstractInterpreter
    world::UInt
    method_table::CC.CachedMethodTable{WasmMethodTable}
    inf_cache::Vector{CC.InferenceResult}
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    "The uncompressed source of the CodeInstances inferred, for `CC.compile!`."
    codegen::CodegenSources
end

function WasmInterpreter(; world::UInt=Base.get_world_counter(), extensions=())
    mt = CC.CachedMethodTable(WasmMethodTable(world, extensions))
    inf_params = CC.InferenceParams(; force_enable_inference=true)
    # calls target the method instance of their argument types, not the signature native
    # code would be compiled for, which widens arguments of type Function, Type and Vararg
    # that a method only passes on (JuliaSyntax's parser passes its subparsers as
    # `down::Function`): a closed world has no dynamic dispatch to fall back on
    opt_params = CC.OptimizationParams(; compilesig_invokes=false)
    return WasmInterpreter(world, mt, CC.InferenceResult[], inf_params, opt_params,
                           CodegenSources(WasmCacheOwner(extensions)))
end

CC.InferenceParams(interp::WasmInterpreter) = interp.inf_params
CC.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
CC.get_inference_world(interp::WasmInterpreter) = interp.world
CC.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
CC.method_table(interp::WasmInterpreter) = interp.method_table
CC.cache_owner(interp::WasmInterpreter) = interp.codegen.owner
CC.codegen_cache(interp::WasmInterpreter) = interp.codegen
CC.may_discard_trees(::WasmInterpreter) = false

# `have_fma` is false on Wasm (no fused multiply-add): fold it, so that math code picks
# its kernel without fma at compile time
function fold_target_intrinsic(@nospecialize(f), argtypes::Vector{Any})
    f === Core.Intrinsics.have_fma || return nothing
    return CC.CallMeta(CC.Const(false), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo())
end

# A module's `Base.Experimental.@max_methods` (Pkg sets 1 for its modules) limits the
# methods inference considers at a call to save latency in a session that may define more:
# with more candidates the call stays dynamic. A closed world has no later methods and no
# dynamic dispatch to fall back on, so it infers with at least the default limit (a module's
# higher one still applies, and a function's own `@max_methods`): `isempty(v.prerelease)` (a
# `Tuple{Vararg{...}}`, two candidate methods) is then the union-split call it is outside
# such modules (the module's limit; `get_max_methods(interp, f, sv)` asks the function's own first)
CC.get_max_methods(interp::WasmInterpreter, sv::CC.AbsIntState) =
    max(something(CC.get_max_methods_for_module(sv), 0), CC.get_max_methods(interp))

function CC.abstract_call_known(interp::WasmInterpreter, @nospecialize(f),
                                arginfo::CC.ArgInfo, si::CC.StmtInfo, sv::CC.InferenceState,
                                max_methods::Int=CC.get_max_methods(interp, f, sv))
    folded = fold_target_intrinsic(f, arginfo.argtypes)
    folded === nothing || return CC.Future{CC.CallMeta}(folded)
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any,
                                          arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          sv::CC.InferenceState, max_methods::Int)
end
