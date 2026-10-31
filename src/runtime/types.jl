# Functions of types at run time (see `reflection.jl`): `map_type(f, T)` is `f(T)`, which
# the code generator compiles to a table of `f` over the types of the module.

@noinline map_type(f::F, @nospecialize(T)) where {F} = f(T)::Type
"`map_type_symbol(f, T)`: `f(T)`, a Symbol, from the same kind of table as `map_type`."
@noinline map_type_symbol(f::F, @nospecialize(T)) where {F} = f(T)::Symbol
"""
`map_type_value(f, T)`: `f(T)`, any object, from the same kind of table as `map_type`. `f` runs
only natively (on the module's types, when the code generator builds the table), so it is
not inferred from here: juliac's verifier skips this body (`collect.jl`, `twin_body`).
"""
@noinline map_type_value(f::F, @nospecialize(T)) where {F} = Base.inferencebarrier(f)(T)

# Showing functions and enums (`trim/wasm-base.jl`): which global names a value, and whether
# it is visible from the default module of `show`, decided by the bindings of the module's
# modules, known at compile time (the C runtime's bindings are not in the module).

"How `show` names a function of a type (`Base.show_function`), for `map_type_value`."
mutable struct FunctionShow   # (mutable: an object of the image; never mutated)
    fallback::Bool      # an anonymous function's type (shown by the fallback)
    name::Symbol        # the type's `singletonname`
    bound::Bool         # `name` names a constant of its module of this type: `value`
    value::Any
    mod::Module
    visible::Bool       # `isvisible(name, mod, Base.UsesBaseOnly)`
end
const NOT_A_FUNCTION = FunctionShow(true, :_, false, nothing, Base, false)
# (both in the latest world, the program's: the compiler's is older than its definitions;
# one object per type, as the tables of the module's types are built to a fixpoint)
function_show(@nospecialize(T)) = get!(() -> Base.invokelatest(_function_show, T)::FunctionShow, FUNCTION_SHOWS, T)
function _function_show(@nospecialize(T))
    (T isa DataType && T <: Function) || return NOT_A_FUNCTION
    tn = T.name
    tn.name === tn.singletonname && return NOT_A_FUNCTION
    sym = tn.singletonname
    if isdefined(tn, :module) && isdefinedglobal(tn.module, sym) && isconst(tn.module, sym)
        g = getglobal(tn.module, sym)
        if typeof(g) === T
            return FunctionShow(false, sym, true, g, tn.module, Base.isvisible(sym, tn.module, Base.UsesBaseOnly))
        end
    end
    return FunctionShow(false, sym, false, nothing, Base, false)
end

"How `show` names an enum's instances (`Base.show(::IO, ::Enum)`), for `map_type_value`."
mutable struct EnumShow       # (mutable: an object of the image; never mutated)
    def::Module
    names::Vector{Symbol}       # the instances' names (bindings of `def`)
    visible::Vector{Symbol}     # those visible from `Main` (`isvisible`)
end
const NOT_AN_ENUM = EnumShow(Base, Symbol[], Symbol[])
# (of the compilation: emptied when one starts, as bindings and their visibility change)
const FUNCTION_SHOWS = IdDict{Any,FunctionShow}()
const ENUM_SHOWS = IdDict{Any,EnumShow}()
enum_show(@nospecialize(T)) = get!(() -> Base.invokelatest(_enum_show, T)::EnumShow, ENUM_SHOWS, T)
function _enum_show(@nospecialize(T))
    (T isa DataType && T <: Enum && isconcretetype(T)) || return NOT_AN_ENUM
    def = parentmodule(T)
    names = Symbol[Symbol(x) for x in instances(T)]
    return EnumShow(def, names, Symbol[n for n in names if Base.isvisible(n, def, Main)])
end

"""
`simple_type_name(T)`: the name a type is printed with in a module (`show(io, ::Type)`,
`trim/wasm-base.jl`): its name and parameters, without modules (juliac's printing of types,
without reflection at run time: a table over the module's types, `map_type_symbol`).
"""
function simple_type_name(@nospecialize(T))
    io = IOBuffer()
    show_simple_type(io, T)
    return Symbol(String(take!(io)))
end

function show_simple_type_param(io::Base.IO, @nospecialize(p))
    if p isa Int
        show(io, p)
    elseif p isa Type
        show_simple_type(io, p)
    elseif p isa Symbol
        print(io, ":")
        print(io, p)
    elseif p isa TypeVar
        print(io, p.name)
    else
        print(io, "?")
    end
end
function show_simple_type(io::Base.IO, @nospecialize(T))
    if T isa DataType
        print(io, T.name.name)
        if T !== T.name.wrapper && length(T.parameters) > 0
            print(io, "{")
            first = true
            for p in T.parameters
                first || print(io, ", ")
                first = false
                show_simple_type_param(io, p)
            end
            print(io, "}")
        end
    elseif T isa Union
        print(io, "Union{")
        show_simple_type_param(io, T.a)
        print(io, ", ")
        show_simple_type_param(io, T.b)
        print(io, "}")
    elseif T isa UnionAll
        show_simple_type(io, T.body::Type)
        print(io, " where ")
        print(io, T.var.name)
    end
end

"What `typeinfo_eltype` gives where Base's is `nothing` (a table of a function of types holds types)."
struct NoEltype end
"`Base.typeinfo_eltype(T)`, `NoEltype` for `nothing`: the element type a context of type `T` implies."
typeinfo_eltype(@nospecialize(T)) = (e = Base.typeinfo_eltype(T); e === nothing ? NoEltype : e::Type)

"The types of the fields of a `Pair` type `T` (`fieldtype(T, 1)`, `fieldtype(T, 2)`), for `show` of a pair in a context of `T`; `Any` for other types."
# (total: `map_type` computes them for every type of the module, `Union{}` among them, which is
# `<: Pair` but has no fields; a context of `Union{}` holds no pair)
pair_first_type(@nospecialize(T)) = T isa Type && T !== Union{} && T <: Pair ? fieldtype(T, 1) : Any
pair_second_type(@nospecialize(T)) = T isa Type && T !== Union{} && T <: Pair ? fieldtype(T, 2) : Any

"The type a value shown in a context of `typeinfo` `T` is printed as (`nonnothing_nonmissing_typeinfo`)."
nonnothing_nonmissing(@nospecialize(T)) = T isa Type ? Base.nonmissingtype(Base.nonnothingtype(T)) : Any

"""
    tuple_as(x, C)

The tuple `x` of a type of unknown length as an object of the concrete tuple type `C`, if it
is one, else `nothing`: a case of the conversion of a tuple to an object (`tuple_canon_func!`).
"""
@noinline function tuple_as(x, ::Type{C}) where {C}
    r = Ref{Any}(nothing)
    x isa C && (r[] = x::C)
    return r[]
end

"""
    tuple_any(x)

The tuple `x` of a type of unknown length as a `Tuple` (its elements as objects): the object
it is where the module does not have its concrete type (see `tuple_canon_func!`).
"""
@noinline tuple_any(x) = Ref{Tuple}(x)[]

"""
    tuple_from(x, C, S)

The tuple object `x`, of the tuple type `C` (concrete, or `Tuple`), as a value of the tuple
type of unknown length `S`: a case of the conversion of an object to such a tuple
(`tuple_from_func!`). (The types by `Val`s: a `Type` of an abstract one is not a constant of
the code.)
"""
@noinline tuple_from(@nospecialize(x), ::Val{C}, ::Val{S}) where {C,S} = Ref{S}(x::C)[]

"""
    tuple_objectid(x, S)

`objectid` of the tuple `x`, of a type the module does not have, an object of `S` (`Tuple`,
see `tuple_canon_func!`): of its elements, as of a tuple of a known type, from `S`'s id for
that type's hash.
"""
@noinline function tuple_objectid(@nospecialize(x), ::Val{S}) where {S}
    t = x::S
    h = objectid(S)
    for i in 1:length(t)
        h = bitmix(h, objectid(t[i]))
    end
    return h
end

"""
    types_equal(a, b)

`jl_types_equal(a, b)`: whether the types `a` and `b` are equal, as subtypes of each other
(`<:` of the module's types is a table, see `reflection.jl`). `Vararg`s, which are not types,
are equal as the C runtime compares them: of the same length (or both of no length) and of
the same element type (`===`; a bare `Vararg`'s is `Any`). A `Vararg` and a type are not.
(The C runtime also finds `Vararg`s equal whose element types differ only in the names of
type variables, `Vararg{Tuple{T,T} where T}` and `Vararg{Tuple{S,S} where S}`: here they are
not, as the fields of type objects are not read at run time.)
"""
function types_equal(@nospecialize(a), @nospecialize(b))
    a === b && return Int32(1)
    if a isa Core.TypeofVararg || b isa Core.TypeofVararg
        a isa Core.TypeofVararg || return Int32(0)
        b isa Core.TypeofVararg || return Int32(0)
        va, vb = a::Core.TypeofVararg, b::Core.TypeofVararg
        isdefined(va, :N) == isdefined(vb, :N) || return Int32(0)
        isdefined(va, :N) && !(getfield(va, :N) === getfield(vb, :N)) && return Int32(0)
        Ta = isdefined(va, :T) ? getfield(va, :T) : Any
        Tb = isdefined(vb, :T) ? getfield(vb, :T) : Any
        return Int32(Ta === Tb)
    end
    return Int32(((a <: b)::Bool && (b <: a)::Bool)::Bool)
end

"""
The error of `typeof` of a tuple whose concrete type is not one of the module's (see
`reflection.jl`). (Julia's `typeof` does not throw, so inference may have removed the
handlers around it: the message is also written to `Core.stderr` before the error.)
"""
@noinline function throw_typeof_unknown()
    msg = "WasmCodegen: typeof of a tuple whose concrete type the module does not have (no types are made at run time)"
    Core.println(Core.stderr, msg)
    error(msg)
end
