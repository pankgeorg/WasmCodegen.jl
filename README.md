# WasmCodegen.jl

[![CI](https://github.com/gbaraldi/WasmCodegen.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/gbaraldi/WasmCodegen.jl/actions/workflows/CI.yml)

A compiler from Julia to WebAssembly with garbage collection (WasmGC), working like
`juliac --trim`. From entry points, it collects the closed world of code they can run,
using Julia's own inference. It compiles that code to a Wasm module and serializes the
Julia objects the code refers to into the module. A program can build its data natively at
compile time (an `ODEProblem`, an integrator after `init`, a lookup table), and the module
starts with that data instead of the code that built it.

No Julia runtime is linked. WasmGC provides allocation and garbage collection, and
generated code handles object layout and type tags. What libjulia's C code does
otherwise (IO, 128-bit arithmetic, `memmove`, Unicode tables, `strtod`, hashes, random
seeds, BLAS and LAPACK) is a small runtime written in Julia and compiled into the module on
demand, over a few host imports (from JavaScript, or WASI).

**Status: experimental.** The supported subset is what `juliac --trim=safe` accepts: no
dynamic dispatch. Julia 1.13 is the main target, and 1.12 also works. Programs that run
today include OrdinaryDiffEq's `Tsit5` on an `ODEProblem` built at compile time, its implicit
`Rodas5P` on a stiff PDE with LinearSolve's solvers for its linear systems, a
ModelingToolkit model, JuliaSyntax (Julia's parser), Random (bit-identical streams),
dictionaries, exceptions (`try`/`catch`/`finally`, with Wasm's exception handling),
LinearAlgebra (BLAS and LAPACK in the runtime), LinearSolve's pure-Julia solvers (its
default algorithm, the blocked `GenericLUFactorization`, `SimpleLUFactorization`, PureKLU on
sparse matrices, Krylov.jl's and its own GMRES), printing to `stdout` (`show` of arrays and
tuples too), and the programs of JuliaC.jl's tests (dispatch over concrete types,
reductions, sorting, concatenation).

## Example

```julia
using WasmCodegen

function f(n::Int)
    v = [sin(i * 0.1) for i in 1:n]
    println(Core.stdout, "sum = ", sum(v))
    return maximum(v)
end

c = WasmCodegen.compile(f, (Int,))           # or compile([(f, (Int,)), (g, (Float64,))])
write("f.wasm", c.bytes)
```

```js
// node --experimental-wasm-exnref run.mjs, with js/julia.mjs copied next to it
import fs from 'node:fs';
import { instantiate } from './julia.mjs';
const { instance } = await instantiate(fs.readFileSync('f.wasm'));   // output to the console
console.log(instance.exports.f(100n));      // Int is an i64: a BigInt
```

The module imports what it needs of the host (output, a random seed, a clock), in one of
two interfaces, `Config(host = ...)`:

- `:js` (the default): a few functions of the import module `julia`, which
  [`js/julia.mjs`](js/julia.mjs) provides (its `instantiate`, or `createHost` for the
  imports alone). `WasmCodegen.JS_HOST` is its path, to copy next to a module.
- `:wasi`: [WASI preview 1](https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md)
  (`fd_write`, `random_get`, `clock_time_get`), for WASI runtimes, as other languages
  compiling to Wasm do (Go's `wasip1`, Kotlin's `wasmWasi`). The module exports its
  `memory` (a page, for the data of WASI calls) and runs its initialization from
  `_initialize`, as a WASI reactor; `js/julia.mjs` runs these too, where JavaScript has
  no WASI (browsers). In Node, with `node:wasi`:

```js
import { WASI } from 'node:wasi';
const wasi = new WASI({ version: 'preview1' });
const { instance } = await WebAssembly.instantiate(await WebAssembly.compile(bytes), wasi.getImportObject());
wasi.initialize(instance);
instance.exports.f(100n);
```

WASI file paths use absolute preopen names and a virtual working directory (`PWD`, or the
first preopen). Preopens must occupy contiguous descriptors starting at 3; the first EBADF
ends discovery. Resolution uses the longest component-prefix match. `link/..` is resolved
lexically, and `cd(f, dir)` restores the old directory by path, so renaming that directory
can prevent restoration. Permission bits, uid/gid and block counts are synthesized unless
a mode provider is installed. Default modes do not enforce access or guarantee 0600/0700
privacy for temporary files/directories. Access checks approximate owner bits, not ACLs or
effective credentials. Preview 1 metadata timestamps cannot represent times before 1970.

File IOStreams write synchronously to the host; `flush` has no pending file output to drain
and does not promise durability. After read-ahead, writing or truncating requires a successful
rewind; nonseekable duplex descriptors fail this transition and retain their read buffer.
Writes retry EINTR from the unwritten suffix; EAGAIN is reported without waiting for host
readiness. An error after a partial write can leave a prefix written. Raw `jl_fs_read`,
`jl_fs_write` and `jl_fs_sendfile` return counts or negative errors, permit short IO, and cap
each request at 1 MiB. Julia's complete-read/write wrappers loop above that interface.
Positional IO uses `fd_pread`/`fd_pwrite` and never moves the source/current file offset.

Creation followed by mode adjustment is not atomic. If a mode query or adjustment fails,
the created object remains at the host's mode and a newly opened descriptor is closed.
Path-based mode adjustment has replacement races. Atomic create-with-mode and
identity-checked chmod require a stronger host interface and are outside this contract.
Directory records up to 1 MiB and symbolic-link targets shorter than 1 MiB are supported;
ambiguous full buffers grow to that bound and then report ENAMETOOLONG.

`compile` throws `UnsupportedConstructs` with the statements it cannot compile and the
method instances they are in, as juliac's verifier reports what it cannot trim. The module
it returns is optimized by `wasm-opt -O3` (Binaryen_jll); `Config(optimize=nothing)` gives
the raw module, for debugging the code generator only.

Each example builds a page: `examples/lorenz` solves the Lorenz system with adjustable
parameters, `examples/mtk` simulates a ModelingToolkit model with sliders, and
`examples/juliasyntax` parses Julia source in the browser.

## Host runtimes

The supported hosts are Node.js, wasmtime and, partly, Cloudflare workerd. The sections
below say what each needs and what doesn't work yet.

Modules use WasmGC and typed function references. A program that catches exceptions also
uses exception handling with `exnref`; one that catches none traps on a throw instead.

### Node.js

Node 24 is the reference host: the tests run there. Node 24.21 enables `exnref` and JSPI
(JavaScript Promise Integration) by default, so the tests pass no Wasm flags. JSPI is
needed by the host's events of
[#36](https://github.com/gbaraldi/WasmCodegen.jl/pull/36) and by Tasks on JSPI of
[#37](https://github.com/gbaraldi/WasmCodegen.jl/pull/37) (both not merged). On a Node
without JSPI by default, these need `--experimental-wasm-jspi`.

For speed, keep the defaults: `wasm-opt -O3` and Node's own tiering. Node's
`--liftoff-only`, `--no-liftoff` and `--no-wasm-dynamic-tiering` were each slower in
[#43](https://github.com/gbaraldi/WasmCodegen.jl/issues/43).

### Browsers

Only V8 has been checked, through Node and workerd. No minimum browser version has been
verified. The example pages' error message gives the versions that added WebAssembly GC
(Chrome 119, Firefox 120, Safari 18.2), which is not all a module may use. Browser support
for `exnref` and JSPI hasn't been tested here.

### wasmtime

Tested with wasmtime 50.0.1.

- **Support.** GC, typed function references and exceptions (`exnref`) are Tier 1 and
  enabled by default with Cranelift
  ([status](https://github.com/bytecodealliance/wasmtime/blob/v50.0.1/docs/stability-wasm-proposals.md)).
  A module that imports nothing, such as a Tsit5 solve, runs with the default flags and
  gives Node's results. A `host = :js` module that imports `julia` functions doesn't run as
  is: `js/julia.mjs` implements them in JavaScript, and an embedder would have to provide
  its own.
- **WASI imports.** wasmtime rejects `host = :wasi` modules built with the current
  WasmBuilder at instantiation, with `types incompatible`: WasmBuilder puts every type in
  one recursion group. Modules built with
  [gbaraldi/WasmBuilder.jl#2](https://github.com/gbaraldi/WasmBuilder.jl/pull/2) (import
  types in recursion groups of their own, not merged) run, and give `node:wasi`'s output.
- **GC heap size.** The default collector is the copying collector. On a Dict/String loop
  that keeps a Dict alive, its heap stayed small and it collected constantly; a 64 MiB
  initial heap made the loop about 5.6× faster (4.76 s to 0.85 s), for about 64 MiB more
  memory. For allocation-heavy code, try a bigger initial heap:

  ```
  wasmtime run -O gc-heap-initial-size=67108864 --invoke f module.wasm 100
  ```

  An embedder sets
  [`Config::gc_heap_initial_size`](https://github.com/bytecodealliance/wasmtime/blob/v50.0.1/crates/wasmtime/src/config.rs#L1521).
  Keep the copying collector: with `-C collector=drc` the same loop took about 4× as long
  as with the default, and DRC doesn't collect cycles.
- **Tasks.** Tasks on JSPI (#37) import JSPI functions from JavaScript, so they don't run
  on wasmtime. Wasm stack switching could replace them, but wasmtime has it at Tier 3,
  off by default, and only on x86_64 Linux.
- **Threads.** Shared memory and atomics (Tier 2) share linear memory only, not WasmGC
  objects, which every Julia object is here. Sharing those needs shared-everything
  threads, which wasmtime hasn't implemented
  ([#9466](https://github.com/bytecodealliance/wasmtime/issues/9466)). wasi-threads, a
  thread-spawning ABI, is [legacy](https://github.com/WebAssembly/wasi-threads) and Tier 3
  in wasmtime. Independent instances on separate threads need none of these.

### Cloudflare workerd and Workers

Partly supported. Tested locally with workerd 1.20261031.1 (V8 15.7) and not deployed.

- **Runs:** a Lorenz solve and a Dict/String loop gave the same results as Node, with the
  imports from `js/julia.mjs`'s `createHost`. JSPI works in workerd.
- **Doesn't run:** Node's WASI driver. workerd's `node:wasi` throws
  `ERR_METHOD_NOT_IMPLEMENTED` from its constructor, so `host = :wasi` modules need another
  implementation of their WASI imports. `js/julia.mjs` has one; in workerd only its
  `random_get` has been exercised. The host's events of #36 (`js/julia_io.mjs`) fail too:
  they detect the platform from Node's diagnostic report, which workerd doesn't fill in.
- **Compiling at request time is disallowed** ("Wasm code generation disallowed by
  embedder"). Configure modules as Wasm modules of the Worker and instantiate the
  `WebAssembly.Module` they import. `instantiate(bytes)` of `js/julia.mjs` compiles bytes,
  so it can't be used inside a request.
- **`wasm:js-string`** builtins need the compatibility flag
  `wasm_esm_integration_builtins`.
- **Production limits** ([limits](https://developers.cloudflare.com/workers/platform/limits/)),
  which local workerd doesn't enforce: 128 MB of memory per isolate, including Wasm; CPU
  time per HTTP request, 10 ms on the Free plan and 30 s by default (up to 5 minutes) on
  the Paid plan; 64 MiB of uncompressed bundle; 1 s of startup.

### Not supported or untested

- **WasmEdge** 0.18.1 is not a supported host, and WasmCodegen's output hasn't been tried
  there. Its [0.18.0 release](https://github.com/WasmEdge/WasmEdge/releases/tag/0.18.0)
  turned on the Wasm 3.0 proposals, including exception handling, function references and
  tail calls, by default. Its [proposal tracker](https://github.com/WasmEdge/WasmEdge/issues/4825)
  still lists GC as unfinished (a real runtime collector,
  [#4156](https://github.com/WasmEdge/WasmEdge/pull/4156)), as well as stack switching and the
  component model.
- Other engines and runtimes haven't been tried: Wasmer, wazero, Deno and Bun.

## How it works

- **The program's world.** The program is inferred in a world with juliac's trim patches
  (method redefinitions from JuliaC.jl) and the pseudo-runtime's own (`src/trim`), such
  as IO through a host import instead of libuv. The patches are deleted afterwards. The
  compiler itself runs in the world it was loaded in.
- **Collecting.** `Core.Compiler.compile!` with a Wasm interpreter, as juliac's
  `typeinf_ext_toplevel` does, so the code compiled is the code juliac compiles.
- **Structuring.** Each function's IR is turned into structured control flow by
  [IRStructurizer.jl](https://github.com/maleadt/IRStructurizer.jl). For now this is the
  `eh-tryop` branch of [a fork](https://github.com/gbaraldi/IRStructurizer.jl/tree/eh-tryop),
  which adds structured exception handling; `Project.toml` installs it from there.
- **Emitting.** Values follow JuliaCodegen.jl's representations. Isbits values are inline
  (Wasm locals, multi-value returns), everything else is a WasmGC object with a type tag.
  `Memory` is a Wasm array, and Base's `Array` code compiles from its Julia source.
  Pointers are an address plus the object they point into, so Base's pointer code works.
  Modules are built and validated with
  [WasmBuilder.jl](https://github.com/gbaraldi/WasmBuilder.jl).
- **Optimizing.** The code generator emits simple code (a local per value, a helper per
  type for memory access and boxing) and leaves locals, the operand stack and inlining to
  `wasm-opt`.
- **The image.** Constants and global variables, and everything reachable from them,
  become immutable globals in the module, with identity preserved and cycles completed by
  the start function.

[DESIGN.md](DESIGN.md) describes each part.

## Tests

`Pkg.test()` compiles each test program, runs it in Node.js 24 (`NodeJS_24_jll`), and
compares the result with native Julia. Modules are validated by WasmBuilder, and also by
`wasm-tools` when it is installed.
