# The tests, in parallel (ParallelTestRunner): each file in a worker process. A worker opens a
# session of juliac's trim patches once (as juliac builds in one process) and runs its files in
# it; the files that open sessions with other patches run in workers without one.
# `julia test/runtests.jl --help` lists the options (`--jobs=N`, test names to run only those).

using ParallelTestRunner
using WasmCodegen

# programs inferred into a package image; precompiled here, once, before the workers load
# them, and before the patches, which change how Base prints the code it sends to the
# precompiling process
push!(LOAD_PATH, joinpath(@__DIR__, "PrecompiledPrograms"))
using PrecompiledPrograms
pop!(LOAD_PATH)

# the files run in a session of juliac's trim patches
const SESSION_TESTS = [
    "basics", "cfunctions", "data", "random", "dicts", "object_graphs", "globals", "exceptions",
    "coverage", "linalg", "eachindex_trim", "task_fields", "ptrcarry", "regressions", "exprs",
    "ir_cache", "progress", "hosts", "import_libraries", "ptrbytes", "ptrhash", "typeof_any",
    "getfield_any", "invoke_cycle", "reflection_rt", "printing", "runtime", "idset", "unset",
    "image_pointers", "ptrtyped", "ptrviews", "simd128", "vararg_tuples", "split_unions", "versions", "specialize", "invokelatest",
    "staging", "env", "fs", "event", "diagnostics", "type_hash", "foreign_functions",
    "verifier", "juliac/runtests"]
# the files that open sessions with other patches themselves
const OWN_SESSION_TESTS = ["patch_sessions", "tasks"]

# in each worker, once: the harness, the programs and the references of printing.jl (with
# Base's printing: before the patches), in `Main`; the names they define, which each test's
# module imports
const harness_code = quote
    const _BEFORE_HARNESS = Set(names(Main; all=true, imported=true))
    include($(joinpath(@__DIR__, "harness.jl")))
    include($(joinpath(@__DIR__, "juliac", "programs.jl")))
    push!(LOAD_PATH, $(joinpath(@__DIR__, "PrecompiledPrograms")))
    using PrecompiledPrograms
    pop!(LOAD_PATH)
    include($(joinpath(@__DIR__, "printing_fixtures.jl")))
    const HARNESS_NAMES = Symbol[n for n in names(Main; all=true, imported=true)
                                 if !(n in _BEFORE_HARNESS) && !startswith(string(n), '#')]
end
# and then the session of juliac's trim patches, open for the worker's life: a task waits in
# it, and the files' sessions (and `compile`'s) are that one (same patches: no new session)
const init_worker_code = quote
    $harness_code
    const _SESSION_OPEN = Base.Event()
    const _SESSION = @async try
        WasmCodegen.with_trim_patches() do _, _
            notify(_SESSION_OPEN)
            wait(Base.Event())
        end
    finally
        notify(_SESSION_OPEN)   # (also if the session failed to open: its error, below)
    end
    wait(_SESSION_OPEN)
    istaskfailed(_SESSION) && fetch(_SESSION)
end
# the files that open sessions with other patches: in a worker of their own, without the session
test_worker(test, _) =
    test in OWN_SESSION_TESTS ? ParallelTestRunner.addworker(; init_worker_code=harness_code) : nothing
const init_code = quote
    # (the harness's `using`s: their exported names are not bindings of `Main`)
    using WasmCodegen, WasmBuilder, Base64, SHA
    for n in Main.HARNESS_NAMES
        isdefined(@__MODULE__, n) && continue
        Core.eval(@__MODULE__, Expr(:using, Expr(:(:), Expr(:., :Main), Expr(:., n))))
    end
end

testsuite = Dict{String,Expr}()
for t in SESSION_TESTS
    file = joinpath(@__DIR__, t * ".jl")
    testsuite[t] = :(WasmCodegen.with_trim_patches() do _, _
                         include($file)
                     end)
end
for t in OWN_SESSION_TESTS
    testsuite[t] = :(include($(joinpath(@__DIR__, t * ".jl"))))
end

args = parse_args(ARGS)
filter_tests!(testsuite, args)
runtests(WasmCodegen, args; testsuite, init_worker_code, init_code, test_worker)
