# WasmCodegen modules on Cloudflare's workerd

A Worker (`worker.mjs`) that runs three modules in [workerd](https://github.com/cloudflare/workerd),
the runtime of Cloudflare Workers, locally:

- `/lorenz`: `examples/lorenz`'s module (`host = :js`), an OrdinaryDiffEq `Tsit5` solve;
- `/tasks`: the test suite's program of Julia Tasks (`test/tasks_program.jl`'s `main_safe`,
  `Config(host = :wasi, host_extensions = [:julia_io], tasks = :jspi)`): tasks on JSPI
  stacks, timers, channels, conditions, exceptions in tasks;
- `/env`: a WASI program (`programs.jl`) that reads its environment and the clock.

`check.mjs` serves the Worker and compares each response with the same module on Node
(Lorenz) or with native Julia's output (the others). It needs no network once installed:

```sh
julia +1.13 --project=../lorenz ../lorenz/build.jl    # lorenz.wasm
julia +1.13 --project=. build.jl                       # tasks.wasm, env.wasm, expected/
npm ci                                                 # workerd, pinned
node check.mjs
```

```text
ok   /lorenz: matches Node (1 lines)
ok   /tasks: matches native Julia (45 lines)
ok   /env: matches native Julia (6 lines)
```

It is not run by CI, which would download workerd.

## What a Worker needs

- **Modules compiled ahead of time.** A Worker cannot compile Wasm while it handles a
  request (`WebAssembly.compile` of bytes fails with "Wasm code generation disallowed by
  embedder"). Configure each `.wasm` as a module (`wasm = embed "..."` in workerd's
  configuration; in Wrangler, `import m from './m.wasm'` with the default `CompiledWasm` rule):
  it is imported as a `WebAssembly.Module`, which `instantiate` of `js/julia.mjs` and
  `WebAssembly.instantiate` take.
- **WASI from `js/julia.mjs`.** workerd's `node:wasi` throws on construction. `createHost()`'s
  `wasi_snapshot_preview1` imports give a `host = :wasi` module its arguments and
  environment (`createHost({ env, args })`), the clocks, randomness and stdout/stderr. It
  exposes no filesystem (workerd's own `/tmp` and `/bundle` included): no directory is
  preopened, stdin is empty, and file operations fail as for a path out of the preopens
  (`isfile` is false, `open` throws a `SystemError`).
- **`nodejs_compat`** for `js/julia_io.mjs` (its `node:` imports) and `js/julia_task.mjs`
  (`setImmediate`): the default from the compatibility date 2026-08-04 on, else
  `compatibilityFlags = ["nodejs_compat"]` (`compatibility_flags` in `wrangler.toml`).
  `julia_io`'s HTTP requests and decompression are not tested here (`network: false`).
- **JSPI** (`WebAssembly.Suspending`, `WebAssembly.promising`) is on in workerd: Tasks and
  `sleep` need no flag.
- **`wasm:js-string`**: WasmCodegen's modules do not import JS string builtins or string
  constants. A module that does needs the compatibility flag `wasm_esm_integration_builtins`
  (`compatibilityFlags = ["wasm_esm_integration_builtins"]`, or
  `compatibility_flags = ["wasm_esm_integration_builtins"]` in `wrangler.toml`).

## Limits on Cloudflare

Local workerd enforces none of these; deployed Workers do
([limits](https://developers.cloudflare.com/workers/platform/limits/)):

- **Memory:** 128 MB per isolate, JavaScript and Wasm together (linear memory, GC heap,
  compiled code, JSPI stacks), shared by the requests the isolate serves at once.
- **CPU time:** 10 ms per request on the Free plan; 30 s by default on Paid, configurable
  up to 5 min.
- **Size and startup:** 64 MiB uncompressed bundle; 1 s of startup.
- **Clocks:** a Worker's clocks advance only between I/O operations: `time()` and
  `time_ns()` do not advance during a computation without I/O.
