# Calls of C libraries, `ccall((:sym, lib), ...)`. Each is a Wasm import of the module
# `c:<library>`, and which C code provides it is not the compiler's business: `requirements`
# lists what a module imports, for a linker to resolve. No option selects this.
#
# Only numbers cross. Linear memory is not where Julia's objects are, so a C function that takes
# or returns a pointer cannot see them; such a call is unsupported, reported by the name of the
# function. An `i64` is a C `long` or `size_t`, as Julia's own `Clong` and `Csize_t` are.

"The libraries whose functions the runtime implements, by name (`RUNTIME_CCALLS`)."
const RUNTIME_LIBRARIES = ("libblastrampoline", "libjulia", "libjulia-internal", "libjulia-codegen",
                           "libjulia-debug", "libjulia-internal-debug", "libjulia-codegen-debug")

const C_SCALARS = (Int32, UInt32, Int64, UInt64, Float32, Float64)

"""
    CRequirement

A function of a C library a module imports: of the library `library` (the name of its file,
without directory or extensions), which the Julia package `package` provides if the program named
it through a binding of that package, the function `symbol`, of the declared types.
"""
struct CRequirement
    library::String
    package::Union{Nothing,Base.PkgId}
    symbol::String
    rettype::Any
    argtypes::Vector{Any}
end

import_module(r::CRequirement) = "c:" * r.library

function library_name(@nospecialize(l))
    l isa Base.Libc.Libdl.LazyLibrary && (l = string(l.path))
    (l isa String || l isa Symbol) || return nothing
    return String(first(split(basename(String(l)), '.')))
end

"""
    c_library(fc, target) -> Union{Nothing,Tuple}

`(library, package, symbol)` of the foreign call target `target` if it calls a C library, else
nothing. The library is read in the program's world, where a JLL's non-constant binding has the
value its `__init__` gave it in the build process. A library computed at run time is not one
this finds, nor one the runtime implements; nor are functions `foreigncall_hint` explains.
"""
function c_library(fc::FnCtx, @nospecialize(target))
    sym, l = foreigncall_parts(target)
    (sym isa Symbol || sym isa String) || return nothing
    package = nothing
    if l isa GlobalRef
        world = fc.cgm.world.world
        Base.invoke_in_world(world, isdefinedglobal, l.mod, l.name) || return nothing
        id = Base.PkgId(l.mod)
        id.uuid === nothing || (package = id)
        l = Base.invoke_in_world(world, getglobal, l.mod, l.name)
        l isa Base.Libc.Libdl.LazyLibrary && (l = Base.invoke_in_world(world, string, l.path))
    end
    lib = library_name(l)
    (lib === nothing || lib in RUNTIME_LIBRARIES) && return nothing
    name = Symbol(sym)
    lib in IMPORT_LIBRARIES && return nothing
    isempty(foreigncall_hint(name)) || return nothing
    return (lib, package, name)
end

is_c_pointer(@nospecialize(T)) = T === Any || is_ptr_type(T) || (T isa Type && T <: Ref)

function check_c_scalar(lib::String, name::Symbol, @nospecialize(T))
    T in C_SCALARS && return
    is_c_pointer(T) && unsupported("the C function ", name, " of ", lib, ": a pointer in its signature (", T,
                                   "). Only numbers cross to C libraries")
    unsupported("the C function ", name, " of ", lib, ": the type ", T, " in its signature. Only 32- and ",
                "64-bit integers and floats cross to C libraries")
end

"`ccall((name, lib), RT, (ArgT...), args...)` of a C library: a call of the Wasm import `c:lib.name`."
function emit_c_ccall!(fc::FnCtx, lib::String, package, name::Symbol, ex::Expr, args::Vector{Any})
    ex.args[4] == 0 || unsupported("the C function ", name, " of ", lib, ": a variadic call")
    cc = ex.args[5]
    cc isa QuoteNode && (cc = cc.value)
    cc isa Tuple && !isempty(cc) && (cc = cc[1])
    cc === :ccall || cc === :cdecl ||
        unsupported("the C function ", name, " of ", lib, ": the calling convention ", cc)
    RT = ex.args[2]
    ATs = ex.args[3]::Core.SimpleVector
    RT === Cvoid || check_c_scalar(lib, name, RT)
    foreach(T -> check_c_scalar(lib, name, T), ATs)
    reqs = get!(() -> Dict{Tuple{String,String},CRequirement}(), fc.cgm.helpers, :c_requirements)
    r = get!(reqs, (lib, String(name))) do
        CRequirement(lib, package, String(name), RT, collect(Any, ATs))
    end
    (r.rettype === RT && r.argtypes == collect(Any, ATs)) ||
        unsupported("the C function ", name, " of ", lib, ": declared as both ", Tuple(r.argtypes), " -> ", r.rettype,
                    " and ", ATs, " -> ", RT)
    return call_scalar_import!(fc, import_module(r), name, RT, ATs, args)
end
