# The abstract interpreter that infers code for Wasm: Julia's native inference, with its own
# code cache. There is no overlay method table: what Wasm needs replaced is replaced by
# method definitions in a newer world (`patches.jl`), as juliac does, so inference (and its
# concrete evaluation) is the native one.

"""The owner of the CodeInstances inferred for Wasm in Julia's code cache: one per inlining
size cap (`Config.inline_cap`), since the cap changes the optimized code."""
struct WasmCacheOwner
    inline_cap::Int
end
WasmCacheOwner() = WasmCacheOwner(0)

"""
    CodegenSources

The optimized sources of CodeInstances that `CC.compile!` reads (`interp.codegen`): those
stashed by inference, and, for CodeInstances of the Wasm cache inferred by an earlier
interpreter, their cached source, uncompressed on demand. (For an owner other than
native code, `CC.ci_has_source` accepts a cached CodeInstance by its `inferred` field
without putting its source here, which `CC.compile!` requires.)
"""
struct CodegenSources <: AbstractDict{Core.CodeInstance,Core.CodeInfo}
    dict::IdDict{Core.CodeInstance,Core.CodeInfo}
end
CodegenSources() = CodegenSources(IdDict{Core.CodeInstance,Core.CodeInfo}())

function cached_source(d::CodegenSources, ci::Core.CodeInstance)
    src = get(d.dict, ci, nothing)
    src === nothing || return src
    ci.owner isa WasmCacheOwner || return nothing
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
    WasmInterpreter(; world)

Julia's native inference and optimization in `world`, with its own code cache.
"""
struct WasmInterpreter <: CC.AbstractInterpreter
    world::UInt
    method_table::CC.CachedMethodTable{CC.InternalMethodTable}
    inf_cache::Vector{CC.InferenceResult}
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    "The uncompressed source of the CodeInstances inferred, for `CC.compile!`."
    codegen::CodegenSources
    "Callees whose optimized code has more statements than this are not inlined (0: no cap)."
    inline_cap::Int
    "The statement counts of compressed sources seen by the inlining size cap."
    src_lengths::IdDict{Any,Int}
end

function WasmInterpreter(; world::UInt=Base.get_world_counter(), inline_cap::Int=0)
    mt = CC.CachedMethodTable(CC.InternalMethodTable(world))
    inf_params = CC.InferenceParams(; force_enable_inference=true)
    # calls target the method instance of their argument types, not the signature native
    # code would be compiled for, which widens arguments of type Function, Type and Vararg
    # that a method only passes on (JuliaSyntax's parser passes its subparsers as
    # `down::Function`): a closed world has no dynamic dispatch to fall back on
    opt_params = CC.OptimizationParams(; compilesig_invokes=false)
    return WasmInterpreter(world, mt, CC.InferenceResult[], inf_params, opt_params,
                           CodegenSources(), inline_cap, IdDict{Any,Int}())
end

CC.InferenceParams(interp::WasmInterpreter) = interp.inf_params
CC.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
CC.get_inference_world(interp::WasmInterpreter) = interp.world
CC.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
CC.method_table(interp::WasmInterpreter) = interp.method_table
CC.cache_owner(interp::WasmInterpreter) = WasmCacheOwner(interp.inline_cap)

# the number of statements of a callee's optimized code, as inlining sees it (`nothing`: unknown)
source_length(@nospecialize(src), ::Core.MethodInstance, ::WasmInterpreter) = nothing
source_length(src::CC.OptimizationState, mi::Core.MethodInstance, interp::WasmInterpreter) =
    src.optresult === nothing ? source_length(src.src, mi, interp) : length(src.optresult.ir.stmts)
source_length(src::Core.CodeInfo, ::Core.MethodInstance, ::WasmInterpreter) = length(src.code)
source_length(src::CC.IRCode, ::Core.MethodInstance, ::WasmInterpreter) = length(src.stmts)
# (compressed code decodes only with its CodeInstance: the one cached for `mi`, if this is its code)
function source_length(src::String, mi::Core.MethodInstance, interp::WasmInterpreter)
    n = get(interp.src_lengths, src, -1)
    n >= 0 && return n
    ci = CC.get(CC.code_cache(interp), mi, nothing)
    (ci isa Core.CodeInstance && (@atomic :monotonic ci.inferred) === src) || return nothing
    code = CC._uncompressed_ir(ci, src)
    code isa Core.CodeInfo || return nothing
    return interp.src_lengths[src] = length(code.code)
end

# with an inlining size cap, a callee larger than the cap stays a call (an `@inline` one too):
# the structurizer's and Binaryen's costs grow faster than the size of a function. A callee of
# unknown size is not capped. (Inference asks this too, in its size-dependent heuristic for whether
# constant propagation into a callee pays, so the cap can reduce constant propagation.)
# This form of the policy, with the callee's method instance, is the one Julia 1.13 calls.
function CC.src_inlining_policy(interp::WasmInterpreter, mi::Core.MethodInstance, @nospecialize(src),
                                @nospecialize(info::CC.CallInfo), stmt_flag::UInt32)
    inline = @invoke CC.src_inlining_policy(interp::CC.AbstractInterpreter, mi::Core.MethodInstance, src::Any,
                                            info::CC.CallInfo, stmt_flag::UInt32)
    (inline && interp.inline_cap > 0) || return inline
    n = source_length(src, mi, interp)
    return n === nothing || n <= interp.inline_cap
end
CC.codegen_cache(interp::WasmInterpreter) = interp.codegen
CC.may_discard_trees(::WasmInterpreter) = false

# `have_fma` is false on Wasm (no fused multiply-add): fold it, so that math code picks
# its kernel without fma at compile time
function fold_target_intrinsic(@nospecialize(f), argtypes::Vector{Any})
    f === Core.Intrinsics.have_fma || return nothing
    return CC.CallMeta(CC.Const(false), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo())
end

function CC.abstract_call_known(interp::WasmInterpreter, @nospecialize(f),
                                arginfo::CC.ArgInfo, si::CC.StmtInfo, sv::CC.InferenceState,
                                max_methods::Int=CC.get_max_methods(interp, f, sv))
    folded = fold_target_intrinsic(f, arginfo.argtypes)
    folded === nothing || return CC.Future{CC.CallMeta}(folded)
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any,
                                          arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          sv::CC.InferenceState, max_methods::Int)
end
