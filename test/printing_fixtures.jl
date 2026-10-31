# The fixtures of test/printing.jl and their results natively, computed here, before the trim
# patches, with Base's own printing. Printing in a closed world (trim/wasm-base.jl,
# wasm-show.jl, wasm-runtime.jl): types known
# only at run time (through a table of the module's types), enums and functions (their
# module prefixes: the bindings' visibility, computed at compile time), values shown in the
# context of their type (`:typeinfo`), and `print`/`string` of many arguments.

# (an enum with an instance visible from Main, and a function so)
@eval Main module PrintVisible
export pv_shown, pv_f
@enum PVE pv_shown pv_hidden
pv_f() = 1
end
@eval Main using .PrintVisible

module PrintingTests

using Test

module Outer
module Inner
struct T; x::Int; end
end
end

# types known only at run time
const TYPES = Any[Int, Vector{String}, Dict{String,Int}, Union{Nothing,Int}, Outer.Inner.T, Pair{Symbol,Any}]
type_str(i::Int) = (io = IOBuffer(); show(io, TYPES[i]::Type); s = String(take!(io)); (sizeof(s), hash(s)))

# enums and functions
@enum Fruit apple banana
const ENUMS = Any[apple, banana, Base.MPFR.MPFRRoundNearest, Main.PrintVisible.pv_shown, Main.PrintVisible.pv_hidden]
const FUNCS = Function[push!, Base.Iterators.filter, type_str, Main.PrintVisible.pv_f, sort!, Base.Filesystem.joinpath, +]
shown(x) = (io = IOBuffer(); show(io, x); s = String(take!(io)); (sizeof(s), hash(s)))
enum_shown(i::Int) = (x = ENUMS[i]; x isa Fruit ? shown(x) : x isa Base.MPFR.MPFRRoundingMode ? shown(x) : shown(x::Main.PrintVisible.PVE))
fruit_shown(i::Int) = shown((apple, banana)[i])   # (the enum's type known at compile time)
# (a function of a type not known at compile time, with a fallback other than show_default)
fallback_show(io::IO, @nospecialize(f)) = print(io, "?")
func_str(i::Int, compact::Bool) = (io = IOBuffer(); Base.show_function(io, FUNCS[i], compact, fallback_show);
                                   s = String(take!(io)); (sizeof(s), hash(s)))
func_shown(i::Int) = func_str(i, false)
func_printed(i::Int) = func_str(i, true)

# values shown in the context of their type: a Set{String}, a Dict{String,Float64}
# (Pair{String,Float64}), nested Dicts, a Pair in a context of another Pair type
@noinline pt_names(n::Int) = n > 1 ? Set(["a", "b"]) : Set(["c"])
@noinline pt_values(n::Int) = n > 1 ? Dict("A" => 1.5, "B" => -2.0) : Dict("C" => 0.25)
@noinline pt_nested(n::Int) = Dict("x" => Dict("y" => n), "z" => Dict{String,Int}())
function show_typeinfo(io::IO, n::Int)
    print(io, string("urls: ", pt_names(n)), '\n')
    print(io, string("values: ", pt_values(n)), '\n')
    print(io, pt_nested(n), '\n')
    show(io, "x" => 1.0); println(io)
    show(IOContext(io, :typeinfo => Pair{String,Float64}), "y" => 2.0); println(io)
    show(IOContext(io, :typeinfo => Pair{Any,Any}), "z" => n); println(io)
    show(IOContext(io, :typeinfo => Pair{String,Int}), "w" => 1 => 2); println(io)
end
show_typeinfo_wasm(n::Int) = (show_typeinfo(Core.stdout, n); Int32(0))

# print and string of more arguments than Base specializes on (32 here)
many(n::Int) = (s = string("a", n, "b", n + 1, "c", n + 2, "d", n + 3, "e", n + 4, "f", n + 5, "g", n + 6); (sizeof(s), hash(s)))

# (natively, with Base's printing: the references)
const REFS = Dict{Any,Any}()
for i in 1:length(ENUMS); REFS[(:enum_shown, i)] = enum_shown(i); end
for i in 1:2; REFS[(:fruit_shown, i)] = fruit_shown(i); end
for i in 1:length(FUNCS); REFS[(:func_shown, i)] = func_shown(i); REFS[(:func_printed, i)] = func_printed(i); end
for n in (1, 2); REFS[(:show_typeinfo, n)] = sprint(show_typeinfo, n); end
REFS[(:many, 3)] = many(3)
# (an invalid value of an enum: Base prefixes its module)
const INVALID = reinterpret(Fruit, Int32(17))
invalid_shown() = shown(INVALID)
REFS[(:invalid_shown,)] = invalid_shown()

end
