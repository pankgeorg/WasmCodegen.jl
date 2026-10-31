# Build the modules of the Worker and the native outputs they are compared with:
#   julia +1.13 --project=. build.jl
# (lorenz.wasm is examples/lorenz's: julia +1.13 --project=../lorenz ../lorenz/build.jl)
using WasmCodegen
using WasmCodegen: Entry, Config
include("programs.jl")
const TASKS_PROGRAM = normpath(joinpath(@__DIR__, "..", "..", "test", "tasks_program.jl"))
include(TASKS_PROGRAM)

# the environment worker.mjs gives the WASI program
const WORKER_ENV = ["WCG_GREETING" => "hello", "WCG_TARGET" => "workerd"]
mkpath(joinpath(@__DIR__, "expected"))

env = WasmCodegen.compile(env_clock, (Float64,); config=Config(host=:wasi))
write(joinpath(@__DIR__, "env.wasm"), env.bytes)
# (natively, only those of the variables the program reads)
write(joinpath(@__DIR__, "expected", "env.txt"),
      withenv(() -> env_clock_text(time()), [k => nothing for k in keys(ENV) if startswith(k, ENV_PREFIX)]...,
              WORKER_ENV...))

# the test suite's program of Julia Tasks: timers, channels, conditions, exceptions in tasks
tasks = WasmCodegen.compile([Entry(TasksProgram.main_safe, (); name="main_safe")];
                            config=Config(host=:wasi, host_extensions=[:julia_io], tasks=:jspi))
write(joinpath(@__DIR__, "tasks.wasm"), tasks.bytes)
native = read(addenv(`$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$(Base.active_project())
                      -e "include($(repr(TASKS_PROGRAM))); TasksProgram.main()"`, "JULIA_NUM_THREADS" => "1"), String)
write(joinpath(@__DIR__, "expected", "tasks.txt"), native)

for f in ("env.wasm", "tasks.wasm")
    println(f, ": ", filesize(joinpath(@__DIR__, f)), " bytes")
end
