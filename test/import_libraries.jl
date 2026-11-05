# Libraries of host imports a program declares (`Config(import_libraries)`, src/foreigncall.jl):
# a `ccall` of one is a call of the Wasm import `lib.name`, which a host of the program's own
# provides; other libraries are C libraries as before (unsupported), and the names of
# WasmCodegen's own imports cannot be declared.

implib_add(x::Int32, y::Int64) = ccall((:add, "implib_test"), Int64, (Int32, Int64), x, y)
implib_note(x::UInt32) = (ccall((:note, "implib_test"), Cvoid, (UInt32,), x); x + UInt32(1))
implib_both(x::Int32) = implib_add(x, Int64(1)) + ccall((:twice, "implib_other"), UInt64, (UInt64,), UInt64(x))
implib_float(x::Float64) = ccall((:half, "implib_test"), Float64, (Float64,), x)

import_list(c) = sort!([(f.imported[1], f.imported[2], f.params, f.results)
                        for f in c.cgm.mod.funcs if f.imported !== nothing &&
                            f.imported[1] != "wasi_snapshot_preview1"]; by = x -> (x[1], x[2]))

# run `fn(args...)` of a WASI module with Node, the declared libraries given as JavaScript
# (`libs`: the source of an object of import modules), WASI's functions as stubs that do
# nothing: (result as a string, the host's log)
function run_import_libraries(c, fn, libs, args...)
    dir = mktempdir()
    write(joinpath(dir, "m.wasm"), c.bytes)
    write(joinpath(dir, "run.mjs"), """
    import fs from 'node:fs';
    const log = [];
    const libs = $libs;
    const mod = new WebAssembly.Module(fs.readFileSync('$(joinpath(dir, "m.wasm"))'));
    const imports = { ...libs, wasi_snapshot_preview1: {} };
    for (const i of WebAssembly.Module.imports(mod))
      if (i.module === 'wasi_snapshot_preview1') imports.wasi_snapshot_preview1[i.name] = () => 0;
    const instance = await WebAssembly.instantiate(mod, imports);
    instance.exports._initialize?.();
    const r = instance.exports.$fn($(join((a isa Union{Int64,UInt64} ? "$(a)n" : string(a) for a in args), ", ")));
    process.stdout.write(JSON.stringify({ r: String(r), log }));
    """)
    resp = JSON.parse(read(`$(node_cmd()) $(joinpath(dir, "run.mjs"))`, String))
    return String(resp["r"]), String[x for x in resp["log"]]
end

@testset "import libraries" begin
    wasi(; kw...) = WasmCodegen.Config(; host = :wasi, kw...)
    # a ccall of a declared library: the import lib.name, of the ccall's Wasm types
    add = WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(import_libraries = ["implib_test"]))
    @test import_list(add) == [("implib_test", "add", ValType[I32, I64], ValType[I64])]
    lib = "{ implib_test: { add: (x, y) => { log.push(`add \${x} \${y}`); return BigInt(x) + y; } } }"
    @test run_import_libraries(add, "implib_add", lib, Int32(40), Int64(2)) == ("42", ["add 40 2"])
    # no result (Cvoid), an unsigned argument
    note = WasmCodegen.compile(implib_note, (UInt32,); config = wasi(import_libraries = ["implib_test"]))
    @test import_list(note) == [("implib_test", "note", ValType[I32], ValType[])]
    lib = "{ implib_test: { note: (x) => { log.push(`note \${x >>> 0}`); } } }"
    @test run_import_libraries(note, "implib_note", lib, UInt32(7)) == ("8", ["note 7"])
    # several libraries, each its own import module
    both = WasmCodegen.compile(implib_both, (Int32,); config = wasi(import_libraries = ["implib_test", "implib_other"]))
    @test import_list(both) == [("implib_other", "twice", ValType[I64], ValType[I64]),
                                ("implib_test", "add", ValType[I32, I64], ValType[I64])]
    lib = "{ implib_test: { add: (x, y) => BigInt(x) + y }, implib_other: { twice: (x) => 2n * x } }"
    @test run_import_libraries(both, "implib_both", lib, Int32(5)) == ("16", String[])

    # a library not declared is a C library, as before: unsupported
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi())
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_add, (Int32, Int64);
                                                                       config = wasi(import_libraries = ["implib_other"]))
    # (with trim = :unsafe, a trap where it is, reported in the diagnostics)
    c = WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(trim = :unsafe, on_unsupported = :trap))
    @test isempty(import_list(c)) && length(c.cgm.diagnostics) == 1
    # types other than 32- and 64-bit integers
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(implib_float, (Float64,);
                                                                       config = wasi(import_libraries = ["implib_test"]))

    # the names of WasmCodegen's own imports cannot be declared
    for name in ("wasi_snapshot_preview1", "julia", "julia_io", "julia_anything", "")
        @test_throws ArgumentError WasmCodegen.compile(implib_add, (Int32, Int64); config = wasi(import_libraries = [name]))
    end
    # nor libraries for another host than WASI
    @test_throws ArgumentError WasmCodegen.compile(implib_add, (Int32, Int64);
                                                   config = WasmCodegen.Config(host = :js, import_libraries = ["implib_test"]))
    # (an empty list changes nothing for either host)
    for host in (:js, :wasi)
        c = WasmCodegen.compile(implib_note, (UInt32,); config = WasmCodegen.Config(; host, trim = :unsafe, on_unsupported = :trap))
        @test isempty(import_list(c))
    end
end
