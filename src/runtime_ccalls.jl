# The rest of the calls into Julia's C runtime and the C library that the runtime answers
# (see `foreigncall.jl`): functions it implements (`runtime/jlapi.jl`, `runtime/libc.jl`),
# constants of a program of one thread and one task, without signals, finalizers that run
# or compilation at run time, and the C runtime's global variables code reads. Calls that
# cannot be answered in a closed world are unsupported, with the Julia API that reaches
# them named in the message (`FOREIGNCALL_HINTS`).

for (name, f, kinds) in (
        # the C library
        (:memrchr, Runtime.ptr_memrchr, [:val, :val, :val]),
        (:strcmp, Runtime.ptr_strcmp, [:val, :val]),
        # CRC-32C (`Base._crc32c`, Pkg's slugs)
        (:jl_crc32c, Runtime.crc32c, [:val, :val, :val]),
        (:jl_crc32c_sw, Runtime.crc32c, [:val, :val, :val]),
        # IdSet (`Base.IdSet`; Base.TOML's parser and printer)
        (:jl_idset_peek_bp, Runtime.IdSets.peek_bp, [:val, :val, :val]),
        (:jl_idset_pop, Runtime.IdSets.pop, [:val, :val, :val]),
        (:jl_idset_put_key, Runtime.IdSets.put_key, [:val, :val, :val]),
        (:jl_idset_put_idx, Runtime.IdSets.put_idx, [:val, :val, :val]),
        # the parser's operators (show of Symbol, Module and Expr, Meta.isoperator)
        (:jl_is_operator, Runtime.Operators.is_operator, [:val]),
        (:jl_is_unary_operator, Runtime.Operators.is_unary_operator, [:val]),
        (:jl_is_unary_and_binary_operator, Runtime.Operators.is_unary_and_binary_operator, [:val]),
        (:jl_is_syntactic_operator, Runtime.Operators.is_syntactic_operator, [:val]),
        (:jl_operator_precedence, Runtime.Operators.operator_precedence, [:val]),
        (:jl_op_suffix_char, Runtime.Operators.op_suffix_char, [:val]),
        # symbols, Libc.rand
        (:jl_gensym, Runtime.gensym, Symbol[]),
        (:jl_tagged_gensym, Runtime.tagged_gensym, [:val, :val]),
        (:jl_rand, Runtime.rand, Symbol[]),
        (:jl_srand, Runtime.srand, [:val]),
        # the GC
        (:jl_enable_gc_logging, Runtime.enable_gc_logging, [:val]),
        (:jl_is_gc_logging_enabled, Runtime.is_gc_logging_enabled, Symbol[]),
        (:jl_gc_enable, Runtime.gc_enable, [:val]),
        # the scheduler's random state (`Base.Partr`): one thread's
        (:jl_get_ptls_rng, Runtime.get_ptls_rng, Symbol[]),
        (:jl_set_ptls_rng, Runtime.set_ptls_rng, [:val]),
        (:jl_gc_new_weakref_th, Runtime.new_weakref, [:val, :val]),
        (:jl_gc_get_total_bytes, Runtime.gc_get_total_bytes, [:val]),
        (:jl_gc_num, Runtime.gc_num, Symbol[]),
        # floating point environment
        (:jl_set_fenv_rounding, Runtime.set_fenv_rounding, [:val]),
        (:jl_set_zero_subnormals, Runtime.set_zero_subnormals, [:val]))
    RUNTIME_CCALLS[name] = RuntimeCcall(f, kinds)
end

"""
The C functions whose result is a constant here (`nothing`: no result), whatever their
arguments: of one thread (in the default pool, as natively with `-t 1`), no signals, no
finalizers that run, WasmGC's heap (no statistics), nothing compiled at run time.
"""
const CONST_FOREIGNCALLS = Dict{Symbol,Any}(
    # threads and the scheduler
    :jl_threadpoolid => 1, :jl_get_task_threadpoolid => 1,
    :jl_in_threaded_region => 0, :jl_cpu_threads => 1, :jl_effective_threads => 1,
    :jl_get_ptls_states => C_NULL, 
    :jl_iolock_begin => nothing, :jl_iolock_end => nothing,
    :jl_task_metrics_enable => nothing, :jl_task_metrics_disable => nothing,
    # signals
    :jl_sigatomic_begin => nothing, :jl_sigatomic_end => nothing,
    :jl_exit_on_sigint => nothing, :jl_install_sigint_handler => nothing,
    :jl_raise_debugger => nothing, :jl_test_failure_breakpoint => nothing,
    # the GC
    :jl_gc_collect => nothing, :jl_gc_live_bytes => 0, :jl_gc_total_hrtime => 0,
    :jl_gc_pool_live_bytes => 0, :jl_gc_diff_total_bytes => 0, :jl_gc_sync_total_bytes => 0,
    :jl_gc_get_max_memory => 0, :jl_gc_set_max_memory => nothing,
    :jl_gc_add_ptr_finalizer => nothing, :jl_gc_add_finalizer => nothing,
    :jl_gc_add_finalizer_th => nothing, :jl_gc_add_quiescent => nothing,
    :jl_gc_enable_finalizers => nothing, :jl_gc_is_in_finalizer => 0,
    :jl_gc_init_finalizer_rng_state => nothing,
    
    :jl_clear_malloc_data => nothing,
    # compilation (none at run time)
    :jl_cumulative_compile_time_ns => 0, :jl_cumulative_recompile_time_ns => 0,
    :jl_cumulative_compile_timing_enable => nothing, :jl_cumulative_compile_timing_disable => nothing,
    :jl_force_trace_compile_timing_enable => nothing, :jl_force_trace_compile_timing_disable => nothing,
    :jl_force_trace_dispatch_enable => nothing, :jl_force_trace_dispatch_disable => nothing,
    :jl_set_precompile_field_replace => nothing, :jl_is_in_pure_context => false,
    # the build and the machine
    :jl_is_debugbuild => 0, :jl_is_assertsbuild => 0, :jl_is_memdebug => 0,
    :jl_running_on_valgrind => 0, :jl_SC_CLK_TCK => 100, :jl_getpagesize => 65536,
    :jl_getallocationgranularity => 65536, :jl_ispty => 0,
    :jl_get_zero_subnormals => 0, :jl_get_fenv_rounding => Base.Rounding.JL_FE_TONEAREST)

"The C runtime's global variables, as the objects of the module that hold their values."
const C_GLOBALS = Dict{Symbol,Any}(
    :jl_gc_have_pending_finalizers => Runtime.PENDING_FINALIZERS,
    :jl_n_threads => Runtime.N_THREADS,
    :jl_n_threadpools => Runtime.N_THREADPOOLS,
    :jl_n_gcthreads => Runtime.N_GCTHREADS)

"""
What reaches a C function that cannot run in a closed world (the Julia API, and why), for
the message of the unsupported call: by a pattern of the function's name.
"""
const FOREIGNCALL_HINTS = Pair{Regex,String}[
    r"^jl_(dlopen|dlclose|dlsym|dllist|load_dynamic_library|pathname_for_handle|lazy_load_and_lookup|load_and_lookup|libdl_dlopen_func)" =>
        "Libdl.dlopen/dlsym: there are no dynamic libraries in Wasm",
    r"^jl_(toplevel_eval|eval_string|load_$|load$|load_file_string|fl_parse|fl_lower|macroexpand|parse|lower|expand|method_def|declare_const|set_const|f_new_module|begin_new_module|end_new_module|module_import|module_using|eval_globalref)" =>
        "Core.eval/include_string/Meta.parse/macroexpand: evaluating or defining code at run time (the module is a closed world)",
    r"^jl_(restore_|read_verify_header|match_cache_flags|cache_flags|generating_output|require_world|object_top_module|base_relative_to|is_file_tracked|write_compiler_output|create_system_image|init_restored_module|add_to_module_init_list)" =>
        "require/using/Base.compilecache at run time: package loading and precompilation",
    r"^jl_(compile_|add_codeinst_to_jit|get_JIT|get_libllvm|get_LLVM_VERSION|jit_total_bytes|dump_|get_llvmf_defn|extern_c|code_for_staged)" =>
        "code_llvm/code_native/precompile/@ccallable: code generation at run time",
    r"^jl_(method_|matching_methods|gf_invoke_lookup|specializations_|methtable_lookup|new_method_|get_specialization1|normalize_to_compilable_sig|isa_compileable_sig|mi_cache_|rettype_inferred|new_codeinst|update_codeinst|fill_codeinst|promote_|invalidate_code_instance|uncompress|compress_|ir_|engine_|call_in_typeinf_world|typeinf_|get_unspecialized|new_opaque_closure)" =>
        "methods/which/code_typed/invokelatest of an unknown function: method tables and inference at run time",
    r"^jl_(get_binding|get_module_binding|bpart_|globalref_is_const|is_const|binding_backedges|maybe_|deprecate_binding|disable_binding|is_binding_deprecated|get_module_of_binding|module_globalref|boundp|get_global|set_global|module_names|module_usings|module_exports_p|module_public_p|module_getloc)" =>
        "names/getglobal/isdefined(::Module, ::Symbol) with a name known only at run time: bindings by name",
    r"^jl_(type_intersection|type_morespecific|type_unionall|has_concrete_subtype|widen_diagonal|new_datatype|new_typename_in|new_primitivetype|new_typevar|instantiate_type|instantiate_unionall|apply_type|apply_tuple_type|apply_array_type|type_union|subtype|intersect_types|has_empty_intersection|find_free_typevars)" =>
        "typeintersect/typejoin/Type{...} construction/<: of types known only at run time: the type system",
    r"^jl_(new_task|switch|set_next_task|get_next_task|wakeup_thread|wakeup_threadpool|queue_work|set_task_tid|set_task_threadpoolid|enter_threaded_region|exit_threaded_region|adopt_thread)" =>
        "@async/@spawn/schedule/Threads.@threads: the program has one task and one thread",
    r"^(jl_spawn|jl_uv_process_|uv_process_kill|uv_kill)" =>
        "run/pipeline/open of a Cmd: processes do not exist in Wasm",
    r"^(jl_tcp_|jl_udp_|jl_sockaddr_|jl_getaddrinfo|jl_getnameinfo|jl_next_from_addrinfo|jl_has_so_reuseport|jl_uv_interface_|uv_tcp_|uv_udp_|uv_pipe|uv_accept|uv_listen)" =>
        "Sockets: there are no sockets in Wasm",
    r"^(jl_mmap|mmap|munmap|msync|madvise|shm_open|shm_unlink)" =>
        "Mmap.mmap: there is no mmap in Wasm",
    r"^(jl_profile_|jl_start_alloc_profile|jl_stop_alloc_profile|jl_fetch_alloc_profile|jl_gc_take_heap_snapshot|jl_gc_take_page_profile)" =>
        "Profile: no sampling or heap snapshots in Wasm",
    r"^(jl_tty_set_mode|jl_termios_size|tcgetattr|tcsetattr|cfmakeraw|posix_openpt|uv_tty_)" =>
        "terminals (REPL, raw mode): there is no terminal in Wasm",
    r"^curl_" => "Downloads (libcurl) is not in Wasm",
    r"^git_|^libssh2_" => "LibGit2 (libgit2) is not in Wasm",
    r"^(mpfr_|__gmpfr_)" => "BigFloat (MPFR) is not in Wasm",
    r"^(__gmpz_|__gmpq_|__gmpn_)" => "BigInt/Rational{BigInt} (GMP) is not in Wasm",
    r"^dsfmt_" => "MersenneTwister (dSFMT) is not in Wasm; Xoshiro (Random.default_rng) is",
    r"^(cholmod_|umfpack_|SuiteSparse|amd_|camd_|colamd_|ccolamd_|spqr_)" =>
        "SparseArrays factorizations (SuiteSparse) are not in Wasm",
    r"^pcre2_" => "Regex (PCRE2) runs on the host's engine with Config(host = :wasi, host_extensions = [:julia_regex])",
]

"The Julia API that reaches the C function `name` and why it cannot run, or \"\"."
function foreigncall_hint(name)
    name isa Symbol || return ""
    s = String(name)
    for (re, hint) in FOREIGNCALL_HINTS
        occursin(re, s) && return " (" * hint * ")"
    end
    return ""
end

## fields by a run-time index (`deepcopy` of a mutable struct, Serialization)

# the statement defining the SSA value `id` in the structured IR `block`, or nothing
function defining_stmt(block, id::Int)
    for inst in IRStructurizer.instructions(block)
        st = inst[:stmt]
        inst.ssa_idx == id && return st
        if st isa IRStructurizer.ControlFlowOp
            for b in IRStructurizer.blocks(st)
                r = defining_stmt(b, id)
                r === nothing || return r
            end
        end
    end
    return nothing
end

"""
The concrete type of the object `x` (the operand `a`), where the compiler knows it: its type,
if concrete, or `T` where `a` is `jl_new_struct_uninit(T)` (as `deepcopy` makes the copy of a
mutable struct before it sets its fields); else `nothing`.
"""
function exact_type(fc::FnCtx, @nospecialize(a), x::CGVal)
    T = x.typ
    T isa DataType && isconcretetype(T) && return T
    a isa Core.SSAValue || return nothing
    st = defining_stmt(fc.sci.entry, a.id)
    (st isa Expr && st.head === :foreigncall && foreigncall_name(st.args[1]) === :jl_new_struct_uninit) ||
        return nothing
    c = operand(fc, st.args[6])
    (c isa CGVal && isconstant(c) && constant_value(c) isa DataType) || return nothing
    return constant_value(c)
end

"""
`jl_set_nth_field(x, i, v)`: the field `i + 1` (0-based `i`, a run-time value) of the mutable
object `x`, of a type the compiler knows (`exact_type`), set to `v` (a chain of tests of the
index; `v` must be of the field's type, as natively). Const fields too, as natively.
"""
function set_nth_field!(fc::FnCtx, ex::Expr, args::Vector{Any})
    x, i, v = args[1]::CGVal, args[2]::CGVal, args[3]::CGVal
    T = exact_type(fc, ex.args[6], x)
    (T !== nothing && ismutabletype(T)) ||
        unsupported("jl_set_nth_field (deepcopy/Serialization) of an object of a type not known at compile time")
    y = convert_repr(fc, x, T)
    idx = convert_repr(fc, i, UInt)
    # out of range: a BoundsError (of the index + 1), as natively
    push_val!(fc, idx); emit!(fc.b, :i64_const, fieldcount(T)); emit!(fc.b, :i64_ge_u)
    if!(fc.b); throw_error!(fc, Runtime.throw_nth_field_bounds, () -> convert_repr(fc, x, Any), idx); end!(fc.b)
    for k in 1:fieldcount(T)
        push_val!(fc, idx); emit!(fc.b, :i64_const, k - 1); emit!(fc.b, :i64_eq)
        if!(fc.b)
        set_field!(fc, y, k, convert_repr(fc, v, fieldtype(T, k)))
        end!(fc.b)
    end
    return ghost(Nothing, nothing)
end

"""
    finish_gensym_counter!(cgm)

The module's gensym counter (`Runtime.GENSYM_COUNTER`, if the image holds it) set, when the
module starts, to the build process's next gensym number now, after the whole compilation:
symbols generated while compiling (by generated functions, during inference) are in the image
too, and the module's gensyms must not repeat them.
"""
function finish_gensym_counter!(cgm::CGModule)
    img = cgm.image
    g = get(img.globals, Runtime.GENSYM_COUNTER, nothing)
    g === nothing && return
    l = layout(img.cgm.types, typeof(Runtime.GENSYM_COUNTER))
    push!(img.patches, (g, :struct, l.wtype, first(l.fields[1]) - 1, Runtime.native_gensym_counter(), UInt32))
    return
end

## modules (`parentmodule`, `PkgId(::Module)`, `moduleloc`)

"""
`jl_module_parent(m)`, `jl_module_uuid(m)` and `jl_module_getloc(m, line)`: modules exist in
the module only as objects of its image, so each is a helper function (`jl_module_<what>`) over
the image's modules, by identity, made when the module is finished (`finish_modules!`): their
parents (added to the image until every module's is in it), UUIDs and definition sites, as
natively.
"""
const MODULE_QUERIES = (:jl_module_parent, :jl_module_uuid, :jl_module_getloc)

function module_query_func!(cgm::CGModule, what::Symbol)
    get!(cgm.helpers, (:module_query, what)) do
        jl = jlvalue_ref(cgm.types)
        results = what === :uuid ? ValType[I64, I64] : what === :line ? ValType[I32] : ValType[jl]
        add_func!(cgm.mod, string("jl_module_", what), ValType[jl], results)
    end
end

function emit_module_query!(fc::FnCtx, name::Symbol, args::Vector{Any}, @nospecialize(typ))
    m = convert_repr(fc, args[1]::CGVal, Module)
    query(what) = (push_val!(fc, convert_repr(fc, m, Any)); call!(fc.b, module_query_func!(fc.cgm, what)))
    if name === :jl_module_parent
        query(:parent)
        return convert_repr(fc, pop_val!(fc, Any), Module)
    elseif name === :jl_module_uuid
        query(:uuid)
        return pop_val!(fc, NTuple{2,UInt64})
    else
        # the line, through the pointer if it is not null (as natively); the file, a Symbol
        p = args[2]::CGVal
        if !(isconstant(p) && constant_value(p) == C_NULL)
            if !isconstant(p)
                push_val!(fc, ptr_address(p)); emit!(fc.b, :i64_eqz); emit!(fc.b, :i32_eqz)
                if!(fc.b)
            end
            query(:line)
            ptr_store!(fc, p, pop_val!(fc, Int32), const_value(fc, 1))
            isconstant(p) || end!(fc.b)
        end
        query(:file)
        return convert_repr(fc, pop_val!(fc, Any), Symbol)
    end
end

function finish_modules!(cgm::CGModule)
    queries = [(k[2], f) for (k, f) in cgm.helpers if k isa Tuple && k[1] === :module_query]
    isempty(queries) && return
    img = cgm.image
    modules() = Module[x for x in keys(img.globals) if x isa Module]
    # every module's parent, and the files of their definitions, in the image
    while true
        ms = modules()
        foreach(m -> object_global!(img, parentmodule(m)), ms)
        any(q -> q[1] === :file, queries) && foreach(m -> object_global!(img, Base.moduleloc(m).file::Symbol), ms)
        length(modules()) == length(ms) && break
    end
    ms = modules()
    for (what, f) in queries
        b = Builder(cgm.mod, f)
        for m in ms
            emit!(b, :local_get, 0)
            emit!(b, :global_get, object_global!(img, m))
            emit!(b, :ref_eq)
            if!(b)
            if what === :parent
                emit!(b, :global_get, object_global!(img, parentmodule(m)))
            elseif what === :uuid
                lo, hi = ccall(:jl_module_uuid, NTuple{2,UInt64}, (Any,), m)
                emit!(b, :i64_const, reinterpret(Int64, lo)); emit!(b, :i64_const, reinterpret(Int64, hi))
            elseif what === :line
                emit!(b, :i32_const, Int32(Base.moduleloc(m).line))
            else
                emit!(b, :global_get, object_global!(img, Base.moduleloc(m).file::Symbol))
            end
            return!(b)
            end!(b)
        end
        # (a module not in the image: none exists at run time)
        unreachable!(b)
        finish!(b)
    end
end
