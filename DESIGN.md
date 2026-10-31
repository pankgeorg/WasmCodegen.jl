# WasmCodegen.jl design

WasmCodegen compiles Julia programs to WebAssembly with the GC proposal (WasmGC), the
way `juliac --trim` compiles them to native code: from entry points, it collects the
closed world of code they can run, compiles it, and serializes the Julia objects that code
refers to into the binary, so the module starts with the heap the program needs. No Julia
runtime is linked. What libjulia does natively (allocation, GC, object layout, type tags)
is done by WasmGC and by generated code. What the C runtime and libraries do (IO, 128-bit
arithmetic, ...) is a small runtime written in Julia, compiled into the module on demand,
over a few host imports.

The supported subset is what `juliac --trim=safe` accepts (no dynamic dispatch), on
Julia 1.13 (1.12 works too).

It follows JuliaCodegen.jl (Julia's code generator written in Julia) in how values are
represented, SynchJulia.jl and cuTile.jl in how it gets and structures IR, and JuliaC.jl
in how programs are prepared for trimming. WasmBuilder.jl (the LLVM.jl of Wasm) builds and
validates the module. WasmTarget.jl was a reference for edge cases (`docs/EDGE_CASES.md`).

```
entry points (f, argtypes)
  │  in a world with juliac's trim patches (+ the pseudo-runtime's): method definitions
  │  compiler pinned to its own world (the world WasmCodegen was loaded in)
  ▼
collect: CC.compile! under WasmInterpreter    ── juliac's typeinf_ext_toplevel
  │  (native inference; target fact: have_fma = false)
  │  check: juliac's trim verifier, on the native interpreter (trim_check)
  ▼
per function: CodeInfo → IRCode → prepare → StructuredIRCode (IRStructurizer.jl)
  │  prepare: exceptions as the program uses them, drop unused type computations
  ▼
emit: walk the structured IR → WasmBuilder (validating builder)
  │  simple code: a local per value; per-type helpers for memory access and boxing
  │  runtime functions (Julia) and host imports added on demand
  ▼
image: serialize the referenced objects; start function completes them (WASI: _initialize)
  ▼
raw module (WasmBuilder's validation, and wasm-tools' when installed)
  ▼
wasm-opt -O3 (Binaryen_jll): locals, stack code, inlining, the rest
  ▼
module bytes
```

## 1. The program's world: no overlays, patches

Inference is Julia's own: the same `InferenceParams`/`OptimizationParams` as juliac
(`force_enable_inference`), concrete and semi-concrete evaluation included, over Julia's
own method table, with its own cache owner. The only target-specific fact is
`have_fma = false` (Wasm has no fused multiply-add), folded in `abstract_call_known`.
Inlining is Julia's own too. One optimizer parameter differs: `compilesig_invokes = false`,
so a call targets the method instance of its argument types rather than the signature
native code would be compiled for, which widens arguments of type `Function`, `Type` and
`Vararg` that a method only passes on. A closed world has no dynamic dispatch to fall back
on: JuliaSyntax's parser passes its subparsers as `down::Function`, which juliac's own
verifier rejects, and compiles once they are specialized.

There is no overlay method table, not even an empty one. Stacking one makes the
interpreter overlayed, and inference then taints every call it cannot resolve statically
(`nonoverlayed`), which disables concrete evaluation of everything that may reach one (a
`typejoin` building a vector; `Base.packedsize`, whose `padding` reflects on field types,
so `reinterpret(NTuple{4,UInt8}, x)` compiled its reflection instead of folding it). And
code built on fake native bodies confuses effects (an overlay's native fallback made an
intrinsic look effect-free, and it was deleted). What overlays would do is done instead:

- **juliac's trim patches** (`src/trim/juliac-*.jl`, from JuliaC.jl): the method
  redefinitions juliac applies in its build process (`invokelatest` as a direct call, no
  logger lookups, trim-friendly `show(::Type)`, raised `max_args`, ...);
- **the pseudo-runtime's patches** (`src/trim/wasm-*.jl`): Base and Core methods
  redefined for what Wasm has no C runtime for, written over runtime primitives. IO:
  Core's standard streams write through `Runtime.IO.write_byte` instead of libuv.
  `Base._reinterpret` of isbits values folds the padding reflection at compile time and
  calls `Runtime.reinterpret_bits` (which the code generator compiles to a rearrangement of
  leaves) instead of copying bytes between `Ref`s. Random's bulk generator's vector
  operations (`llvmcall`s on `NTuple{N,VecElement{UInt64}}`) are the same operations on
  each element, so its streams are the native ones. Paths are split by their bytes
  (`splitdir`, `basename`, `splitext`, `isdirpath`: Base matches them with PCRE regular
  expressions, a C library), checked against Base on every path of up to 7 characters
  over `a`, `.`, `/`, `é`;
- **lowering in the code generator** of what Base does with pointers and C calls
  (`memmove`, `memset`, `jl_genericmemory_copyto`, `jl_alloc_genericmemory`, string
  conversions), from the IR (section 5);
- **runtime functions** in Julia for what Wasm lacks (128-bit arithmetic, exact `fma`).

Patches are real method definitions: native inference treats them like any method. They
are defined in a new world for a compilation (or a session of compilations,
`with_trim_patches`), the program is inferred in that world, and they are deleted
afterwards (deleting a method that replaced another restores it; the one constant juliac
rebinds, `Base.invokelatest`, is rebound).

**The compiler runs in its own world**: the world WasmCodegen was loaded in. All of
`compile` runs through `invoke_in_world(COMPILER_WORLD, ...)`, so the compiler's native
code stays valid whatever is defined or deleted later (patches, the program, packages
loaded afterwards), as GPUCompiler isolates the compiler. Without this, each patch cycle
invalidated the compiler's own code and every compilation re-JITted it (≈50 s); with it, a
patched compilation of a small function takes about a second.

## 2. Collecting the closed world, checking it

`collect_world` drains a `CompilationQueue` with `CC.compile!` (as juliac's
`typeinf_ext_toplevel`), then completes `:invoke` targets inference kept without source,
to a fixpoint. `CodegenSources` serves `compile!` the sources of CodeInstances cached by
earlier interpreters (uncompressed on demand), so inference results are reused across
compilations. `extend_world!` adds functions later (the runtime's).

`trim_check` is juliac's check, exactly: native inference collects the entry points'
code (`typeinf_ext_toplevel` with `TRIM_UNSAFE`) and juliac's verifier reports dynamic
dispatch. With `Config(verify=:warn)` (the default) it reports; `:error` fails as juliac
`--trim=safe` does. (The verifier on our own collection gives false positives: its fallback
cache only knows CodeInstances of the native cache.)

The code generator then reports every construct it cannot compile, all of them
(`UnsupportedConstructs`), with `trim = :safe` (the default). `trim = :unsafe` compiles
them to traps where they are, as `juliac --trim=unsafe`.

## 3. Structured IR

IRStructurizer recovers `IfOp`/`WhileOp`/`LoopOp` regions with block arguments; Wasm
control flow is structured, so the lift is direct:

| Structured op | Wasm |
|---|---|
| `IfOp` with `YieldOp`s | `if` with result locals assigned in each arm |
| `LoopOp` (`ContinueOp`/`BreakOp`) | `block $exit (loop $cont ...)` |
| `WhileOp` (before/`ConditionOp`/after) | `block (loop before (if !cond results br exit) after br loop)` |
| `ReturnNode` | `return` |

Loops are not promoted to counting `ForOp`s (`promote = false`): a `ForOp` has neither the
signedness of the comparison it came from (`ult_int`) nor room for an inclusive bound at
`typemax`, and gains nothing on Wasm. Carried values are assigned in parallel (all values
pushed, then all locals set). Results of control-flow ops are lists of values read by
`getfield(op, i)`.

The structured form threads values through every `if` on the path between a definition
and a merge (a phi of Julia's IR becomes results of each enclosing `if`): JuliaSyntax's
`parse_call_chain` has 1,511 `if`s with 57,977 results. Three rules keep that from turning
into copies, all exact:

- **Aliasing.** A result that each arm yields as the same value, or as undefined, is that
  value: no locals, no copies (Wasm locals live in the whole function, and an undefined
  result is not read). An undefined value is never stored.
- **Destination passing.** A result of a control-flow op that only goes to the yield ending
  its block, to the enclosing `if`'s result, is assigned there directly: a chain of nested
  merges shares one set of locals. (Never to a loop's carries, which the loop reads.)
- **Dead carries.** A loop carry nothing reads has no locals. IRStructurizer's
terminator type check is stricter than Julia's IR (a phi's edge value may be wider than
the phi when a branch narrowed it), so that one validation is skipped.

**Exceptions** (`exceptions.jl`) are Wasm's: one tag, whose payload is the exception
object, `throw`, and `try_table`. What a program needs is decided for its closed world:

- *nothing catches* (no `try` with a handler): a throw traps, `prepare` removes the
  handlers of `try`/`finally` (`EnterNode` edges, `:leave`, `:pop_exception`, upsilons),
  replaces the thrown value by `nothing` and removes the computations that only built it
  (exception objects, error messages) when they are effect-free or build an exception or
  a string. Functions that always throw are still compiled (their effects before the
  throw happen);
- *something catches but nothing reads the exception* (no `:the_exception`; Julia infers
  exception types, so `catch e; e isa BoundsError` is often folded): throws unwind to the
  handlers with a null payload, and exception objects are still not built;
- *a handler reads the exception*: throws carry the objects, and the code generator's own
  checks throw what Julia's C runtime throws (`BoundsError(memory, i)`, `DivideError`,
  `UndefRefError`, `TypeError` of `typeassert`, `UndefVarError`, `MethodError`), built by
  runtime functions (`runtime/errors.jl`). Errors Wasm checks itself (a failed cast, an
  array index out of range) remain traps, which no handler catches.

A `TryOp` (IRStructurizer branch `eh-tryop`) is

    block $exit
      block $handler (result exception)
        try_table (catch $tag $handler)  body (its yield: results, br $exit)  end
        unreachable
      end
      current exception := the caught one;  handler (its yield: results)
    end

A `LeaveOp` (an exit of a try body from a nested region) assigns the results and branches
to `$exit`. Handler arguments (Julia's `PhiC`s) have locals, assigned by their upsilons,
which may come before the `try`; Wasm locals keep the values a throw left. The current
exception (`catch e`, `rethrow()`) is a global, set by a handler; `pop_exception` restores
the value it had at the `try`.

## 4. Values

As in JuliaCodegen (and Julia's code generator), a value's representation follows its type:

- **ghost**: singletons and zero-size types (`nothing`, functions without captures,
  unique `Type{T}`): no Wasm value;
- **inline**: concrete immutable types (primitives, tuples, structs, closures) with at
  most 64 leaves: a flat list of Wasm values, its *leaves* (`SVector{3,Float64}` is three
  `f64`s). Never allocated: `getfield` selects leaves, `new` gathers them, calls take and
  return them as multiple values. Tuples whose fields are unique `Type{X}`s (packed varargs)
  are inline too, and so are tuples with elements of small unions of concrete types
  (`Tuple{Bool, Union{Nothing, Int}}`, the union element boxed): boxed, such a tuple is of
  one of its few concrete types, which boxing and unboxing test;
- **boxed**: everything else, one reference.

One exception, for an element at a run-time index of an inline tuple of mixed concrete
types (`t[k]`, as `string` and `print` read their arguments), which is of a union: where it
is only tested with `isa` and narrowed, it is *split*, a tag (which member it is) and a value
of each member, assigned by the field the index selects, and never boxed.

Primitives: 8/16/32-bit integers, `Bool`, `Char` (its bits) are `i32`, kept zero-extended
(masked after arithmetic, sign-extended where signedness matters); 64-bit `i64`; floats
`f32`/`f64`; 128-bit integers two `i64` leaves (low, high), their arithmetic in the
runtime; pointers two leaves, an `i64` virtual address and the object they point into
(section 5).

**Objects** are `$JlValue` subtypes: `(struct (field $typeid i32) (field $hash (mut i32)) ...)`.
The type id indexes the closed world's types (for `isa`, `typeof`); the hash is the
identity hash, assigned on first use.

- mutable structs: the header, then their fields' leaves, flattened (mutable, nullable
  references; null is `#undef`);
- inline values stored where the type is abstract: a box (`$Box{T}`, immutable leaves);
  ghosts: one singleton object per type;
- `Memory{T}`: an object holding a Wasm array of the elements; `String` and `Symbol`:
  objects holding a byte array (the same array type as `Memory{UInt8}`, so conversions
  share bytes); `String` `===` compares contents;
- large homogeneous tuples (more than 64 leaves) and tuples of unknown length
  (`Tuple{Vararg{T}}`, e.g. from splatting a vector): an immutable object holding an
  array, which can be indexed at run time; a run-time index into a small inline tuple of
  one element type builds a temporary array. A tuple held as an object (an `Any`) is one
  of its concrete type, so a tuple of unknown length becomes one of the concrete type its
  elements make it, and one is rebuilt as an array from such an object, by helpers per
  type of unknown length generated over the module's concrete tuple types (section 8);
- type objects (`DataType`s used as values): one interned object per type, holding the type
  id it is; what code asks of them at run time is answered by tables (section 8). A
  `TypeName` has only its name; a `SimpleVector` (a type's parameters) is an array object;
- immutable types Julia does not store inline (those containing themselves, as
  `Base.ImmutableDict`, behind `IOContext`): immutable objects, a field per leaf.

All types are in one recursion group, so they are nominal.

**Memory layout.** A `Memory{T}`'s array stores, per element: a primitive as its numeric
type (packed `i8`/`i16` for small ones); an inline value whose leaves are stored alike as
its leaves (stride `k`: `SVector{3,Float64}` is 3 `f64`s, as Julia lays it out); other
isbits values as their leaves widened to `i64` (never `#undef`); other inline values
(with references, mixed) as references to boxes; references as references. Where Julia
stores a type inline without references (isbits types, isbits unions, structs with union
fields), a value never stored (an element of a new memory, a field `new` is not given) is
its zero bits, a union's of its first type (`Vector{Union{Missing,Float64}}(undef, n)`
holds `missing`s): a null reference read there is that value, and `new` stores it; of
other types, a null reference is `#undef` (`UndefRefError`).
`MemoryRef{T}` is inline: the Memory object, its array (so accesses don't load it) and the
element index. `Array` is then Base's own mutable struct, and Base's array code (growth
with `_growend!`, `copyto!`, broadcasting, `sort!`, `cat`) compiles from its Julia source.

## 5. Pointers: address and owner

Wasm has no addresses. Base takes pointers into memory (`ptr_or_offset`, `pointer(s)`,
`jl_value_ptr` of a `Ref`) to call C (`memmove`, `memset`, ...), for alias checks
(`dataids`), and to read memory as other types (SHA reads its byte buffer as `UInt32`s,
Random writes `UInt64`s into a `Vector{UInt8}`). A `Ptr` is two leaves (`pointers.jl`):

- a **virtual address** (`i64`): each object gets a range from its identity hash shifted by
  32 bits, plus the byte offset, so comparisons and differences behave as natively; integer
  operations on pointers are operations on their addresses;
- its **owner**, the object it points into (a Memory, a String, a `Ref`), or null for a
  pointer made from an integer, which cannot be dereferenced.

Pointer arithmetic moves the address and keeps the owner, and both cross calls with the
pointer, as any value's leaves do. Memory is addressed by bytes as Julia lays it out, so a
pointer may reinterpret it.

`unsafe_pointer_to_objref(p)` is `p`'s owner when `p` is at the owner's base address, and
traps otherwise. Since the owner follows the pointer and not its address, a pointer without
owner (made from an integer, or through an integer round trip) and one moved by arithmetic from
one object to another (`p + (q - p)` keeps `p`'s owner) trap where natively they give the
object at that address.

Within a function, a pointer also carries its **origin** when it is known statically: the
array of its owner, the byte offset into it, and the type of its elements. A load, store,
`memmove` or `memset` through pointers with origins compiles to array accesses
(`array.get`/`set`, `array.copy`, `array.fill`): of whole elements when aligned to them
(checked at run time, as Julia allows any alignment), else of the bytes of the elements
holding them. Without an origin (a pointer that crossed a call), the access goes byte by
byte through two run-time helpers, `jl_ptr_load_byte(address, owner)` and
`jl_ptr_store_byte(address, owner, byte)`, generated once the module's types are known:
they find the byte from the owner's type id: of a memory whose elements are stored as
laid out, of a memory of widened or padded isbits elements (by the leaves of an element),
of a string, or of the isbits fields of a mutable object. `memmove` and `memset` without
origins are byte loops in the runtime (`Runtime.ptr_memmove`/`ptr_memset`). An owner whose
bytes are not addressable (a memory of references) traps.

## 6. The image: serializing objects

Constants in the IR (literals, `QuoteNode`s, constant globals) and the values of global
variables, and every object reachable from them, are serialized into the module, as juliac
puts them in its image: a program can build data at compile time (an `ODEProblem`, an
integrator after `init`, a table) and the module contains that data, not the code that
built it.

- An inline constant is instructions (its leaves; references inside are `global.get`s).
- An object is one immutable global, initialized by a constant expression (`struct.new`,
  `array.new_fixed` for small arrays), emitted in depth-first postorder so referenced
  objects come first. Identity is preserved (an `IdDict`): an object referenced from
  several places is one object.
- A reference to an object being serialized (a cycle) is null in the initializer and set by
  the module's start function once every global exists. Cycles through immutable objects
  are rejected for now (an allocate-then-patch order over strongly connected components
  would handle them).
- Large numeric arrays are `array.new_default` in the initializer and filled by the start
  function from passive data segments (`array.init_data`); large reference arrays are filled
  by the start function.
- `MemoryRef` constants are (Memory object, array, index); type objects are interned, and
  carry their native `objectid` (as mutable objects do), so that `IdDict`s with type keys
  built at compile time find them.
- Global variables are mutable globals (one per leaf of the declared type), initialized
  with their value at compile time.
- A `Ptr` constant must be null (`C_NULL`): a non-null one is an address of the build process,
  which means nothing in the module, and is rejected unless its field is allowlisted by
  `Config(image_pointer_fields)` (then it is kept as an address without owner).
- A symbol carries its hash, as Julia's runtime computed it, so that dictionaries with
  symbol keys built at compile time are found at run time.
- Not serializable (an error naming the object): tasks, modules, methods.
- Not preserved: memory shared between distinct `Memory` objects (an `unsafe_wrap` of
  another array's data is a copy), and the distinctness of equal `String`s (one object).

## 7. Functions, calls, intrinsics

One Wasm function per CodeInstance; parameters and results are the leaves of the
arguments (the function object too, for closures; varargs packed in a tuple) and of the
return type. `:invoke` calls it, converting representations (boxing for abstract
parameters). Builtins (`getfield`, `setfield!`, `===` (bitwise on floats, by content for
immutables), `isa` (type ids, a generated predicate per abstract type), `tuple`,
`ifelse`, `memoryref*`, `_apply_iterate` into tuples, ...) and intrinsics are emitted
inline, with Julia's semantics where Wasm's differ: over-shifts, saturating float→int,
checked arithmetic, `fpiseq`, IEEE `min`/`max`, division traps. A `PiNode` narrows without
a check, as natively: Julia's optimizer sometimes places one where it does not hold (a
value forwarded with a flag saying whether it is `nothing`, read only where it is not), so
a boxed value is converted only if it is of the narrower type. A value of a type
where one of a type it shares no value with is expected (in code inference put after a
test that cannot pass) is a trap, not an error; so is a field a type does not have
(`FieldError`, as natively). `typeof` of a value of a union of concrete types, and `isa`
or `typeassert` against such a type (`x::typeof(y)`), are chains of tests of its members;
`isdefined(x, i)` and `getfield(x, i)` of an index known only at run time, chains over
the fields.

Atomic operations on fields (`swapfield!`, `modifyfield!`, `replacefield!`,
`setfieldonce!`) and `Threads.Atomic`'s (intrinsics, or on Julia 1.12 the `llvmcall`s of
LLVM's atomic instructions it is written with) are the loads and stores they are: a
program runs as one task on one thread. So locks are taken without contention; waiting
(`wait()`, a contended lock) can only wait forever and scheduling another task has none to
schedule, so both throw a `ConcurrencyViolationError` in place of the scheduler. The C
runtime's finalizer and CPU hints are no-ops, and its thread queries say the main thread
(thread 1, in the pool of id 0, as natively). LLVM intrinsics that code calls with `ccall("llvm.<name>.<type>", llvmcall,
...)` (`fmuladd`, `fma`, `sqrt`, `fabs`, `copysign`, rounding), on floats or on vectors of
them (`NTuple{N,VecElement{T}}`, element by element), are the matching Julia intrinsics:
LinearSolve's blocked LU kernel is written with `llvm.fmuladd.v4f64` on vectors loaded
through pointers. Other `llvmcall` IR (VectorizationBase's, LoopVectorization's) is not
supported.

Operations whose code grows with the value they move are **outlined**: a helper function
per operation and type, called where they are used (`outline.jl`): `memoryrefget`,
`memoryrefset!`, `memoryrefnew`, `memoryref_isassigned`, `memorynew`, boxing and unboxing,
and `objectid` of immutable objects (which may refer to others of their type: the helper
calls itself at run time instead of the emission recursing).
A helper's body is the operation's inline emission, run in the helper's own context, so
there is one implementation; Binaryen inlines the helpers where it pays, and keeps others
shared (10% smaller modules for the parser).

## 8. The runtime

- **Runtime functions** (`src/runtime/`, module `WasmCodegen.Runtime`): Julia code the
  code generator calls for what Wasm lacks, compiled into the module on demand
  (`runtime_function!` extends the closed world): 128-bit integer arithmetic on `UInt64`
  pairs (multiplication by 32-bit halves, shift-subtract division); `fma` is Base's
  `fma_emulated`; Float16 conversions (compiler-rt's: exact widening, narrowing rounded
  once, quiet NaNs), with Float16 arithmetic done in Float32 and rounded back, as LLVM
  does without half-precision hardware; the exceptions of the code generator's checks.
- **C library calls implemented in Julia** (`RUNTIME_CCALLS`), checked against the native
  libraries: Unicode properties (`utf8proc_category`, `utf8proc_isupper`/`islower`, case
  mappings, `utf8proc_charwidth`, `jl_id_char`, `jl_id_start_char`: tables of runs
  computed from the native libraries when WasmCodegen is compiled, exact on every code
  point; `utf8proc_grapheme_break_stateful`: utf8proc's rules over its classes);
  `strtod`/`strtof`/`jl_try_substrtod` (the extent of the number as C finds it, the value
  from Parsers.jl, which is correctly rounded without C or big floats) and `errno`;
  `memmove`/`memset`/`memcmp`/`memchr`/`strlen` through pointers without origins (a C
  string ends at its owner's end: Julia's strings and symbols are NUL-terminated);
  `jl_symbol_name` (a pointer into the symbol's bytes; `Cstring`s are pointers too);
  identity hash tables (`IdDict`: `jl_eqtable_*`, `iddict.c`'s open addressing by
  `objectid` and `===`, so that a table built natively and serialized is found the same
  way); `deepcopy`'s `jl_new_structv` (a new immutable from an array of its fields).
- **BLAS and LAPACK** (`runtime/blas.jl`, `lapack.jl`): what LinearAlgebra calls in
  libblastrampoline, on Float64 and Float32: levels 1 to 3 (`dot`, norms, `gemv`, `gemm`,
  triangular and symmetric products and solves, rank updates), LU (`getrf`, `getrs`,
  `getri`), Cholesky (`potrf`, `potrs`), triangular solves, QR (`geqrt`/`gemqrt`, pivoted
  `geqp3`/`ormqr`) and the rank-deficient least squares behind `\` (`laic1`, `tzrzf`,
  `ormrz`), symmetric indefinite factorizations (Bunch-Kaufman's `sytrf`/`sytrs` and their
  rook variants: LAPACK's `dsytf2` ported), symmetric eigenvalues (`syevr`) and singular
  values (`gesdd`, `gesvd`) by Jacobi's methods: reference algorithms, unblocked. An array argument is a `MemoryRef` where the
  pointer's memory is known, else the pointer; outputs are written through. Results agree
  with an optimized BLAS's within rounding (the order of sums differs). Vectors of eigen- and
  singular values agree up to their signs. Not yet: nonsymmetric eigenvalues.
- **Hashes as the C runtime computes them**, so that dictionaries built at compile time are
  found at run time: `objectid` of symbols (their hash: MurmurHash3 of the name, mixed;
  symbols in the image carry it, computed natively), of isbits values of 1, 2, 4 or 8
  bytes (`immut_id_`: the bits' hash and the type's; other sizes, `memhash` of the
  bytes), of immutable values with references (their fields' ids mixed, `bitmix`; a field
  stored inline of a union of types, by the member it holds), and
  strings (`memhash_seed`, which `hash(::String)` calls before Julia 1.13). Strings and
  symbols are `===` by their bytes, so symbols made at run time need no interning. A
  mutable object's `objectid` is natively a hash of its address: an object of the image
  keeps the one it had natively (its header's hash refers to a table of them), so that
  dictionaries keyed by such objects find them; others hash their identity hash. Modules
  are objects of the image carrying their name (`nameof`), compared by identity.
- **Types at run time** (`reflection.jl`). Types are not made at run time: those a
  program can hold are the ones with objects in its image, all known when the module is
  finished. So what code asks of a type at run time is computed natively for each of them
  then, and looked up: `<:` in a table of bits over all pairs, and functions of types
  (`Runtime.map_type(f, T)`, as `nonnothing_nonmissing_typeinfo` of `show`) in tables of
  their values, whose objects are added to the image; `x isa Type{<:Real}` (a pattern that
  holds of some types and not others of their kind) in a table of which types are, as a
  type object's header only says which kind of type it is. `===` of values whose types
  are known only at run time is `jl_egal`, generated over the module's types: identity for
  mutable ones, contents for the others (strings, boxes, immutable objects, tuples,
  SimpleVectors). Their `objectid` is `jl_object_id`, by type too: of each type whose
  values may be objects, the code of `objectid` for that type, compiled once the program's
  code is (until it adds no types; a type whose `objectid` cannot be compiled traps there,
  not an error of the program). The conversions of tuples of unknown length to and from
  objects (section 4) are helpers of the same kind: per concrete tuple type of the
  module, a test of the elements and the conversion, compiled with the code. A tuple whose
  concrete type the module does not have (no code names it) is an object of `Tuple`, its
  elements as objects: one such object of its elements whatever type it came from,
  compared (`===`) and hashed (`objectid`, not the native one) by its elements, and tested
  by them for tuple types; `typeof` of it is `Tuple`. These cases are compiled until
  they, and the values of the type maps, add no types, and the tables are built after
  them and the image. Printing a type (juliac's `show`,
  which reflects on it) is a foldable function returning its name as a Symbol, so that
  inference computes it for a type known at compile time (a `Union` or `UnionAll` is not
  a constant for inference: printing one at run time needs reflection, not supported).
- **Primitives**: runtime functions whose calls the code generator compiles to the host's
  (`host.jl`): `write_byte(fd, byte)` and `flush_output(fd)` (the end of a write),
  `entropy()` (the seed of the task's random number generator), `hrtime()` (`time_ns()`: a
  monotonic clock in nanoseconds), `clock_now()` (`time()`: seconds since the Unix epoch, to
  the microsecond as natively).
  The C runtime's globals code reads through `cglobal`: none so far but
  `jl_gc_have_pending_finalizers` (an image object holding 0). The thread counts behind
  `Threads.nthreads()` (`jl_n_threads_per_pool`, a pointer to an array) are not yet
  supported.
- **The pseudo-runtime's patches** (section 1): Base/Core methods over the primitives
  (IO for `Core.stdout`/`Core.stderr`).
- **The host** (`Config(host = ...)`), as other languages compiling to Wasm have both a
  JavaScript and a WASI target (Go's `js` and `wasip1`, Kotlin's `wasmJs` and `wasmWasi`):
  - `:js`: imports of the module `julia` (`write_byte`, `entropy`, `hrtime`, `clock_now`), which
    `js/julia.mjs` provides (`WasmCodegen.JS_HOST`): it buffers output bytes per
    descriptor and decodes them as UTF-8. `flush_output` compiles to nothing.
  - `:wasi`: WASI preview 1 (`fd_write`, `random_get`, `clock_time_get` of the monotonic
    and real-time clocks). WASI passes data through linear memory, which a WasmGC module otherwise has no
    use for: as Kotlin's WASI target does, the module has a page of it for these calls
    only, exported as `memory` (as WASI requires): the 8 bytes of a call's result, an
    iovec, and an output buffer that `write_byte` appends to and `fd_write` writes out at
    `flush_output`, when full, or for another descriptor. A failed `random_get` or
    `clock_time_get` traps. Initialization (the image's, which seeds the RNG through the
    host) runs from the exported `_initialize`, as a WASI reactor's, instead of a start
    function: a WASI host can serve calls only once the instance (its memory) exists.
    `js/julia.mjs` implements these three functions too, for JavaScript without WASI.

  The test runner (`test/runner.mjs`) runs `:js` modules with `js/julia.mjs` and `:wasi`
  ones with Node's `node:wasi`; `WASMCODEGEN_TEST_HOST=wasi` runs the suite for WASI.

Next: `IdSet` (`smallintset.c`); `deepcopy` of mutable structs (`jl_set_nth_field` of an
object whose type is known only at run time); pointers stored in memory (the C runtime's
thread counts).

## 9. Output, performance

Exports are the entry points under their names, with their leaves as parameters and
results (`i64` is a JavaScript BigInt).

The code generator emits simple code and `compile` optimizes it with `wasm-opt -O3`
(`Config(optimize=...)`; the features are listed explicitly: `-all` enables proposals V8
does not ship). Allocating locals, putting values on the operand stack and inlining small
helpers are Binaryen's job, which it does far better than a code generator's own passes
would (JuliaSyntax's parser: 147,000 locals to 3,500). A raw module is not meant to run:
its large functions have frames of thousands of locals, which overflow the stack of a
recursive parser. What the code generator does avoid is code `wasm-opt` would have to
remove at a cost: without the rules of section 3, `wasm-opt` takes 13 times longer on the
parser (683 s against 53 s) for a worse module, and destination passing halved it again
(23 s). Most of its time is `simplify-locals` on the largest functions.

For the parser, a compile takes about 23 s in `wasm-opt`, 8 s in IRStructurizer, 3 s in
juliac's verifier and 2 s in the code generator (after Julia's inference, cached across
compilations). OrdinaryDiffEq's Tsit5 on the Lorenz system runs within about 1.5× of native
Julia in Node.js; a ModelingToolkit model and the parser run at about native speed.

Floating-point results are bit-identical to native Julia built for a CPU without FMA
(`-C generic`); natively on FMA hardware, `muladd` fuses, so results differ in the last
bits (and chaotic systems diverge from there). Relaxed SIMD's `relaxed_madd` could give
`muladd` native speed and rounding on most hardware, at the cost of determinism.

## 10. Testing

Differential (`@wtest f(args...)`): native and compiled results compared (values and
types), in a persistent Node.js from `NodeJS_24_jll`, inside one session of patches.
Coverage: numbers and control flow, 128-bit integers, pointers, identity, globals,
structs/vectors/closures/broadcast/sort, dictionaries and sets, Random (the native
streams), the image (tables, symbols, cycles, identity), exceptions (try/catch/finally,
rethrow, the exceptions of Base and of the code generator's checks), strings, Unicode and
printing found missing by sweeping WasmTarget.jl's catalogue of Base operations, and
JuliaC.jl's own test programs (reshape, dispatch, reductions, concatenations, printing;
the untrimmable one must be rejected). The tests run the optimized modules. The examples: `examples/lorenz`
(OrdinaryDiffEq), `examples/mtk` (a ModelingToolkit model), `examples/juliasyntax` (Julia's
parser, compared with native JuliaSyntax node for node on Base's sources), each with a page.
