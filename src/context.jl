# The state of a compilation: one `CGModule` per Wasm module, one `FnCtx` per function.

"""
    Config(; on_unsupported=:error)

The configuration of the code generator:

- `on_unsupported`: what happens when a function uses an unsupported construct: `:error`
  (throw), or `:trap` (the construct compiles to a trap, and is reported in the
  compilation's diagnostics);
- `verify`: checking the entry points as `juliac --trim=safe` does (`:error`, `:warn`
  (report), `:off`);
- `trim_patches`: compile with the methods juliac redefines for trimmed programs
  (`patches.jl`);
- `trim`: as juliac's `--trim`: `:safe`, a statement the code generator cannot compile
  (dynamic dispatch, ...) is an error; `:unsafe`, it compiles to a trap where it is (an
  error if it runs), recorded in the diagnostics.
"""
Base.@kwdef struct Config
    on_unsupported::Symbol = :error
    verify::Symbol = :warn
    trim_patches::Bool = true
    trim::Symbol = :safe
    "Binaryen's `wasm-opt` options the module is optimized with (`nothing`: not optimized).
    The code generator emits simple code (a local per value) and leaves allocating locals,
    putting values on the operand stack and the rest to it."
    optimize::Union{Nothing,Cmd} = `-O3`
    "`Core._call_in_world` / `Core._call_latest` (`invoke_in_world`, `invokelatest`) of a constant
    callee with arguments of known types compile to a direct call of the method the program world
    dispatches to. A world known at compile time must be one in which that code is valid (else
    unsupported); a world known only at run time is assumed to be (nothing the call runs
    redefined after it)."
    direct_world_calls::Bool = false
    "`cfunction` pointers and calls through them (`FunctionWrappers`) compile to typed Wasm
    function references (`runtime/fwrappers.jl`)."
    funcref_wrappers::Bool = false
    "Mutable objects of the image are created as shells (header and default fields) whose fields
    the start function sets, so that a cycle back to a mutable object through closures or
    immutable objects (an ODE integrator holding callbacks whose closures capture it) can be
    serialized."
    shell_first_mutables::Bool = false
    "Callees whose optimized code has more than this many statements are not inlined into their
    callers, as far as the interpreter can tell their size (0: Julia's inlining decisions as
    they are). Large inlined bodies make the structurizer and `wasm-opt` slow. The cap can also
    reduce constant propagation into capped callees (inference's size-dependent heuristic).
    (Julia 1.13 and later; ignored on 1.12, whose inlining policy does not see the callee.)"
    inline_cap::Int = 0
    "The structured IR of each function is kept for the session (the process) and reused by every
    later compilation that has the same function: keyed by its CodeInstance (which an inlining cap
    owns: each cap its own) and the module's exception mode. Pays off when compilations share
    code, e.g. a solver compiled for many models behind a model-independent interface. Emission
    only reads the structured IR, so it is reused as it is. See `ir_cache_stats`, `empty_ir_cache!`."
    ir_cache::Bool = false
end

"""
    FuncInfo

A Wasm function compiled for a method instance: its Julia argument types (with the
function object first, varargs packed in a tuple, as the IR has them) and return type.
"""
struct FuncInfo
    mi::Core.MethodInstance
    func::Func
    argtypes::Vector{Any}
    rettype::Any
end

"""
    CGModule

The state of generating a module: the closed world, the Wasm module and its types, the
functions emitted for method instances, the image of serialized objects, and helper
functions generated on demand.
"""
mutable struct CGModule
    world::ClosedWorld
    mod::WModule
    types::Types
    config::Config
    funcs::IdDict{Core.MethodInstance,FuncInfo}
    worklist::Vector{FuncInfo}
    image::Any
    helpers::Dict{Any,Any}
    "Diagnostics: the unsupported constructs compiled as traps, by function."
    diagnostics::Vector{Pair{Core.MethodInstance,Unsupported}}
    "Instructions of the start function (initializing objects of the image)."
    start::Vector{Inst}
    "How the program uses exceptions (`:none`, `:control`, `:values`: see `exceptions.jl`)."
    exceptions::Symbol
end

function CGModule(world::ClosedWorld, config::Config, exceptions::Symbol=exception_mode(world))
    m = WModule()
    types = Types(m)
    cgm = CGModule(world, m, types, config, IdDict{Core.MethodInstance,FuncInfo}(),
                   FuncInfo[], nothing, Dict{Any,Any}(), Pair{Core.MethodInstance,Unsupported}[],
                   Inst[], exceptions)
    cgm.image = Image(cgm)
    return cgm
end

layout(cgm::CGModule, @nospecialize(T)) = layout(cgm.types, T)
valtypes(cgm::CGModule, @nospecialize(T)) = valtypes(cgm.types, T)

"""
    LoopTarget

An enclosing loop: the depths of its labels (`exit`: the block around the loop; `cont`:
the loop itself), the locals of its carried values and results, and for a `for` loop its
induction variable and step.
"""
struct LoopTarget
    exit::Int
    cont::Int
    carries::Vector{CGVal}
    results::Vector{CGVal}
    iv::Union{Nothing,CGVal}
    step::Any
end

"""
    TryTarget

An enclosing `try` body: the depth of the label after the `try`, and the locals of its
results (which a `LeaveOp` assigns before branching there).
"""
struct TryTarget
    exit::Int
    results::Vector{CGVal}
end

"""
    FnCtx

The state of emitting one function: its structured IR, the builder, the value of each
argument, statement and block argument, the enclosing loops and the label depth.
"""
mutable struct FnCtx
    cgm::CGModule
    info::FuncInfo
    sci::Any
    b::Builder
    args::Vector{CGVal}
    ssavals::Dict{Int,Any}
    blockargs::Dict{Int,CGVal}
    loops::Vector{LoopTarget}
    "The number of labels (blocks, loops, ifs) enclosing the current position."
    depth::Int
    "The results of the enclosing ifs, which `YieldOp`s assign (bottom: not assigned)."
    yields::Vector{Vector{CGVal}}
    "The types of the SSA values of the structured IR."
    ssatypes::Dict{Int,Any}
    "The block arguments (loop carries) that are read somewhere."
    usedargs::Set{Int}
    "The uses of the SSA values (see `analyze_uses!`)."
    uses::Any
    "Whether the destinations of each entry of `yields` are the results of an `if`."
    yields_if::Vector{Bool}
    "The SSA index of the control flow operation being emitted."
    opidx::Int
    "The enclosing `try` bodies."
    tries::Vector{TryTarget}
    "The handler arguments upsilon statements assign, by statement."
    upsilons::Dict{Int,CGVal}
    "The local holding the current exception at each `try` (for `pop_exception`)."
    excsaved::Dict{Int,Int}
end

FnCtx(cgm::CGModule, info::FuncInfo, sci, b::Builder, args::Vector{CGVal}=CGVal[]) =
    FnCtx(cgm, info, sci, b, args, Dict{Int,Any}(), Dict{Int,CGVal}(), LoopTarget[], 0,
          Vector{CGVal}[], Dict{Int,Any}(), Set{Int}(), Uses(), Bool[], 0, TryTarget[],
          Dict{Int,CGVal}(), Dict{Int,Int}())

layout(fc::FnCtx, @nospecialize(T)) = layout(fc.cgm.types, T)
valtypes(fc::FnCtx, @nospecialize(T)) = valtypes(fc.cgm.types, T)

"The depth of a branch to the label opened when the depth was `d`."
br_depth(fc::FnCtx, d::Int) = fc.depth - d

function open_label!(fc::FnCtx)
    fc.depth += 1
    return fc.depth
end
close_label!(fc::FnCtx) = (fc.depth -= 1)

## locals and values

"A new local of type `t`."
new_local!(fc::FnCtx, t::ValType) = add_local!(fc.b.func, t)

"Push the leaf `l` on the operand stack."
function push_leaf!(fc::FnCtx, l::LeafVal)
    if l isa Int
        emit!(fc.b, :local_get, l)
    else
        emit!(fc.b, l.op, l.imm...)
    end
end

"Push the leaves of `v` on the operand stack."
function push_val!(fc::FnCtx, v::CGVal)
    foreach(l -> push_leaf!(fc, l), v.leaves)
end

"""
    new_val!(fc, T) -> CGVal

A value of type `T` in new locals (unassigned).
"""
function new_val!(fc::FnCtx, @nospecialize(T))
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    l.kind === Bottom && return bottom()
    return CGVal(T, l.kind, LeafVal[new_local!(fc, leaf.type) for leaf in l.leaves])
end

"Assign the leaves on the operand stack to the locals of `dst`."
function pop_to!(fc::FnCtx, dst::CGVal)
    for l in Iterators.reverse(dst.leaves)
        emit!(fc.b, :local_set, l::Int)
    end
end

"""
    pop_val!(fc, T) -> CGVal

Pop a value of type `T` (its leaves) from the operand stack into new locals.
"""
function pop_val!(fc::FnCtx, @nospecialize(T))
    l = layout(fc, T)
    if l.kind === Bottom
        is_unreachable(fc.b) || unreachable!(fc.b)
        return bottom()
    end
    v = new_val!(fc, T)
    pop_to!(fc, v)
    return v
end

"Assign the value `v` to the locals of `dst` (converted to its type)."
function assign!(fc::FnCtx, dst::CGVal, v::CGVal)
    v = convert_repr(fc, v, dst.typ)
    v.kind === Bottom && return
    push_val!(fc, v)
    pop_to!(fc, dst)
end

"Push the default value of each Wasm type in `ts` (zero or null)."
function push_default!(fc::FnCtx, t::ValType)
    if t === I32
        emit!(fc.b, :i32_const, 0)
    elseif t === I64
        emit!(fc.b, :i64_const, 0)
    elseif t === F32
        emit!(fc.b, :f32_const, 0.0f0)
    elseif t === F64
        emit!(fc.b, :f64_const, 0.0)
    else
        emit!(fc.b, :ref_null, (t::RefType).heap)
    end
end

default_inst(t::ValType) =
    t === I32 ? Inst(:i32_const, 0) : t === I64 ? Inst(:i64_const, 0) :
    t === F32 ? Inst(:f32_const, 0.0f0) : t === F64 ? Inst(:f64_const, 0.0) :
    Inst(:ref_null, (t::RefType).heap)

"An undefined value of type `T` (never observed): defaults."
function undef_val(fc::FnCtx, @nospecialize(T))
    l = layout(fc, T)
    l.kind === Ghost && return ghost(T, something(ghost_value(T)))
    l.kind === Bottom && return bottom()
    return CGVal(T, l.kind, LeafVal[default_inst(leaf.type) for leaf in l.leaves])
end
