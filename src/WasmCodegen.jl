"""
    WasmCodegen

A compiler of Julia programs to WebAssembly (with the GC proposal), working like juliac:
from entry points, the closed world of code they run is collected with Julia's own
inference, structured (IRStructurizer.jl), compiled to Wasm (WasmBuilder.jl), and the
objects it refers to are serialized into the module.
"""
module WasmCodegen

using WasmBuilder
using WasmBuilder: Inst, Func, Global, WModule, TypeRef, RefType, ValType, StorageType,
                   PackedType, FieldType, StructType, ArrayType, SubType, Builder, emit!,
                   typedef, is_unreachable
import IRStructurizer
import Binaryen_jll
using IRStructurizer: StructuredIRCode

const CC = Base.Compiler

include("errors.jl")

"Functions the code generator calls for what Wasm lacks, compiled into the module on demand."
module Runtime
include("runtime/int128.jl")
include("runtime/io.jl")
include("runtime/pointers.jl")
include("runtime/reinterpret.jl")
include("runtime/hash.jl")
include("runtime/unicode.jl")
include("runtime/floats.jl")
include("runtime/float16.jl")
include("runtime/errors.jl")
include("runtime/types.jl")
include("runtime/eqtable.jl")
include("runtime/blas.jl")
include("runtime/lapack.jl")
include("runtime/fwrappers.jl")
end
include("interpreter.jl")
include("collect.jl")
include("prepare.jl")
include("layout.jl")
include("values.jl")
include("context.jl")
include("emit.jl")
include("exceptions.jl")
include("reflection.jl")
include("builtins.jl")
include("memory.jl")
include("outline.jl")
include("intrinsics.jl")
include("intrinsics128.jl")
include("foreigncall.jl")
include("pointers.jl")
include("image.jl")
include("overlays.jl")
include("types_runtime.jl")
include("patches.jl")
include("driver.jl")
include("precompile.jl")

export compile, Entry, Config, UnsupportedConstructs

function __init__()
    COMPILER_WORLD[] = Base.get_world_counter()
end

end
