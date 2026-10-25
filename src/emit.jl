# Generating functions: declarations, the walk of the structured IR, statements, calls and
# changes of representation.

## declarations

"The Julia argument types of the function of `mi`: its signature, varargs packed in a tuple."
function function_argtypes(mi::Core.MethodInstance)
    sig = Any[Base.unwrap_unionall(mi.specTypes).parameters...]
    m = mi.def
    (m isa Method && m.isva) || return sig
    n = Int(m.nargs)
    return Any[sig[1:n-1]..., Tuple{sig[n:end]...}]
end

function function_name(cgm::CGModule, mi::Core.MethodInstance)
    m = mi.def
    base = m isa Method ? string(m.name) : "toplevel"
    return string(replace(base, r"[^A-Za-z0-9_!]" => "_"), "_", length(cgm.mod.funcs) + 1)
end

"""
    get_function!(cgm, mi) -> FuncInfo

The function of `mi`, declared on first use and queued for emission. `mi` must be in
the closed world.
"""
function get_function!(cgm::CGModule, mi::Core.MethodInstance)
    info = get(cgm.funcs, mi, nothing)
    if info !== nothing
        img = cgm.image
        # an optional function that a program function needs too is no longer optional
        info in img.optional && !(img.optional_mode || img.owner in img.optional) && promote_optional!(cgm, info)
        return info
    end
    src = get(cgm.world.sources, mi, nothing)
    src === nothing && unsupported("a call of ", mi, ", which is not in the closed world")
    ci, _ = src
    argtypes = function_argtypes(mi)
    rettype = CC.widenconst(ci.rettype)
    params = ValType[]
    for A in argtypes
        append!(params, valtypes(cgm, A))
    end
    results = layout(cgm, rettype).kind === Bottom ? ValType[] : valtypes(cgm, rettype)
    func = add_func!(cgm.mod, function_name(cgm, mi), params, results)
    info = FuncInfo(mi, func, argtypes, rettype)
    cgm.funcs[mi] = info
    # first needed by an optional function (or while its values are serialized): optional too
    img = cgm.image
    if img.optional_mode || img.owner in img.optional
        push!(img.optional, info)
        img.owner in img.optional && push!(get!(() -> Any[], img.optional_children, img.owner), info)
    end
    push!(cgm.worklist, info)
    return info
end

# The errors an optional function had become the program's (its code stays as compiled: an
# unsupported statement traps), and so do the optional functions it needed first.
function promote_optional!(cgm::CGModule, info::FuncInfo)
    img = cgm.image
    info in img.optional || return
    delete!(img.optional, info)
    errs = pop!(img.suppressed, info, Any[])
    append!(cgm.diagnostics, errs)
    info in img.failed_owners && (img.failed = true)
    for c in pop!(img.optional_children, info, Any[])
        promote_optional!(cgm, c)
    end
end

"""
    process_worklist!(cgm)

Emit the bodies of the queued functions. A function using an unsupported construct is an
error, or with `on_unsupported = :trap`, a function that traps (recorded in
`cgm.diagnostics`).
"""
function process_worklist!(cgm::CGModule)
    img = cgm.image
    while !isempty(cgm.worklist)
        info = popfirst!(cgm.worklist)
        img.optional_mode && push!(img.optional, info)
        if info in img.optional && !img.optional_mode
            with_optional_config(() -> emit_or_trap!(cgm, info), cgm)
        else
            emit_or_trap!(cgm, info)
        end
    end
end

function emit_or_trap!(cgm::CGModule, info::FuncInfo)
    try
        with_image_owner(() -> emit_function!(cgm, info), cgm.image, info)
    catch err
        err isa Unsupported || rethrow()
        push!(err.context, info.mi)
        cgm.config.on_unsupported === :trap || rethrow()
        push!(cgm.diagnostics, info.mi => err)
        empty!(info.func.body)
        empty!(info.func.locals)
        b = Builder(cgm.mod, info.func)
        unreachable!(b)
        finish!(b)
    end
end

"""
    emit_function!(cgm, info)

Emit the body of the function `info` from the structured IR of its method instance.
"""
function emit_function!(cgm::CGModule, info::FuncInfo)
    ir = prepare_ir(cgm.world, info.mi, cgm.exceptions)
    sci = try
        structurize(ir)
    catch err
        err isa Unsupported && rethrow()
        unsupported("structurizing the IR: ", sprint(showerror, err))
    end
    b = Builder(cgm.mod, info.func)
    fc = FnCtx(cgm, info, sci, b)
    collect_ssatypes!(fc.ssatypes, sci.entry)
    analyze_uses!(fc, sci.entry)
    analyze_ptr_carries!(fc, sci.entry)
    bind_arguments!(fc)
    bind_handler_args!(fc, sci.entry)
    emit_block!(fc, sci.entry)
    is_unreachable(b) || unreachable!(b)
    finish!(b)
    return info
end

# Julia's IR does not require the values of a phi on an edge to be of the phi's type (a
# branch on a type test narrows them), which IRStructurizer's terminator validation
# requires of the yields replacing phis: validate everything else.
# Loops stay `LoopOp`s and `WhileOp`s, with their own exit conditions: promoting them to
# counting `ForOp`s gains nothing on Wasm, and a `ForOp` has neither the signedness of the
# comparison it came from (`ult_int`) nor room for an inclusive bound at `typemax`
function structurize(ir::CC.IRCode)
    sci = StructuredIRCode(ir; validate=false, promote=false)
    IRStructurizer.validate_scf(sci.entry)
    IRStructurizer.validate_no_phis(sci.entry)
    return sci
end

function bind_arguments!(fc::FnCtx)
    p = 0
    for T in fc.info.argtypes
        l = layout(fc, T)
        if l.kind === Ghost
            push!(fc.args, ghost(T, something(ghost_value(T))))
        else
            n = length(l.leaves)
            push!(fc.args, CGVal(T, l.kind, LeafVal[p:p+n-1;]))
            p += n
        end
    end
end

## the walk

"""
    operand(fc, x) -> Union{CGVal,MultiVal}

The value of the operand `x` of a statement.
"""
function operand(fc::FnCtx, @nospecialize(x))
    if x isa Core.SSAValue
        v = get(fc.ssavals, x.id, nothing)
        v === nothing && unsupported("a use of the undefined SSA value %", x.id)
        return v
    elseif x isa Core.Argument
        return fc.args[x.n]
    elseif x isa IRStructurizer.BlockArgument
        return fc.blockargs[x.id]
    elseif x isa IRStructurizer.Undef
        return undef_val(fc, x.type)
    elseif x isa GlobalRef
        c = const_global(fc.cgm.world.world, x.mod, x.name)
        c === nothing || return const_value(fc, something(c))
        return nonconst_global(fc, x)
    elseif x isa QuoteNode
        return const_value(fc, x.value)
    elseif x isa Expr
        unsupported("a nested expression ", x.head)
    end
    return const_value(fc, x)
end

# the builtins of globals (and `getfield`/`isdefined` of a module's): their module is
# compile-time information only, never serialized
const GLOBAL_BUILTINS = Any[getfield(Core, s) for s in (:getglobal, :setglobal!, :isdefinedglobal,
                                                         :swapglobal!, :modifyglobal!, :replaceglobal!,
                                                         :setglobalonce!, :get_binding_type, :getfield,
                                                         :isdefined) if isdefined(Core, s)]

# an operand of a builtin of globals: a constant module is a ghost
function builtin_operand(fc::FnCtx, @nospecialize(x))
    m = x isa QuoteNode ? x.value : x
    if m isa GlobalRef
        c = const_global(fc.cgm.world.world, m.mod, m.name)
        c === nothing || (m = something(c))
    end
    m isa Module && return CGVal(Module, Ghost, LeafVal[], Some{Any}(m))
    return operand(fc, x)
end

function const_global(world::UInt, m::Module, s::Symbol)
    Base.invoke_in_world(world, isconst, m, s) || return nothing
    return Some(Base.invoke_in_world(world, getglobal, m, s))
end

"Emit the statements of `block` and its terminator."
function emit_block!(fc::FnCtx, block)
    for inst in IRStructurizer.instructions(block)
        is_unreachable(fc.b) && return
        idx = inst.ssa_idx
        stmt = inst[:stmt]
        typ = CC.widenconst(inst[:type])
        if stmt isa IRStructurizer.ControlFlowOp
            fc.opidx = idx
            fc.ssavals[idx] = emit_cfop!(fc, stmt, typ)
        elseif stmt isa Core.UpsilonNode
            emit_upsilon!(fc, idx, stmt)
        else
            res = emit_stmt_or_trap!(fc, stmt, typ)
            if res !== nothing
                if res isa CGVal && res.kind !== Bottom && typ !== Union{}
                    res = try
                        convert_repr(fc, res, typ)
                    catch err
                        err isa Unsupported || rethrow()
                        push!(err.context, string("the result of ", sprint(show, stmt; context=:limit => true), "::", typ))
                        rethrow()
                    end
                end
                fc.ssavals[idx] = res
            end
            if typ === Union{} && !is_unreachable(fc.b)
                unreachable!(fc.b)
            end
        end
    end
    is_unreachable(fc.b) && return
    emit_terminator!(fc, block.terminator)
end

function emit_terminator!(fc::FnCtx, @nospecialize(term))
    if term isa Core.ReturnNode
        if isdefined(term, :val)
            v = operand(fc, term.val)
            v = convert_repr(fc, v, fc.info.rettype)
            v.kind === Bottom && return
            push_val!(fc, v)
            return!(fc.b)
        else
            unreachable!(fc.b)
        end
    elseif term isa IRStructurizer.YieldOp
        dsts = fc.yields[end]
        length(term.values) == length(dsts) ||
            unsupported("a yield of ", length(term.values), " values to ", length(dsts), " results")
        assign_all!(fc, dsts, term.values)
    elseif term isa IRStructurizer.ContinueOp
        lt = fc.loops[end]
        assign_all!(fc, lt.carries, term.values)
        if lt.iv !== nothing
            push_val!(fc, lt.iv)
            push_val!(fc, convert_repr(fc, operand(fc, lt.step), lt.iv.typ))
            emit!(fc.b, layout(fc, lt.iv.typ).leaves[1].type === I64 ? :i64_add : :i32_add)
            pop_to!(fc, lt.iv)
        end
        br!(fc.b, br_depth(fc, lt.cont))
    elseif term isa IRStructurizer.BreakOp
        lt = fc.loops[end]
        assign_all!(fc, lt.results, term.values)
        br!(fc.b, br_depth(fc, lt.exit))
    elseif term isa IRStructurizer.LeaveOp
        # out of the innermost enclosing try body, with its results
        t = fc.tries[end]
        assign_all!(fc, t.results, term.values)
        br!(fc.b, br_depth(fc, t.exit))
    elseif term === nothing
        # a block that does not end (its last statement never returns)
    else
        unsupported("the terminator ", typeof(term))
    end
end

# assign values to locals, evaluating all values before assigning (a value may read a
# local that is assigned)
# assign the values `vals` to the destinations `dsts` (as one parallel assignment); an
# undefined value leaves its destination as it is (it is not read), and a bottom
# destination is an aliased result, not assigned
function assign_all!(fc::FnCtx, dsts::Vector{CGVal}, vals)
    pairs = [(d, v) for (d, v) in zip(dsts, vals)
             if d.kind !== Bottom && !(v isa IRStructurizer.Undef) && !same_locals(fc, d, v)]
    srcs = CGVal[convert_repr(fc, operand(fc, v), d.typ) for (d, v) in pairs]
    for (s, (d, _)) in zip(srcs, pairs)
        s.kind === Bottom && continue
        push_val!(fc, s)
        d.origin === nothing || push_origin_index!(fc, d.origin, s)
    end
    for i in reverse(eachindex(pairs))
        srcs[i].kind === Bottom && continue
        d = pairs[i][1]
        d.origin === nothing || emit!(fc.b, :local_set, d.origin.index::Int)
        pop_to!(fc, d)
    end
end

# push the byte offset of the pointer `s` into the array of the origin `o` of a carry: that of
# its own origin into the same array, else the low bits of its address (it points into the same object)
function push_origin_index!(fc::FnCtx, o::PtrOrigin, s::CGVal)
    so = array_origin(s)
    if so !== nothing && so.mem == o.mem && so.array == o.array
        push_leaf!(fc, so.index)
    else
        # an object's addresses are its base (in the high 32 bits) plus the offset
        push_leaf!(fc, s.leaves[1])
        emit!(fc.b, :i32_wrap_i64)
    end
end

# A statement; where it cannot be compiled, a trap, and the error is recorded: with
# `trim = :safe` the compilation fails at the end with every such error (as juliac's
# verifier reports them all), with `trim = :unsafe` the trap stays.
function emit_stmt_or_trap!(fc::FnCtx, @nospecialize(stmt), @nospecialize(typ))
    # (a statement that fails leaves no partial code: its instructions are dropped)
    mark = length(fc.b.func.body)
    stack = copy(fc.b.stack)
    frames = copy(fc.b.frames)
    inits = copy(fc.b.inits)
    depth = fc.depth
    try
        return emit_stmt!(fc, stmt, typ)
    catch err
        err isa Unsupported || rethrow()
        resize!(fc.b.func.body, mark)
        fc.b.stack = stack
        fc.b.frames = frames
        fc.b.inits = inits
        fc.depth = depth
        push!(err.context, string("the statement ", sprint(show, stmt; context=:limit => true), "::", typ))
        push!(err.context, fc.info.mi)
        push!(fc.cgm.diagnostics, fc.info.mi => err)
        unreachable!(fc.b)
        return bottom()
    end
end

## structured control flow

result_types(@nospecialize(typ)) =
    typ isa DataType && typ <: Tuple ? Any[typ.parameters...] : Any[]

function new_vals!(fc::FnCtx, types)
    return CGVal[new_val!(fc, T) for T in types]
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.IfOp, @nospecialize(typ))
    rtypes = result_types(typ)
    # a result that both arms yield as the same value (or one of them as undefined) is
    # that value: no locals, no copies (Wasm locals live in the whole function, and on the
    # undefined arm the result is not read)
    aliases = Any[if_alias(fc, op, i, rtypes[i]) for i in eachindex(rtypes)]
    results = CGVal[aliases[i] === nothing ? result_val!(fc, fc.opidx, i, rtypes[i]) : bottom()
                    for i in eachindex(rtypes)]
    c = convert_repr(fc, operand(fc, op.condition), Bool)
    if isconstant(c)
        # a branch on a constant: only one arm
        push!(fc.yields, results); push!(fc.yields_if, true)
        emit_region!(fc, constant_value(c) ? op.then_region : op.else_region)
        pop!(fc.yields); pop!(fc.yields_if)
    else
        push_val!(fc, c)
        if!(fc.b)
        open_label!(fc)
        push!(fc.yields, results); push!(fc.yields_if, true)
        emit_region!(fc, op.then_region)
        else!(fc.b)
        emit_region!(fc, op.else_region)
        pop!(fc.yields); pop!(fc.yields_if)
        end!(fc.b)
        close_label!(fc)
    end
    for (i, a) in enumerate(aliases)
        a === nothing && continue
        # (defined in an arm that does not complete: no value, the result is not read)
        v = a isa Core.SSAValue && !haskey(fc.ssavals, a.id) ? undef_val(fc, rtypes[i]) : operand(fc, a)
        results[i] = v isa CGVal && v.kind !== Bottom ? convert_repr(fc, v, rtypes[i]) : undef_val(fc, rtypes[i])
    end
    return MultiVal(results)
end

# the value the result `i` of an if is, when every arm that yields it yields that one
# value or undefined, and the value has the representation of the result's type
function if_alias(fc::FnCtx, op::IRStructurizer.IfOp, i::Int, @nospecialize(T))
    # (a yielded value may be `nothing` itself: whether one was found is a flag)
    found = false
    v = nothing
    for r in (op.then_region, op.else_region)
        t = r.terminator
        t isa IRStructurizer.YieldOp || continue
        x = t.values[i]
        x isa IRStructurizer.Undef && continue
        if !found
            v, found = x, true
        elseif !(v === x)
            return nothing
        end
    end
    found || return nothing
    S = static_type(fc, v)
    S === nothing && return nothing
    return same_repr(fc, S, T) ? v : nothing
end

# the type of an operand, before it is emitted (or nothing if not known)
function static_type(fc::FnCtx, @nospecialize(x))
    if x isa Core.SSAValue
        return get(fc.ssatypes, x.id, nothing)
    elseif x isa IRStructurizer.BlockArgument
        return CC.widenconst(x.type)
    elseif x isa Core.Argument
        return x.n <= length(fc.info.argtypes) ? fc.info.argtypes[x.n] : nothing
    elseif x isa QuoteNode
        return Core.Typeof(x.value)
    elseif x isa GlobalRef || x isa Expr || x isa IRStructurizer.Undef
        return nothing
    end
    return Core.Typeof(x)
end

# whether the value `v` (an operand) is in the locals of `d` already
function same_locals(fc::FnCtx, d::CGVal, @nospecialize(v))
    v isa Core.SSAValue && haskey(fc.ssavals, v.id) || return false
    x = fc.ssavals[v.id]
    return x isa CGVal && x.typ === d.typ && x.leaves == d.leaves
end

# whether a value of type S is a value of type T without a conversion that emits code
function same_repr(fc::FnCtx, @nospecialize(S), @nospecialize(T))
    S === T && return true
    S <: T || return false
    ls, lt = layout(fc, S), layout(fc, T)
    if ls.kind === Inline && lt.kind === Inline
        return length(ls.leaves) == length(lt.leaves) &&
               all(i -> ls.leaves[i].type == lt.leaves[i].type, eachindex(lt.leaves))
    elseif ls.kind === Boxed && lt.kind === Boxed
        return ls.wtype == lt.wtype ||
               (lt.wtype == fc.cgm.types.jlvalue && is_jlvalue_type(fc.cgm.types, S))
    end
    return false
end

"""
    Uses

What the code generator needs to know about the uses of SSA values: how many times each
is used, which is used by the terminator of the block defining it (and at which position
of its values), and the projections `getfield(op, i)` of the results of control flow
operations.
"""
struct Uses
    count::Dict{Int,Int}
    interm::Dict{Int,Tuple{Any,Int}}
    defblock::Dict{Int,Any}
    projections::Dict{Tuple{Int,Int},Vector{Int}}
    "The pointer loop carries that keep the origin of their initial value (`analyze_ptr_carries!`)."
    ptrcarries::Set{Int}
end
Uses() = Uses(Dict{Int,Int}(), Dict{Int,Tuple{Any,Int}}(), Dict{Int,Any}(), Dict{Tuple{Int,Int},Vector{Int}}(),
              Set{Int}())

"""
    analyze_uses!(fc, block)

Find the block arguments that are read (`fc.usedargs`: a loop carry nothing reads is not
kept) and the uses of SSA values (`fc.uses`).
"""
function analyze_uses!(fc::FnCtx, block)
    u = fc.uses
    function use!(@nospecialize(v))
        v isa IRStructurizer.BlockArgument && push!(fc.usedargs, v.id)
        v isa Core.SSAValue && (u.count[v.id] = get(u.count, v.id, 0) + 1)
    end
    for inst in IRStructurizer.instructions(block)
        st = inst[:stmt]
        u.defblock[inst.ssa_idx] = block
        if st isa IRStructurizer.ControlFlowOp
            foreach(use!, IRStructurizer.operands(st))
            foreach(b -> analyze_uses!(fc, b), IRStructurizer.blocks(st))
        else
            foreach(use!, IRStructurizer.operands(block, st))
            # a projection of a result of a control flow operation
            if st isa Expr && st.head === :call && length(st.args) == 3 &&
               st.args[2] isa Core.SSAValue && st.args[3] isa Int
                push!(get!(Vector{Int}, u.projections, (st.args[2].id, st.args[3])), inst.ssa_idx)
            end
        end
    end
    t = block.terminator
    t === nothing && return
    for name in fieldnames(typeof(t))
        isdefined(t, name) || continue
        x = getfield(t, name)
        if x isa AbstractVector
            for (j, v) in enumerate(x)
                use!(v)
                v isa Core.SSAValue && (u.interm[v.id] = (block, j))
            end
        else
            use!(x)
        end
    end
end

"""
    analyze_ptr_carries!(fc, block)

Find the loop carries of pointer type that are always the same pointer, moved: every value
flowing into the carry (initial, continued) is derived through `add_ptr`, `sub_ptr` and
pointer-to-pointer `bitcast` from one pointer `r`, or from carries that are themselves
derived only from `r`. Such a carry points into the object `r` points into, so it keeps the
origin of its initial value, with the byte offset carried alongside (`fc.uses.ptrcarries`):
accesses through it inside the loop compile to array accesses, as accesses through `r` do.
"""
function analyze_ptr_carries!(fc::FnCtx, block)
    stmts = Dict{Int,Any}()
    incoming = Dict{Int,Vector{Any}}()
    carrytypes = Dict{Int,Any}()
    collect_ptr_flow!(stmts, incoming, carrytypes, block, IRStructurizer.BlockArgument[])
    ptrcarry(id) = haskey(carrytypes, id) && is_ptr_type(CC.widenconst(carrytypes[id]))
    # the roots of the pointer carries: the least fixed point of
    # roots(c) = union of the bases of its incoming values, where the base of a value is the
    # pointer it is derived from, expanded to the roots of a carry
    world = fc.cgm.world.world
    bases = Dict{Int,Vector{Any}}(id => Any[ptr_base(fc, stmts, world, x) for x in xs
                                            if !(x isa IRStructurizer.Undef)]
                                  for (id, xs) in incoming if ptrcarry(id))
    roots = Dict{Int,Set{Any}}(id => Set{Any}() for id in keys(bases))
    changed = true
    while changed
        changed = false
        for (id, bs) in bases, b in bs
            add = b isa IRStructurizer.BlockArgument && haskey(roots, b.id) ? roots[b.id] : (b,)
            for r in add
                r in roots[id] && continue
                push!(roots[id], r); changed = true
            end
        end
    end
    for (id, rs) in roots
        length(rs) == 1 && only(rs) !== nothing && push!(fc.uses.ptrcarries, id)
    end
end

function add_incoming!(incoming, carrytypes, args, vals)
    for (a, v) in zip(args, vals)
        push!(get!(Vector{Any}, incoming, a.id), v)
        carrytypes[a.id] = a.type
    end
end

# the values flowing into the carries of `LoopOp`s (the loops `structurize` makes): initial
# values and the values of the `continue`s of the innermost enclosing loop; the carries of other
# loops get no origin
function collect_ptr_flow!(stmts, incoming, carrytypes, block, carries)
    for inst in IRStructurizer.instructions(block)
        st = inst[:stmt]
        stmts[inst.ssa_idx] = st
        if st isa IRStructurizer.LoopOp
            add_incoming!(incoming, carrytypes, st.body.args, st.init_values)
            collect_ptr_flow!(stmts, incoming, carrytypes, st.body, st.body.args)
        elseif st isa IRStructurizer.ControlFlowOp
            inner = st isa IRStructurizer.ForOp || st isa IRStructurizer.WhileOp ? IRStructurizer.BlockArgument[] : carries
            for b in IRStructurizer.blocks(st)
                collect_ptr_flow!(stmts, incoming, carrytypes, b, inner)
            end
        end
    end
    t = block.terminator
    t isa IRStructurizer.ContinueOp && add_incoming!(incoming, carrytypes, carries, t.values)
end

# the pointer `v` is derived from through `add_ptr`, `sub_ptr` and pointer-to-pointer
# `bitcast`s (`v` itself if none); `nothing` for a value that is not a known pointer
function ptr_base(fc::FnCtx, stmts, world, @nospecialize(v))
    while v isa Core.SSAValue
        st = get(stmts, v.id, nothing)
        (st isa Expr && st.head === :call && length(st.args) == 3) || break
        f = st.args[1]
        if f isa GlobalRef
            c = const_global(world, f.mod, f.name)
            f = c === nothing ? nothing : something(c)
        end
        if f === Core.Intrinsics.add_ptr || f === Core.Intrinsics.sub_ptr
            v = st.args[2]
        elseif f === Core.Intrinsics.bitcast && is_ptr_type(CC.widenconst(ptr_value_type(fc, st.args[3])))
            v = st.args[3]
        else
            break
        end
    end
    return v isa Core.SSAValue || v isa IRStructurizer.BlockArgument ? v : nothing
end

ptr_value_type(fc::FnCtx, @nospecialize(v)) =
    v isa Core.SSAValue ? get(fc.ssatypes, v.id, Any) :
    v isa IRStructurizer.BlockArgument ? v.type : Any

# the locals of the result `i` of the control flow operation `opidx`: those of the
# enclosing `if`'s result it is forwarded to, or new ones
function result_val!(fc::FnCtx, opidx::Int, i::Int, @nospecialize(T))
    d = forwarded_result(fc, opidx, i, T)
    return d === nothing ? new_val!(fc, T) : d
end

"""
    forwarded_result(fc, opidx, i, T) -> Union{Nothing,CGVal}

Where the result `i` of the control flow operation `opidx` only goes to the yield that ends
its block, to the results of the enclosing `if`: that destination, which the operation
can assign directly (destination passing: a chain of nested merges shares its locals
instead of copying at each level). An `if`'s results cannot be read inside the `if`, so
nothing reads them before the yield; a loop's carries could be, and are never forwarded
to.
"""
function forwarded_result(fc::FnCtx, opidx::Int, i::Int, @nospecialize(T))
    u = fc.uses
    (isempty(fc.yields) || !fc.yields_if[end]) && return nothing
    ps = get(u.projections, (opidx, i), nothing)
    (ps !== nothing && length(ps) == 1) || return nothing
    p = only(ps)
    get(u.count, p, 0) == 1 || return nothing
    t = get(u.interm, p, nothing)
    t === nothing && return nothing
    block, j = t
    block === get(u.defblock, opidx, nothing) || return nothing
    block.terminator isa IRStructurizer.YieldOp || return nothing
    dsts = fc.yields[end]
    j <= length(dsts) || return nothing
    d = dsts[j]
    (d.kind !== Bottom && d.typ === T) || return nothing
    return d
end

function collect_ssatypes!(d::Dict{Int,Any}, block)
    for inst in IRStructurizer.instructions(block)
        d[inst.ssa_idx] = CC.widenconst(inst[:type])
        st = inst[:stmt]
        if st isa IRStructurizer.ControlFlowOp
            for b in IRStructurizer.blocks(st)
                collect_ssatypes!(d, b)
            end
        end
    end
end

# emit a region in its own scope of block arguments
function emit_region!(fc::FnCtx, block)
    emit_block!(fc, block)
end

function bind_block_args!(fc::FnCtx, args, vals::Vector{CGVal})
    for (a, v) in zip(args, vals)
        fc.blockargs[a.id] = v
    end
end

# the locals of the carries of a loop; a carry nothing reads has none (bottom: its
# assignments are dropped)
function carry_vals!(fc::FnCtx, args, inits=fill(nothing, length(args)))
    return CGVal[a.id in fc.usedargs ? carry_val!(fc, a, init) : bottom() for (a, init) in zip(args, inits)]
end

# the locals of a carry, and for a pointer carry that keeps its origin, the byte offset
# into the array of the origin of its initial value `init`
function carry_val!(fc::FnCtx, a, @nospecialize(init))
    v = new_val!(fc, CC.widenconst(a.type))
    a.id in fc.uses.ptrcarries || return v
    (init === nothing || init isa IRStructurizer.Undef) && return v
    x = operand(fc, init)
    o = x isa CGVal ? array_origin(x) : nothing
    o === nothing && return v
    return CGVal(v.typ, v.kind, v.leaves, nothing,
                 PtrOrigin(o.mem, o.array, new_local!(fc, I32), o.eltype, o.terminated))
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.LoopOp, @nospecialize(typ))
    carries = carry_vals!(fc, op.body.args, op.init_values)
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.body.args, carries)
    results = CGVal[result_val!(fc, fc.opidx, i, R) for (i, R) in enumerate(result_types(typ))]
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    push!(fc.loops, LoopTarget(exit, cont, carries, results, nothing, nothing))
    emit_block!(fc, op.body)
    pop!(fc.loops)
    # falling off the end of the body does not happen (it continues or breaks)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(results)
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.ForOp, @nospecialize(typ))
    ivT = CC.widenconst(op.iv_arg.type)
    iv = new_val!(fc, ivT)
    assign!(fc, iv, convert_repr(fc, operand(fc, op.lower), ivT))
    fc.blockargs[op.iv_arg.id] = iv
    carries = carry_vals!(fc, op.body.args)
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.body.args, carries)
    upper = convert_repr(fc, operand(fc, op.upper), ivT)
    is64 = layout(fc, ivT).leaves[1].type === I64
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    # exit unless iv < upper (signed)
    push_val!(fc, iv)
    push_val!(fc, upper)
    emit!(fc.b, is64 ? :i64_ge_s : :i32_ge_s)
    br_if!(fc.b, br_depth(fc, exit))
    push!(fc.loops, LoopTarget(exit, cont, carries, carries, iv, op.step))
    emit_block!(fc, op.body)
    pop!(fc.loops)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(carries)
end

function emit_cfop!(fc::FnCtx, op::IRStructurizer.WhileOp, @nospecialize(typ))
    carries = carry_vals!(fc, op.before.args)
    assign_all!(fc, carries, op.init_values)
    bind_block_args!(fc, op.before.args, carries)
    results = CGVal[result_val!(fc, fc.opidx, i, R) for (i, R) in enumerate(result_types(typ))]
    block!(fc.b); exit = open_label!(fc)
    loop!(fc.b); cont = open_label!(fc)
    push!(fc.loops, LoopTarget(exit, cont, carries, results, nothing, nothing))
    # the before region, up to its condition
    for inst in IRStructurizer.instructions(op.before)
        is_unreachable(fc.b) && break
        stmt = inst[:stmt]
        typ_i = CC.widenconst(inst[:type])
        if stmt isa IRStructurizer.ControlFlowOp
            fc.opidx = inst.ssa_idx
            fc.ssavals[inst.ssa_idx] = emit_cfop!(fc, stmt, typ_i)
        else
            res = emit_stmt_or_trap!(fc, stmt, typ_i)
            res isa CGVal && res.kind !== Bottom && typ_i !== Union{} &&
                (res = convert_repr(fc, res, typ_i))
            res === nothing || (fc.ssavals[inst.ssa_idx] = res)
            typ_i === Union{} && !is_unreachable(fc.b) && unreachable!(fc.b)
        end
    end
    if !is_unreachable(fc.b)
        term = op.before.terminator
        if term isa IRStructurizer.ConditionOp
            c = convert_repr(fc, operand(fc, term.condition), Bool)
            # on false: the condition's values are the results
            push_val!(fc, c)
            emit!(fc.b, :i32_eqz)
            if!(fc.b); open_label!(fc)
            assign_all!(fc, results, term.args)
            br!(fc.b, br_depth(fc, exit))
            end!(fc.b); close_label!(fc)
            # on true: they are the arguments of the after region
            afterargs = new_vals!(fc, [CC.widenconst(a.type) for a in op.after.args])
            assign_all!(fc, afterargs, term.args)
            bind_block_args!(fc, op.after.args, afterargs)
            # the after region yields the next carried values
            push!(fc.yields, carries); push!(fc.yields_if, false)
            emit_block!(fc, op.after)
            pop!(fc.yields); pop!(fc.yields_if)
            is_unreachable(fc.b) || br!(fc.b, br_depth(fc, cont))
        else
            emit_terminator!(fc, term)
        end
    end
    pop!(fc.loops)
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b); close_label!(fc)
    end!(fc.b); close_label!(fc)
    return MultiVal(results)
end

## statements

const NOOP_HEADS = (:code_coverage_effect, :meta, :inbounds, :loopinfo, :aliasscope,
                    :popaliasscope, :latestworld, :gc_preserve_end)

"""
    emit_stmt!(fc, stmt, typ) -> Union{Nothing,CGVal,MultiVal}

Emit a (non control flow) statement of type `typ`, returning its value.
"""
function emit_stmt!(fc::FnCtx, @nospecialize(stmt), @nospecialize(typ))
    if stmt isa Expr
        return emit_expr!(fc, stmt, typ)
    elseif stmt isa Core.PiNode
        return emit_pi!(fc, operand(fc, stmt.val), typ)
    elseif stmt === nothing
        return nothing
    elseif stmt isa Core.GotoNode || stmt isa Core.GotoIfNot || stmt isa Core.PhiNode
        unsupported("unstructured control flow (", typeof(stmt), ")")
    elseif stmt isa Core.EnterNode || stmt isa Core.PhiCNode
        unsupported("exception handling (", typeof(stmt), ")")
    else
        return operand(fc, stmt)
    end
end

"""
    emit_pi!(fc, v, T) -> CGVal

A `PiNode`: `v` narrowed to `T`. Julia's optimizer places narrowing as an assumption, not a
check, sometimes where it does not hold (a value forwarded with a flag saying whether it is
`nothing`, read only where it is not): a boxed value is converted only if it is a `T`, and
is otherwise left undefined (not read).
"""
function emit_pi!(fc::FnCtx, v::CGVal, @nospecialize(T))
    S = v.typ
    ((v.kind === Boxed && layout(fc, S).wtype == fc.cgm.types.jlvalue) || is_union_tuple(S)) && !(S <: T) ||
        return convert_repr(fc, v, T)
    layout(fc, T).kind === Ghost && return convert_repr(fc, v, T)
    t = emit_isa!(fc, v, T)
    isconstant(t) && return constant_value(t) ? convert_repr(fc, v, T) : undef_val(fc, T)
    res = new_val!(fc, T)
    push_val!(fc, t)
    if!(fc.b)
    assign!(fc, res, v)
    end!(fc.b)
    return res
end

function emit_expr!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    head = ex.head
    if head === :call
        return emit_call!(fc, ex, typ)
    elseif head === :invoke
        return emit_invoke!(fc, ex, typ)
    elseif head === :invoke_modify
        # `modifyfield!(x, f, op, v, order)` with the method of `op` resolved
        args = Any[operand(fc, a) for a in ex.args[3:end]]
        return emit_builtin!(fc, Core.modifyfield!, args, typ)
    elseif head === :new
        T = operand(fc, ex.args[1])
        isconstant(T) || unsupported("`new` of a type that is not known at compile time")
        args = CGVal[operand(fc, a) for a in ex.args[2:end]]
        return emit_new!(fc, constant_value(T), args)
    elseif head === :splatnew
        T = operand(fc, ex.args[1])
        isconstant(T) || unsupported("`splatnew` of a type that is not known at compile time")
        tup = operand(fc, ex.args[2])
        return emit_new!(fc, constant_value(T), tuple_elements(fc, tup))
    elseif head === :boundscheck
        cb = Base.JLOptions().check_bounds
        cb == 1 && return const_value(fc, true)
        cb == 2 && return const_value(fc, false)
        return const_value(fc, isempty(ex.args) ? true : ex.args[1] !== false)
    elseif head === :static_parameter
        return const_value(fc, fc.info.mi.sparam_vals[ex.args[1]::Int])
    elseif head === :foreigncall
        return emit_foreigncall!(fc, ex, typ)
    elseif head === :cfunction
        return emit_cfunction!(fc, ex, typ)
    elseif head in NOOP_HEADS
        return nothing
    elseif head === :gc_preserve_begin
        return ghost(Nothing, nothing)
    elseif head === :throw_undef_if_not
        c = convert_repr(fc, operand(fc, ex.args[2]), Bool)
        isconstant(c) && constant_value(c) && return nothing
        push_val!(fc, c)
        emit!(fc.b, :i32_eqz)
        if!(fc.b); throw_error!(fc, Runtime.throw_undefvar_error, const_value(fc, ex.args[1]::Symbol)); end!(fc.b)
        return nothing
    elseif head === :isdefined
        x = ex.args[1]
        x isa GlobalRef && return isdefined_global!(fc, x)
        unsupported("isdefined of ", x)
    elseif head === :the_exception
        return emit_the_exception!(fc)
    elseif head === :pop_exception
        return emit_pop_exception!(fc, ex.args[1])
    else
        unsupported("the expression head ", head)
    end
end

## calls

function emit_call!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    f = operand(fc, ex.args[1])
    (f isa CGVal && isconstant(f)) ||
        unsupported("a call of a function value of type ", f isa CGVal ? f.typ : f)
    fv = constant_value(f)
    args = Any[any(g -> fv === g, GLOBAL_BUILTINS) ? builtin_operand(fc, a) : operand(fc, a) for a in ex.args[2:end]]
    if fv isa Core.IntrinsicFunction
        return emit_intrinsic!(fc, fv, args, typ)
    elseif fv isa Core.Builtin
        return emit_builtin!(fc, fv, args, typ)
    elseif typ === Union{}
        # an error path whose call was not resolved
        unreachable!(fc.b)
        return bottom()
    else
        unsupported("a dynamic call of ", fv, " with argument types (",
                    join([a isa CGVal ? string(a.typ) : "?" for a in args], ", "), ")")
    end
end

function emit_invoke!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    target = ex.args[1]
    mi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
    mi isa Core.MethodInstance || unsupported("an invoke of ", target)
    r = emit_intrinsic_call!(fc, mi, ex, typ)
    r === nothing || return r
    info = get_function!(fc.cgm, mi)
    args = CGVal[operand(fc, a) for a in ex.args[2:end]]
    return emit_call_info!(fc, info, args)
end

"""
    emit_call_info!(fc, info, args) -> CGVal

Call the function `info` with the values `args` (the function object first).
"""
function emit_call_info!(fc::FnCtx, info::FuncInfo, args::Vector{CGVal})
    m = info.mi.def
    if m isa Method && m.isva
        n = Int(m.nargs)
        rest = args[n:end]
        T = info.argtypes[end]
        args = CGVal[args[1:n-1]..., make_tuple(fc, T, rest)]
    end
    length(args) == length(info.argtypes) ||
        unsupported("a call of ", info.mi, " with ", length(args), " arguments")
    for (a, T) in zip(args, info.argtypes)
        v = convert_repr(fc, a, T)
        v.kind === Bottom && return v
        push_val!(fc, v)
    end
    call!(fc.b, info.func)
    if layout(fc, info.rettype).kind === Bottom
        unreachable!(fc.b)
        return bottom()
    end
    return pop_val!(fc, info.rettype)
end

## changes of representation

"""
    convert_repr(fc, v, T) -> CGVal

The value `v` in the representation of type `T` (`v` is of type `T`, or of a type whose
values may be of type `T`): boxing an inline value for an abstract type, unboxing a boxed
value for a concrete one.
"""
function convert_repr(fc::FnCtx, v, @nospecialize(T))
    v isa MultiVal && unsupported("a use of the results of a control flow operation as a value")
    v = v::CGVal
    v.typ === T && return v
    v.kind === Bottom && return v
    lt = layout(fc, T)
    lv = layout(fc, v.typ)
    if lt.kind === Bottom
        is_unreachable(fc.b) || unreachable!(fc.b)
        return bottom()
    elseif lt.kind === Ghost
        return ghost(T, something(ghost_value(T)))
    elseif lt.kind === Inline
        if lv.kind === Inline
            if !(length(lv.leaves) == length(lt.leaves) &&
                 all(i -> lv.leaves[i].type == lt.leaves[i].type, eachindex(lt.leaves)))
                # tuples of different representations of their elements (an element of a
                # union and one of its types): element by element
                (v.typ <: Tuple && T <: Tuple && !Base.isvatuple(v.typ) && !Base.isvatuple(T) &&
                 fieldcount(v.typ) == fieldcount(T)) || return no_conversion!(fc, v.typ, T)
                leaves = LeafVal[]
                for i in 1:fieldcount(T)
                    e = convert_repr(fc, get_field(fc, v, i), fieldtype(T, i))
                    e.kind === Bottom && return e
                    append!(leaves, e.leaves)
                end
                return CGVal(T, Inline, leaves)
            end
            return CGVal(T, Inline, v.leaves, v.constant, v.origin)
        elseif lv.kind === Boxed && lv.elements !== nothing
            # a tuple of unknown length (an array) as a tuple of known length: its elements
            leaves = LeafVal[]
            for i in 1:fieldcount(T)
                e = convert_repr(fc, tuple_array_get!(fc, v, const_value(fc, i)), fieldtype(T, i))
                append!(leaves, e.leaves)
            end
            return CGVal(T, Inline, leaves)
        elseif lv.kind === Boxed && is_union_tuple(T)
            return unbox_union_tuple!(fc, v, T)
        elseif lv.kind === Boxed
            return unbox!(fc, v, T)
        else
            return no_conversion!(fc, v.typ, T)
        end
    else # Boxed
        if lt.wtype == fc.cgm.types.jlvalue
            # an abstract type: any object
            if lv.kind === Boxed && is_jlvalue_type(fc.cgm.types, v.typ)
                return CGVal(T, Boxed, v.leaves, v.constant)
            end
            return box!(fc, v, T)
        elseif lv.kind === Boxed && lv.wtype == lt.wtype
            return CGVal(T, Boxed, v.leaves, v.constant)
        elseif lt.elements !== nothing && lv.kind in (Inline, Ghost) && v.typ <: Tuple
            # a tuple of known length as a tuple of unknown length (an array)
            return new_tuple_array!(fc, T, CGVal[get_field(fc, v, i) for i in 1:fieldcount(v.typ)])
        elseif lv.kind === Boxed && lv.wtype == fc.cgm.types.jlvalue
            return unbox!(fc, v, T)
        else
            return no_conversion!(fc, v.typ, T)
        end
    end
end

"""
    box!(fc, v, T) -> CGVal

The value `v` as an object (a `\$JlValue`), of the abstract type `T`.
"""
function box!(fc::FnCtx, v::CGVal, @nospecialize(T))
    ts = fc.cgm.types
    S = v.typ
    lv = layout(fc, S)
    if isconstant(v)
        g = boxed_object_global!(fc.cgm.image, constant_value(v))
        return CGVal(T, Boxed, LeafVal[Inst(:global_get, g)], v.constant)
    end
    lv.kind === Ghost && unsupported("boxing the ghost ", S, " without its value")
    is_union_tuple(S) && return CGVal(T, Boxed, box_union_tuple!(fc, v).leaves)
    # by a helper per type (outline.jl)
    r = call_outlined!(fc, (:box, S), "box_" * typename_str(S), CGVal[v], Any, box_inline!)
    return CGVal(T, Boxed, r.leaves)
end

function box_inline!(fc::FnCtx, args::Vector{CGVal})
    ts = fc.cgm.types
    v = only(args)
    S = v.typ
    box = box_type!(ts, S)
    emit!(fc.b, :i32_const, typeid!(ts, S))
    emit!(fc.b, :i32_const, 0)
    push_val!(fc, v)
    emit!(fc.b, :struct_new, box)
    return pop_val!(fc, Any)
end

"""
    unbox!(fc, v, T) -> CGVal

The object `v` (a `\$JlValue`) as a value of the concrete type `T` (which it is).
"""
function unbox!(fc::FnCtx, v::CGVal, @nospecialize(T))
    ts = fc.cgm.types
    is_union_tuple(T) && return unbox_union_tuple!(fc, v, T)
    lt = layout(fc, T)
    if lt.kind === Boxed && is_jlvalue_type(ts, T)
        push_val!(fc, v)
        emit!(fc.b, :ref_cast_null, lt.wtype)
        return pop_val!(fc, T)
    end
    # an inline value, a Memory or a String: in a box, unpacked by a helper per type
    return call_outlined!(fc, (:unbox, T), "unbox_" * typename_str(T),
                          CGVal[CGVal(Any, Boxed, v.leaves)], T, (h, a) -> unbox_inline!(h, a[1], T))
end

function unbox_inline!(fc::FnCtx, v::CGVal, @nospecialize(T))
    ts = fc.cgm.types
    box = box_type!(ts, T)
    push_val!(fc, v)
    emit!(fc.b, :ref_cast_null, box)
    tmp = new_local!(fc, RefType(box, true))
    emit!(fc.b, :local_set, tmp)
    fields = (typedef(ts.mod, box).comp::StructType).fields
    for i in HEADER_FIELDS+1:length(fields)
        emit!(fc.b, :local_get, tmp)
        st = fields[i].storage
        emit!(fc.b, st isa PackedType ? :struct_get_u : :struct_get, box, i - 1)
    end
    return pop_val!(fc, T)
end

## tuples with union elements

# whether the union tuple `v` is of the concrete tuple type `C` (its union elements)
function union_tuple_isa!(fc::FnCtx, v::CGVal, @nospecialize(C))
    res = const_value(fc, true)
    for i in 1:fieldcount(C)
        P = fieldtype(v.typ, i)
        isconcretetype(P) && continue
        e = get_field(fc, v, i)
        t = P isa Union ? emit_isa!(fc, e, fieldtype(C, i)) : union_tuple_isa!(fc, e, fieldtype(C, i))
        isconstant(res) ? (res = t) : (push_val!(fc, res); push_val!(fc, t); emit!(fc.b, :i32_and); res = pop_val!(fc, Bool))
    end
    return res
end

"The union tuple `v` boxed: as the concrete tuple type its elements make it."
function box_union_tuple!(fc::FnCtx, v::CGVal)
    res = new_val!(fc, Any)
    combos = tuple_combinations(v.typ)
    for (k, C) in enumerate(combos)
        if k < length(combos)
            push_val!(fc, union_tuple_isa!(fc, v, C))
            if!(fc.b)
        end
        assign!(fc, res, box!(fc, convert_repr(fc, v, C), Any))
        k < length(combos) && else!(fc.b)
    end
    for _ in 1:length(combos)-1
        end!(fc.b)
    end
    return res
end

"The boxed value `v` as the union tuple type `T`: of whichever of its concrete types it is."
function unbox_union_tuple!(fc::FnCtx, v::CGVal, @nospecialize(T))
    res = new_val!(fc, T)
    combos = tuple_combinations(T)
    x = convert_repr(fc, v, Any)
    for (k, C) in enumerate(combos)
        push_val!(fc, emit_isa!(fc, x, C))
        if!(fc.b)
        assign!(fc, res, convert_repr(fc, convert_repr(fc, x, C), T))
        else!(fc.b)
    end
    unreachable!(fc.b)
    for _ in 1:length(combos)
        end!(fc.b)
    end
    return res
end

# a value of type `S` where one of type `T` is expected, of another representation: where
# the types have no value in common, code that does not run (inference put it there,
# after a test that cannot pass), a trap; else unsupported
function no_conversion!(fc::FnCtx, @nospecialize(S), @nospecialize(T))
    typeintersect(S, T) === Union{} || unsupported("a conversion from ", S, " to ", T)
    is_unreachable(fc.b) || unreachable!(fc.b)
    return bottom()
end
