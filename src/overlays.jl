# The runtime: functions written in Julia that the code generator calls for what Wasm
# lacks (an exact fused multiply-add, ...). They are compiled into the module on demand,
# like the functions of libjulia native code calls.
#
# There are no overlays of Base's methods: inference is Julia's own (but for target facts
# like `have_fma`), so the code compiled is the code juliac compiles. What Base does with
# pointers and calls into the C runtime is compiled from the IR instead (`foreigncall.jl`,
# `pointers.jl`).

"""
    runtime_function!(cgm, f, argtypes) -> FuncInfo

The function compiled for the call `f(::argtypes...)`, which the code generator uses as
part of its runtime; it (and what it calls) is added to the closed world.
"""
function runtime_function!(cgm::CGModule, @nospecialize(f), @nospecialize(argtypes::Tuple))
    w = cgm.world
    mi = entry_instance(f, argtypes; world=w.world, extensions=w.extensions)
    haskey(w.sources, mi) || extend_world!(w, Core.MethodInstance[mi])
    return get_function!(cgm, mi)
end

"Call the runtime function `f(args...)`."
function call_runtime!(fc::FnCtx, @nospecialize(f), args::Vector{CGVal})
    info = runtime_function!(fc.cgm, f, Tuple(a.typ for a in args))
    return emit_call_info!(fc, info, CGVal[ghost(typeof(f), f), args...])
end

"""
    emit_intrinsic_call!(fc, mi, ex, typ) -> Union{Nothing,CGVal}

The code of an `:invoke` of a primitive of the runtime, which the code generator compiles
itself (a host call), or `nothing` for other calls.
"""
function emit_intrinsic_call!(fc::FnCtx, mi::Core.MethodInstance, ex::Expr, @nospecialize(typ))
    m = mi.def
    m isa Method || return nothing
    staging = staging_op(m)
    if staging !== nothing
        # a load or store of the linear memory (for WASI: see `staging.jl`), checked first as
        # natively (a Julia error, not a trap)
        fc.cgm.config.host === :wasi ||
            unsupported("the linear memory (`Runtime.Staging`) in a module for JavaScript (`Config(host = :wasi)`)")
        staging_memory!(fc.cgm)
        op, T = staging
        args = CGVal[operand(fc, a) for a in ex.args[3:end]]
        off = convert_repr(fc, args[1], UInt32)
        call_runtime!(fc, Runtime.Staging.check, CGVal[off, const_value(fc, sizeof(T))])
        push_val!(fc, off)
        align = trailing_zeros(sizeof(T))
        if length(args) == 1
            emit!(fc.b, op, align, 0)
            return pop_val!(fc, T)
        end
        push_val!(fc, convert_repr(fc, args[2], T))
        emit!(fc.b, op, align, 0)
        return ghost(Nothing, nothing)
    end
    if m.module === Runtime.IO && m.name === :write_byte
        fd, b = CGVal[operand(fc, a) for a in ex.args[3:end]]
        push_val!(fc, convert_repr(fc, fd, Int32))
        push_val!(fc, convert_repr(fc, b, UInt8))
        call!(fc.b, host_func!(fc.cgm, :write_byte))
        return ghost(Nothing, nothing)
    elseif m.module === Runtime.IO && m.name === :flush_output
        return emit_flush_output!(fc)
    elseif m.module === Runtime && m.name === :map_type
        f = mi.specTypes.parameters[2]
        return emit_map_type!(fc, f.instance, operand(fc, ex.args[4]))
    elseif m.module === Runtime && m.name === :map_type_symbol
        f = mi.specTypes.parameters[2]
        return convert_repr(fc, emit_map_type!(fc, f.instance, operand(fc, ex.args[4])), Symbol)
    elseif m.module === Runtime && m.name === :map_type_value
        f = mi.specTypes.parameters[2]
        return emit_map_type!(fc, f.instance, operand(fc, ex.args[4]))
    elseif m.module === Runtime.Tasks && m.name in TASK_PRIMITIVES
        return emit_task_primitive!(fc, m.name, mi, ex)
    elseif fc.cgm.config.tasks === :none && m.module === Base &&
           (m.name === :enq_work || (m.name === :wait && length(mi.specTypes.parameters) == 1))
        # one task: waiting can only wait forever, and there is no other task to schedule (in
        # place of the scheduler: task switches, the C runtime's queues and threads)
        msg = m.name === :wait ? "deadlock: waiting in a program of one task" : "scheduling a task in a program of one task"
        return throw_error!(fc, Runtime.throw_concurrency_error, () -> const_value(fc, msg))
    elseif m.module === Runtime.EqTables && m.name === :unset!
        # a null reference in the element
        a, i = CGVal[operand(fc, x) for x in ex.args[3:end]]
        ml = memory_layout(fc.cgm.types, Any)
        push_memory_array!(fc, a)
        push_val!(fc, convert_repr(fc, i, Int)); emit!(fc.b, :i32_wrap_i64)
        emit!(fc.b, :i32_const, 1); emit!(fc.b, :i32_sub)
        push_default!(fc, ml.storage)
        emit!(fc.b, :array_set, ml.array)
        return ghost(Nothing, nothing)
    elseif m.module === Runtime && m.name === :unset_element!
        # the element's box (an element per array element) or each of its reference leaves,
        # null: undefined (`emit_memoryref_isassigned!`)
        r = operand(fc, ex.args[3])
        E = ref_eltype(r.typ)
        ml = memory_layout(fc.cgm.types, E)
        ml.storage isa RefType && (ml.boxed || all(l -> l.type isa RefType, ml.elem.leaves)) ||
            unsupported("unsetting an element of ", E)
        for k in 0:(ml.boxed ? 0 : ml.stride - 1)
            push_element_address!(fc, r, ml, k)
            emit!(fc.b, :ref_null, (ml.storage::RefType).heap)
            emit!(fc.b, :array_set, ml.array)
        end
        return ghost(Nothing, nothing)
    elseif m.module === Runtime && m.name === :reinterpret_bits
        Out = mi.specTypes.parameters[2].parameters[1]
        In = mi.specTypes.parameters[3]
        return emit_reinterpret_bits!(fc, Out, operand(fc, ex.args[4]), In)
    end
    return nothing
end

# the loads and stores of `Runtime.Staging`: the instruction, and the type loaded or stored
const STAGING_OPS = Dict{Symbol,Tuple{Symbol,Any}}(
    :load8 => (:i32_load8_u, UInt8), :load16 => (:i32_load16_u, UInt16),
    :load32 => (:i32_load, UInt32), :load64 => (:i64_load, UInt64),
    :store8 => (:i32_store8, UInt8), :store16 => (:i32_store16, UInt16),
    :store32 => (:i32_store, UInt32), :store64 => (:i64_store, UInt64))

# the instruction and type of a load or store of `Runtime.Staging` (`m`, by its name and its
# signature: `load8(off::UInt32)`, `store8(off::UInt32, v::UInt8)`, ...), or nothing
function staging_op(m::Method)
    m.module === Runtime.Staging || return nothing
    op = get(STAGING_OPS, m.name, nothing)
    op === nothing && return nothing
    F = typeof(getglobal(Runtime.Staging, m.name))
    sig = startswith(String(m.name), "load") ? Tuple{F,UInt32} : Tuple{F,UInt32,op[2]}
    return m.sig == sig ? op : nothing
end

## tasks on JSPI stacks (`Config(tasks=:jspi)`, `Runtime.Tasks`)

const TASK_PRIMITIVES = (:alloc_task, :set_current!, :entry_slot!, :call_entry, :get_exception,
                         :set_exception!, :clear_exception!)

# the type of the task bodies' runners, `run_body(::Task, ::Type{F})`: `(ref Task) -> ()`
task_body_type!(cgm::CGModule) = functype!(cgm.mod, valtypes(cgm, Task), ValType[])

# the module's table of task body runners: one slot for each type of task body (at most 65535,
# the range of `Task.priority`, which holds a task's slot until it runs)
function task_entries_global!(cgm::CGModule)
    get!(cgm.helpers, :task_entries) do
        ft = task_body_type!(cgm)
        arr = add_type!(cgm.mod, ArrayType(FieldType(RefType(ft, true), true)))
        g = add_global!(cgm.mod, "jl_task_entries", RefType(arr, false), false,
                        Inst[Inst(:i32_const, 65536), Inst(:array_new_default, arr)])
        (g, arr, ft)
    end
end

function emit_task_primitive!(fc::FnCtx, name::Symbol, mi::Core.MethodInstance, ex::Expr)
    cgm = fc.cgm
    cgm.config.tasks === :jspi || unsupported("tasks (Runtime.Tasks) without Config(tasks=:jspi)")
    args = CGVal[operand(fc, a) for a in ex.args[3:end]]
    if name === :alloc_task
        # a task, every field zero or null (as the root task's global before its fields are set)
        ts = cgm.types
        l = layout(ts, Task)
        emit!(fc.b, :i32_const, typeid!(ts, Task))
        emit!(fc.b, :i32_const, 0)
        for f in (typedef(cgm.mod, l.wtype).comp::StructType).fields[HEADER_FIELDS+1:end]
            st = f.storage
            d = default_inst(st isa PackedType ? I32 : st)
            emit!(fc.b, d.op, d.imm...)
        end
        emit!(fc.b, :struct_new, l.wtype)
        return pop_val!(fc, Task)
    elseif name === :set_current!
        push_val!(fc, convert_repr(fc, args[1], Task))
        emit!(fc.b, :ref_as_non_null)
        emit!(fc.b, :global_set, current_task_global!(cgm))
        return ghost(Nothing, nothing)
    elseif name === :get_exception
        # (the current exception is a global: a task switch keeps it in the switching frame)
        if cgm.exceptions === :none
            emit!(fc.b, :ref_null, cgm.types.jlvalue)
        else
            emit!(fc.b, :global_get, current_exception_global!(cgm))
        end
        return pop_val!(fc, Any)
    elseif name === :set_exception! || name === :clear_exception!
        cgm.exceptions === :none && return ghost(Nothing, nothing)
        if name === :set_exception!
            push_val!(fc, convert_repr(fc, args[1], Any))
        else
            emit!(fc.b, :ref_null, cgm.types.jlvalue)
        end
        emit!(fc.b, :global_set, current_exception_global!(cgm))
        return ghost(Nothing, nothing)
    elseif name === :entry_slot!
        # the slot of `F`'s runner, given at compile time; the runner is stored there
        F = mi.specTypes.parameters[2].parameters[1]
        info = runtime_function!(cgm, Runtime.Tasks.run_body, (Task, Type{F}))
        g, arr, ft = task_entries_global!(cgm)
        info.func.type == ft || unsupported("a task body runner of type ", info.func.type, " (not ", ft, ")")
        slots = get!(() -> IdDict{Any,Int32}(), cgm.helpers, :task_slots)::IdDict{Any,Int32}
        slot = get!(slots, F, Int32(length(slots) + 1))
        slot < 65536 || unsupported("more than 65535 types of task bodies")
        emit!(fc.b, :global_get, g)
        emit!(fc.b, :i32_const, slot)
        emit!(fc.b, :ref_func, info.func)
        emit!(fc.b, :array_set, arr)
        return const_value(fc, slot)
    else # :call_entry
        g, arr, ft = task_entries_global!(cgm)
        push_val!(fc, convert_repr(fc, args[2], Task))
        emit!(fc.b, :global_get, g)
        push_val!(fc, convert_repr(fc, args[1], Int32))
        emit!(fc.b, :array_get, arr)
        emit!(fc.b, :call_ref, ft)
        return ghost(Nothing, nothing)
    end
end
