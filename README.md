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
