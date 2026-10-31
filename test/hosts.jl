# The host interfaces (`Config(host = ...)`, src/host.jl): the module's imports for each,
# output (both streams, in order, and more than WASI's buffer holds), entropy and the
# clock, run by the test runner (js/julia.mjs for `:js`, Node's WASI for `:wasi`), and
# WASI modules run by js/julia.mjs's own WASI functions (hosts without WASI).

host_print(n::Int) = (println(Core.stdout, "out ", n); println(Core.stderr, "err ", 2n); print(Core.stdout, 'λ', "\n"); n)
host_big_print(n::Int) = (print(Core.stdout, repeat("ab", n)); n)
host_entropy_time() = (t0 = time_ns(); x = rand(); t1 = time_ns(); (0.0 <= x < 1.0, t1 >= t0))
host_print_fail(n::Int) = (println(Core.stdout, "before ", n); n > 0 && error("boom"); n)
host_order() = (print(Core.stderr, "first"); println(Core.stdout, "second"); print(Core.stdout, "third"); 0)
host_inc(x::Int) = x + 1
host_clock() = time()
# the environment and the clock of a WASI host, and a filesystem without preopened directories
env_clock_text(now::Float64) =
    string("greeting ", get(ENV, "WCG_GREETING", "-"), "; keys ",
           join(sort([k for (k, _) in ENV if startswith(k, "WCG_")]), ","), "; unset ", haskey(ENV, "WCG_UNSET"),
           "; clock ", abs(time() - now) < 60, "; file ", isfile("/wcg/no/such/file"), "\n")
host_env_clock(now::Float64) = (print(Core.stdout, env_clock_text(now)); Int32(0))
# an image object completed by initialization (a cycle), which calls no host function
mutable struct HostNode; next::Any; v::Int; end
const HOST_CYCLE = (n = HostNode(nothing, 7); n.next = n; n)
host_cycle() = (HOST_CYCLE.next::HostNode).v

imported_modules(c) = unique(f.imported[1] for f in c.cgm.mod.funcs if f.imported !== nothing)
imported_names(c) = [f.imported[2] for f in c.cgm.mod.funcs if f.imported !== nothing]
exported_names(c) = [name for (name, _) in c.cgm.mod.exports]

# run `fn(args...)` of the module with js/julia.mjs's `instantiate` (and WASI's environment
# `env`), given the compiled module: (result as a string, output)
function run_julia_mjs(c, fn, args...; env=Dict{String,String}())
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    write(joinpath(dir, "run.mjs"), """
    import { instantiate } from '$(WasmCodegen.JS_HOST)';
    import fs from 'node:fs';
    const out = [];
    const mod = await WebAssembly.compile(fs.readFileSync('$(joinpath(dir, "m.wasm"))'));
    const { instance } = await instantiate(mod, { write: (fd, b) => out.push(...b), env: $(JSON.json(env)) });
    const r = instance.exports.$fn($(join((a isa Int64 ? "$(a)n" : string(a) for a in args), ", ")));
    process.stdout.write(JSON.stringify({ r: String(r), out: new TextDecoder().decode(new Uint8Array(out)) }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String(resp["r"]), String(resp["out"])
end

# the console lines `fn()` writes through js/julia.mjs's default writer, as [stream, line]s
function julia_mjs_console(c, fn)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    write(joinpath(dir, "run.mjs"), """
    import { instantiate } from '$(WasmCodegen.JS_HOST)';
    import fs from 'node:fs';
    const lines = [];
    console.log = (l) => lines.push(['out', l]);
    console.error = (l) => lines.push(['err', l]);
    const { instance, host } = await instantiate(fs.readFileSync('$(joinpath(dir, "m.wasm"))'));
    instance.exports.$fn();
    host.flush();
    process.stdout.write(JSON.stringify(lines));
    """)
    return [Tuple(String.(l)) for l in JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))]
end

# run `fn(args...)` of a WASI module whose `fd_write` writes at most `chunk` bytes a call, or
# fails (`chunk = 0`: errno EIO): (result as a string, output)
function run_partial_writes(c, fn, chunk, args...)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    write(joinpath(dir, "run.mjs"), """
    import fs from 'node:fs';
    let memory, out = [], calls = 0;
    const wasi_snapshot_preview1 = {
      fd_write(fd, iovs, n, nwritten) {
        if (++calls > 100000) throw new Error('fd_write called without end');
        const v = new DataView(memory.buffer);
        if ($chunk === 0) return 29;
        const ptr = v.getUint32(iovs, true), len = Math.min(v.getUint32(iovs + 4, true), $chunk);
        out.push(...new Uint8Array(memory.buffer, ptr, len));
        v.setUint32(nwritten, len, true);
        return 0;
      },
    };
    const { instance } = await WebAssembly.instantiate(fs.readFileSync('$(joinpath(dir, "m.wasm"))'), { wasi_snapshot_preview1 });
    memory = instance.exports.memory;
    instance.exports._initialize?.();
    const r = instance.exports.$fn($(join(("$(a)n" for a in args), ", ")));
    process.stdout.write(JSON.stringify({ r: String(r), out: new TextDecoder().decode(new Uint8Array(out)) }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String(resp["r"]), String(resp["out"])
end

@testset "host interfaces" begin
    for host in (:js, :wasi)
        cfg = WasmCodegen.Config(; host)
        printing = WasmCodegen.compile(host_print, (Int,); config=cfg)
        entropy = WasmCodegen.compile(host_entropy_time, (); config=cfg)
        if host === :js
            @test imported_modules(printing) == ["julia"]
            @test !("memory" in exported_names(printing))
        else
            @test imported_modules(printing) == imported_modules(entropy) == ["wasi_snapshot_preview1"]
            @test "memory" in exported_names(printing)
            # the RNG's seed from the host: initialization once the instance is made
            @test "_initialize" in exported_names(entropy)
        end
        @test wasm_run(printing, "host_print", 3; rettype=Int) == 3
        @test LAST_OUTPUT[] == "out 3\nerr 6\nλ\n"
        big = WasmCodegen.compile(host_big_print, (Int,); config=cfg)
        @test wasm_run(big, "host_big_print", 50_000; rettype=Int) == 50_000
        @test LAST_OUTPUT[] == repeat("ab", 50_000)
        @test wasm_run(entropy, "host_entropy_time"; rettype=Tuple{Bool,Bool}) == (true, true)
        # the time of day (`time()`): the host's, seconds since the epoch
        clock = WasmCodegen.compile(host_clock, (); config=cfg)
        @test imported_names(clock) == (host === :js ? ["clock_now"] : ["clock_time_get"])
        t0 = time(); t = wasm_run(clock, "host_clock"; rettype=Float64); t1 = time()
        @test t0 - 1 <= t <= t1 + 1
        r, _ = run_julia_mjs(clock, "host_clock")
        @test t0 - 1 <= parse(Float64, r) <= time() + 1
        # output written before a trap is not lost
        failing = WasmCodegen.compile(host_print_fail, (Int,); config=cfg)
        @test wasm_run(failing, "host_print_fail", 1; rettype=Int)[1] === :trap
        @test LAST_OUTPUT[] == "before 1\n"
        # initialization that only completes the image (no host call)
        cycle = WasmCodegen.compile(host_cycle, (); config=cfg)
        host === :wasi && @test "_initialize" in exported_names(cycle)
        @test wasm_run(cycle, "host_cycle"; rettype=Int) == 7
        # js/julia.mjs runs either kind (for WASI, its own WASI functions)
        @test run_julia_mjs(printing, "host_print", 4) == ("4", "out 4\nerr 8\nλ\n")
        @test run_julia_mjs(big, "host_big_print", 40_000) == ("40000", repeat("ab", 40_000))
        @test run_julia_mjs(cycle, "host_cycle") == ("7", "")
        # its console writer keeps the order of the two streams
        order = WasmCodegen.compile(host_order, (); config=cfg)
        @test julia_mjs_console(order, "host_order") == [("err", "first"), ("out", "second"), ("out", "third")]
    end
    # js/julia.mjs's WASI: the environment, the clock, and errnos for the filesystem
    envc = WasmCodegen.compile(host_env_clock, (Float64,); config=WasmCodegen.Config(host=:wasi))
    wenv = Dict("WCG_GREETING" => "hello", "WCG_TARGET" => "js")
    native = withenv(() -> env_clock_text(time()),
                     [k => nothing for k in keys(ENV) if startswith(k, "WCG_")]..., wenv...)
    @test native == "greeting hello; keys WCG_GREETING,WCG_TARGET; unset false; clock true; file false\n"
    @test run_julia_mjs(envc, "host_env_clock", time(); env=wenv) == ("0", native)
    # its WASI functions called directly: records, errnos and strings (prints the failed checks)
    @test read(`$(node_cmd()) $(joinpath(@__DIR__, "wasi_host.mjs"))`, String) == ""
    # WASI's fd_write writing part of the bytes (written until all are), or failing (lost)
    big = WasmCodegen.compile(host_big_print, (Int,); config=WasmCodegen.Config(host=:wasi))
    @test run_partial_writes(big, "host_big_print", 3, 10) == ("10", repeat("ab", 10))
    @test run_partial_writes(big, "host_big_print", 4096, 40_000) == ("40000", repeat("ab", 40_000))
    @test run_partial_writes(big, "host_big_print", 0, 10) == ("10", "")
    @test_throws ArgumentError WasmCodegen.compile(host_print, (Int,); config=WasmCodegen.Config(host=:wasm))
    # the names a WASI module exports for itself: entry points of a JavaScript module only
    for name in ("memory", "_initialize")
        js = WasmCodegen.compile([WasmCodegen.Entry(host_inc, (Int,); name)])
        @test wasm_run(js, name, 41; rettype=Int) == 42
        @test run_julia_mjs(js, name, 41) == ("42", "")
        @test_throws ArgumentError WasmCodegen.compile([WasmCodegen.Entry(host_inc, (Int,); name)];
                                                       config=WasmCodegen.Config(host=:wasi))
    end
end
