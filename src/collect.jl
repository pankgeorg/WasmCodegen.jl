# Collecting the closed world of code an entry point can run, as juliac does
# (`Compiler.typeinf_ext_toplevel`): a compilation queue drained by `CC.compile!` under
# the Wasm interpreter, which yields the (CodeInstance, CodeInfo) pairs of every function
# to compile.

"""
    ClosedWorld

The functions to compile: for every method instance, its CodeInstance and its optimized
source, in the order they were collected, and the entry points.
"""
struct ClosedWorld
    world::UInt
    entries::Vector{Core.MethodInstance}
    order::Vector{Core.MethodInstance}
    sources::IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}
    "What the trim verifier reported (empty if verification was off or clean)."
    trim_report::Base.RefValue{String}
end

"""
    entry_instance(f, argtypes; world) -> MethodInstance

The method instance a call of `f` with arguments of types `argtypes` dispatches to.
"""
function entry_instance(@nospecialize(f), @nospecialize(argtypes::Tuple);
                        world::UInt=Base.get_world_counter())
    tt = Tuple{Core.Typeof(f),argtypes...}
    matches = CC.findall(tt, CC.InternalMethodTable(world); limit=1)
    (matches === nothing || length(matches) != 1) &&
        error("no unique method for $tt")
    match = CC.getindex(matches, 1)::Core.MethodMatch
    return CC.specialize_method(match)
end

# `CC.compile!` takes whether code may link against code in images from Julia 1.13 on:
# the closed world does not
const COMPILE_KWARGS = VERSION >= v"1.13-" ? (; external_linkage=false) : (;)

"""
    collect_world(entries; world, verify=:warn) -> ClosedWorld

Infer the entry method instances and everything they call, as juliac does. Calls kept
as `:invoke`s of method instances inference did not keep source for (error paths) are
inferred too, to a fixpoint. With `verify` (`:error`, `:warn` or `:off`), the result is
checked with juliac's trim verifier, which reports dynamic dispatch.
"""
function collect_world(entries::Vector{Core.MethodInstance};
                       world::UInt=Base.get_world_counter(), verify::Symbol=:warn)
    w = ClosedWorld(world, entries, Core.MethodInstance[],
                    IdDict{Core.MethodInstance,Tuple{Core.CodeInstance,Core.CodeInfo}}(),
                    Ref(""))
    verify === :off || (w.trim_report[] = trim_check(entries; world, onlywarn=verify === :warn))
    extend_world!(w, entries)
    return w
end

"""
    TrimFailure

The entry points are not trim-safe: juliac's verifier found dynamic dispatch (or other
constructs that need the Julia runtime) in the code they run.
"""
struct TrimFailure <: Exception
    report::String
end
Base.showerror(io::IO, e::TrimFailure) =
    print(io, "the code of the entry points is not trim-safe (as juliac --trim=safe checks):\n", e.report)

# the rounds of inferring invoke targets as entries in `trim_check`
const MAX_INVOKE_ROUNDS = 8

"""
    trim_check(entries; world, onlywarn=false) -> String

Check the entry points as `juliac --trim=safe` does: native inference collects the code
they run (`Compiler.typeinf_ext_toplevel`), and juliac's verifier checks it. Returns the
verifier's report, and throws a [`TrimFailure`](@ref) if it found errors (unless
`onlywarn`). This is the subset of Julia the code generator targets.

An `:invoke` of a method instance without a code instance (one inferred only as part of a
recursion cycle, or whose cached code the patches invalidated) is a static call, which the
code generator compiles, but the verifier rejects it as unresolved: native inference does
not compile its target. Each such target is inferred as an entry of its own, and the invoke
made of its code instance; the verifier checks that code as any other. (For a few rounds: the
targets of a program whose specializations do not end, as recursive invokes of ever deeper
types, stay unresolved invokes.)
"""
function trim_check(entries::Vector{Core.MethodInstance}; world::UInt=Base.get_world_counter(),
                    onlywarn::Bool=false)
    args = VERSION >= v"1.13-" ? (CC.TRIM_UNSAFE, false) : (CC.TRIM_UNSAFE,)
    roots = Any[entries...]
    codeinfos = CC.typeinf_ext_toplevel(copy(roots), UInt[world], args...)
    for _ in 1:MAX_INVOKE_ROUNDS
        targets = filter(mi -> !(mi in roots), uncompiled_invoke_targets(codeinfos))
        isempty(targets) && break
        append!(roots, targets)
        codeinfos = CC.typeinf_ext_toplevel(copy(roots), UInt[world], args...)
    end
    link_invoke_targets!(codeinfos)
    io = IOBuffer()
    try
        redirect_stdout(devnull) do
            verify_trim(io, codeinfos, entries, onlywarn)
        end
    catch err
        err isa Core.TrimFailure || rethrow()
        throw(TrimFailure(String(take!(io))))
    end
    return String(take!(io))
end

# the code instances of `codeinfos` the verifier links invokes to, by method instance: native
# ones valid in the current world, of the instance itself (`get_verify_typeinf_trim`'s)
function linkable_code(codeinfos::Vector{Any})
    now = Base.get_world_counter()
    code = IdDict{Core.MethodInstance,Core.CodeInstance}()
    for item in codeinfos
        item isa Core.CodeInstance && item.owner === nothing && item.min_world <= now <= item.max_world &&
            CC.get_ci_mi(item) === item.def && (code[item.def] = item)
    end
    return code
end

# the statement's invoke target when it is a bare method instance (else nothing)
function invoked_instance(@nospecialize(st))
    ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
    Meta.isexpr(ex, :invoke) && ex.args[1] isa Core.MethodInstance || return nothing
    return ex.args[1]::Core.MethodInstance
end

# the method instances `codeinfos` invoke without a code instance of them in `codeinfos`
function uncompiled_invoke_targets(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    targets = Core.MethodInstance[]
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        for st in (codeinfos[i + 1]::Core.CodeInfo).code
            mi = invoked_instance(st)
            mi === nothing || haskey(code, mi) || mi in targets || push!(targets, mi)
        end
    end
    return targets
end

# the invokes of a bare method instance with a code instance in `codeinfos`, of that code
# instance (in copies of the sources: they are inference's)
function link_invoke_targets!(codeinfos::Vector{Any})
    code = linkable_code(codeinfos)
    for i in 1:length(codeinfos)
        codeinfos[i] isa Core.CodeInstance || continue
        src = codeinfos[i + 1]::Core.CodeInfo
        any(st -> (mi = invoked_instance(st); mi !== nothing && haskey(code, mi)), src.code) || continue
        src = copy(src)
        src.code = copy(src.code)
        for j in eachindex(src.code)
            st = src.code[j]
            mi = invoked_instance(st)
            (mi !== nothing && haskey(code, mi)) || continue
            ex = Meta.isexpr(st, :(=)) ? st.args[2] : st
            linked = Expr(:invoke, code[mi], ex.args[2:end]...)
            src.code[j] = Meta.isexpr(st, :(=)) ? Expr(:(=), st.args[1], linked) : linked
        end
        codeinfos[i + 1] = src
    end
    return codeinfos
end

# whether `mi` is a method of a runtime twin (`Runtime.WASM_IMPLS`), whose calls the code
# generator replaces by calls of its Wasm implementation (`overlays.jl`)
function twin_instance(mi::Core.MethodInstance)
    # (`Runtime.map_type_value`: compiled to a table of its function, which runs natively)
    m = mi.def
    m isa Method && m.module === Runtime && m.name === :map_type_value && return true
    F = mi.specTypes isa DataType ? mi.specTypes.parameters[1] : nothing
    return F isa DataType && Base.issingletontype(F) && haskey(Runtime.WASM_IMPLS, F.instance)
end

# whether `mi` is a twin's native body or `Twins.original` (or its keyword body), which only
# those call
function twin_body(mi::Core.MethodInstance)
    m = mi.def
    m isa Method && m.module === Runtime.Twins &&
        (m.name === :original || startswith(String(m.name), "#original#")) && return true
    return twin_instance(mi)
end

"""
    compiled_instances(codeinfos, entries) -> (compiled, native_only)

The method instances of `codeinfos` (native inference's) that the module compiles: those the
entries reach through `:invoke`s, not entering the calls of runtime twins, which the code
generator replaces; and those reached only through twins' native bodies (`native_only`).
"""
function compiled_instances(codeinfos::Vector{Any}, entries::Vector{Core.MethodInstance})
    src = IdDict{Core.MethodInstance,Core.CodeInfo}()
    for i in 1:length(codeinfos)
        item = codeinfos[i]
        item isa Core.CodeInstance && (src[CC.get_ci_mi(item)] = codeinfos[i + 1]::Core.CodeInfo)
    end
    # the instances reached from `roots`, not entering twins (whose callees are `twins`)
    function reach(roots, twins)
        reached = IdSet{Core.MethodInstance}()
        work = Core.MethodInstance[roots...]
        while !isempty(work)
            mi = pop!(work)
            mi in reached && continue
            push!(reached, mi)
            ci = get(src, mi, nothing)
            ci === nothing && continue
            for st in ci.code
                Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify) || continue
                t = st.args[1]
                callee = t isa Core.CodeInstance ? CC.get_ci_mi(t) : t
                callee isa Core.MethodInstance || continue
                twin_instance(callee) ? push!(twins, callee) : push!(work, callee)
            end
        end
        return reached
    end
    twins = Core.MethodInstance[]
    compiled = reach(entries, twins)
    # (from the twins' native bodies, which call more twins in turn)
    native = reach(twins, Core.MethodInstance[])
    return compiled, IdSet{Core.MethodInstance}(mi for mi in native if !(mi in compiled))
end

"""
    verify_trim(io, codeinfos, entries, onlywarn)

juliac's verifier (`Compiler.verify_typeinf_trim`), without the errors in the native bodies
of the runtime's twins, and in the code only they reach, that the module does not compile: in Wasm, the code generator calls
each twin's Wasm implementation instead (`overlays.jl`). (Natively, those bodies call the
method before the patches with `invoke_in_world`, which the verifier rejects.) A twin body
reached otherwise (an entry, a direct call of `Twins.original`) is still verified.
"""
function verify_trim(io::IO, codeinfos::Vector{Any}, entries::Vector{Core.MethodInstance}, onlywarn::Bool)
    TV = CC.TrimVerifier
    errors, parents = TV.get_verify_typeinf_trim(codeinfos)
    compiled, native_only = compiled_instances(codeinfos, entries)
    filter!(errors) do e
        d = e.second
        d isa TV.CallMissing || return true
        mi = CC.get_ci_mi(d.codeinst)
        return !(mi in native_only || (twin_body(mi) && !(mi in compiled)))
    end
    # (the rest as `verify_typeinf_trim`)
    counts = [0, 0]
    io = IOContext{IO}(io)
    for (warn, desc) in errors
        severity = warn ? 2 : 1
        no = (counts[severity] += 1)
        printstyled(io, "Error #", no, ": "; color=Base.error_color(), bold=true)
        # (Julia 1.12's has no `warn`)
        VERSION >= v"1.13-" ? TV.verify_print_error(io, desc, parents, warn) :
                              TV.verify_print_error(io, desc, parents)
    end
    if counts[1] > 0 || counts[2] > 0
        print(io, "Trim verify finished with ")
        if counts[1] > 0
            printstyled(io, counts[1], counts[1] == 1 ? " error" : " errors"; color=Base.error_color(), bold=true)
        else
            print(io, counts[1], counts[1] == 1 ? " error" : " errors")
        end
        print(io, ", ")
        if counts[2] > 0
            printstyled(io, counts[2], counts[2] == 1 ? " warning" : " warnings"; color=Base.warn_color(), bold=true)
        else
            print(io, counts[2], counts[2] == 1 ? " warning" : " warnings")
        end
        print(io, ".\n")
        counts[1] > 0 && !onlywarn && throw(Core.TrimFailure())
    end
    return nothing
end

"""
    extend_world!(w, mis) -> ClosedWorld

Add the method instances `mis` and everything they call to the closed world `w` (the
code generator asks for the functions of its runtime this way).
"""
function extend_world!(w::ClosedWorld, mis::Vector{Core.MethodInstance})
    interp = WasmInterpreter(; world=w.world)
    codeinfos = Any[]
    wq = CC.CompilationQueue(; interp)
    ilq = CC.CompilationQueue(; interp)
    initial = [mi for mi in mis if !haskey(w.sources, mi)]
    append!(wq, initial)
    # Each method instance is asked for once: one that comes back without a source would
    # otherwise be missing, and asked for, again on every round, without end. Each round scans
    # only the functions it added. A target left without a source is not in the world: a call
    # to it that survives to emission is an unsupported construct there (get_function!).
    requested = Base.IdSet{Core.MethodInstance}(initial)
    scanned = length(w.order)
    trace = get(ENV, "WCG_COLLECT_TRACE", "") == "1"
    nround = 0
    t0 = time()
    while true
        nround += 1
        CC.compile!(codeinfos, wq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        CC.compile!(codeinfos, ilq; invokelatest_queue=ilq, COMPILE_KWARGS...)
        for i in 1:2:length(codeinfos)
            ci, src = codeinfos[i], codeinfos[i+1]
            (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
            mi = CC.get_ci_mi(ci)
            haskey(w.sources, mi) && continue
            w.sources[mi] = (ci, src)
            push!(w.order, mi)
        end
        # the targets of `:invoke`s in the functions this round added that are not in the
        # world yet and were not asked for before
        missing = Core.MethodInstance[]
        for k in scanned+1:length(w.order), stmt in w.sources[w.order[k]][2].code
            Meta.isexpr(stmt, :invoke) || continue
            target = stmt.args[1]
            tmi = target isa Core.CodeInstance ? CC.get_ci_mi(target) : target
            tmi isa Core.MethodInstance || continue
            haskey(w.sources, tmi) || tmi in requested || (push!(requested, tmi); push!(missing, tmi))
        end
        trace && println(stderr, "extend_world! round ", nround, ": world ", length(w.order), " (+",
                         length(w.order) - scanned, "), new :invoke targets ", length(missing), ", ",
                         round(time() - t0; digits = 1), " s")
        trace && flush(stderr)
        scanned = length(w.order)
        isempty(missing) && break
        empty!(codeinfos)
        append!(wq, missing)
    end
    # asked for, but inference kept no source for them
    unresolved = [mi for mi in requested if !haskey(w.sources, mi)]
    if trace && !isempty(unresolved)
        println(stderr, "extend_world!: ", length(unresolved), " :invoke targets without a source, e.g. ",
                join((sprint(show, mi; context = :limit => true) for mi in first(unresolved, 5)), "; "))
        flush(stderr)
    end
    return w
end
