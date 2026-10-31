include("harness.jl")
include("juliac/programs.jl")
# programs inferred into a package image; precompiled before the patches, which change how
# Base prints the code it sends to the precompiling process
push!(LOAD_PATH, joinpath(@__DIR__, "PrecompiledPrograms"))
using PrecompiledPrograms
pop!(LOAD_PATH)

# one session of juliac's trim patches for all the tests (as juliac builds in one process)
WasmCodegen.with_trim_patches() do _, _
    include("basics.jl")
    include("data.jl")
    include("random.jl")
    include("dicts.jl")
    include("globals.jl")
    include("exceptions.jl")
    include("coverage.jl")
    include("linalg.jl")
    include("eachindex_trim.jl")
    include("task_fields.jl")
    include("ptrcarry.jl")
    include("regressions.jl")
    include("ir_cache.jl")
    include("hosts.jl")
    include("ptrbytes.jl")
    include("typeof_any.jl")
    include("invoke_cycle.jl")
    include("reflection_rt.jl")
    include("runtime.jl")
    include("idset.jl")
    include("unset.jl")
    include("image_pointers.jl")
    include("vararg_tuples.jl")
    include("versions.jl")
    include("juliac/runtests.jl")
end

# sessions with project patches, outside the session above
include("patch_sessions.jl")
