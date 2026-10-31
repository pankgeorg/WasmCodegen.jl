# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`, `runtime/tasks.jl`, the `julia_task`
# imports of `js/julia_task.mjs`): `tasks_program.jl` compiled and run on Node through
# `tasks.mjs`. `main`'s stdout is compared with native Julia's; the Wasm-only exports check
# waits on the host's handles and the host's lifecycle. (Outside the session of patches of
# `runtests.jl`: the task patches make a session of their own.)

module TasksTests

using Test
import JSON
using ..Main: node_cmd, jspi_flags, WasmCodegen
using WasmCodegen: Entry

include("tasks_program.jl")
const P = TasksProgram

@testset "tasks on JSPI stacks" begin
    # the native output, with Base's scheduler, in a process of its own (one thread)
    prog = joinpath(@__DIR__, "tasks_program.jl")
    native = read(addenv(`$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$(Base.active_project())
                          -e "include($(repr(prog))); TasksProgram.main()"`, "JULIA_NUM_THREADS" => "1"), String)
    @test endswith(native, "\ndone\n")
    fns = [P.main_safe => (), P.pingpong => (Int32,), P.pingpong_busy => (Int32,),
           P.pingpong_channel => (Int32,), P.shared_handle => (), P.dead_handle => (Int32,),
           P.http_shared => (Int32,), P.early_return => (), P.deadlock_child => (),
           P.deadlock_root => (), P.child_trap => (Int32,), P.root_trap => (Int32,),
           P.stress => (Int32, Int32), P.task_stats => (), P.downloads => (Int32, Int32, Int32),
           P.lone_yield => (Int32,), P.discarded => (Int32,)]
    c = WasmCodegen.compile([Entry(f, T; name=string(nameof(f))) for (f, T) in fns];
                            config=WasmCodegen.Config(host=:wasi, host_extensions=[:julia_io], tasks=:jspi,
                                                      verify=:error))
    @test isempty(c.cgm.diagnostics)
    wasm = joinpath(mktempdir(), "tasks.wasm")
    write(wasm, c.bytes)
    calls = [Dict("fn" => "main_safe"),
             Dict("fn" => "pingpong", "args" => [10000], "jsTimer" => true),
             Dict("fn" => "pingpong_busy", "args" => [10000], "jsTimer" => true),
             Dict("fn" => "pingpong_channel", "args" => [10000]),
             Dict("fn" => "shared_handle"), Dict("fn" => "dead_handle", "args" => ["\$PORT"]),
             Dict("fn" => "http_shared", "args" => ["\$PORT"]),
             Dict("fn" => "early_return"), Dict("fn" => "task_stats", "fresh" => false),
             Dict("fn" => "deadlock_child"), Dict("fn" => "deadlock_root"),
             Dict("fn" => "stress", "args" => [10, 100]), Dict("fn" => "task_stats", "fresh" => false),
             Dict("fn" => "stress", "args" => [1, 1000]),
             Dict("fn" => "child_trap", "args" => [10_000_000], "expectTrap" => true),
             Dict("fn" => "task_stats", "fresh" => false, "expectTrap" => true),
             Dict("fn" => "root_trap", "args" => [10_000_000], "expectTrap" => true),
             Dict("fn" => "downloads", "args" => ["\$PORT", 8, 1]),
             Dict("fn" => "downloads", "args" => ["\$PORT", 8, 4]),
             Dict("fn" => "lone_yield", "args" => ["\$PORT"]),
             Dict("fn" => "discarded", "args" => [70000]),
             Dict("fn" => "pingpong_busy", "args" => [10_000_000], "shutdownAfter" => 20, "expectTrap" => true)]
    out = IOBuffer(); err = IOBuffer()
    cmd = `$(node_cmd()) --disable-warning=ExperimentalWarning $(jspi_flags()) $(joinpath(@__DIR__, "tasks.mjs")) $wasm $(JSON.json(calls))`
    proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    errs = String(take!(err))
    @test proc.exitcode == 0
    proc.exitcode == 0 || @info "tasks.mjs stderr" errs
    lines = split(errs, '\n'; keepempty=false)
    rs = [JSON.parse(l[4:end]) for l in lines if startswith(l, "@@ {\"fn\"")]
    downs = [JSON.parse(l[4:end])["shutdown"] for l in lines if startswith(l, "@@ {\"shutdown\"")]
    stdout_wasm = String(take!(out))
    @test length(rs) == length(calls)
    res(i) = (r = rs[i]; haskey(r, "trap") ? error("$(r["fn"]) trapped: $(r["trap"])") : r["result"])
    num(i) = (v = res(i); v isa AbstractString ? parse(Int64, v) : Int64(v))
    # `main`: the same stdout as natively; errormonitor's first line on stderr
    @test res(1) == 0
    @test stdout_wasm[1:something(findfirst("\ndone\n", stdout_wasm), 0:-1)[end]] == native
    @test any(==("UNHANDLED TASK ERROR: monitored"), lines)
    @test rs[1]["host"]["parked"] == 0 && rs[1]["open"] == 0
    # switches are microtasks without host work (a JavaScript timer does not run meanwhile);
    # macrotasks while a timer is open (the JavaScript timer runs)
    @test num(2) > 0 && rs[2]["host"]["handoffs"] == 0
    @test num(3) > 0 && rs[3]["host"]["handoffs"] >= 20000 && rs[3]["jsTimerFired"] === true
    @test num(4) > 0
    # several waiters for one handle, one interrupted; a handle nothing can make ready
    # (EINVAL); two waiters for one HTTP request, one reading it to its end
    @test res(5) == 0 && occursin("shared 6 interrupted\n", stdout_wasm)
    @test num(6) == 28 && occursin("dead handle 28 slept\n", stdout_wasm)
    @test num(7) == 3 && occursin("http shared 3 true\n", stdout_wasm)
    # a root call that returns with a task parked; the next one runs; the host drops it
    @test res(8) == 0 && rs[8]["host"]["parked"] == 1
    @test num(9) & 0xffffffff == 1
    @test downs[8] == Dict("parked" => 1, "live" => 1)
    # deadlocks are thrown (natively: a hang)
    @test num(10) == 1 && num(11) == 1
    # task ids are reused; 1000 tasks alive at once
    @test num(12) == 10 * 5050 && num(13) & 0xffffffff == 0
    @test num(14) == 500500 && rs[14]["host"]["maxLive"] == 1000
    # a trap in a task or in the root fails the root call; the instance is then unusable
    @test occursin("call stack", rs[15]["trap"]) && rs[15]["terminal"]
    @test occursin("terminal", rs[16]["trap"])
    @test occursin("call stack", rs[17]["trap"]) && rs[17]["terminal"]
    # 8 downloads of 100 ms each: serially, and with 4 tasks (overlapping)
    @test num(18) >= 800_000 && num(19) > 0 && num(19) < num(18) ÷ 2
    # the only task yields with a request in flight and no handle waited for: it completes
    @test num(20) == 200
    # 70000 Tasks created and never run: they hold no task id
    @test num(21) == 7 << 32
    # the host shut down during a root call: the call fails
    @test occursin("shut down", rs[22]["trap"]) && rs[22]["terminal"]
end

@testset "Config(tasks)" begin
    # without tasks, a module imports and exports nothing of them
    c = WasmCodegen.compile([Entry(+, (Int, Int))])
    @test !occursin("julia_task", String(copy(c.bytes))) && !occursin("jl_task_entry", String(copy(c.bytes)))
    @test_throws ArgumentError WasmCodegen.compile([Entry(+, (Int, Int))]; config=WasmCodegen.Config(tasks=:jspi))
    @test_throws ArgumentError WasmCodegen.compile([Entry(+, (Int, Int))]; config=WasmCodegen.Config(tasks=:threads))
end

end # TasksTests
