# Functions of types at run time (see `reflection.jl`): `map_type(f, T)` is `f(T)`, which
# the code generator compiles to a table of `f` over the types of the module.

@noinline map_type(f::F, @nospecialize(T)) where {F} = f(T)::Type
"`map_type_symbol(f, T)`: `f(T)`, a Symbol, from the same kind of table as `map_type`."
@noinline map_type_symbol(f::F, @nospecialize(T)) where {F} = f(T)::Symbol
"""
`map_type_value(f, T)`: `f(T)`, any object, from the same kind of table as `map_type`. `f` runs
only natively (on the module's types, when the code generator builds the table), so it is
not inferred from here: juliac's verifier skips this body (`collect.jl`, `compile_time_instance`).
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

"The C runtime's hash of a type, for `map_type_value` (see `type_hash`)."
mutable struct TypeHash   # (mutable: an object of the image; never mutated)
    h::UInt
end
"""
`type_hash(T)`: the C runtime's hash of a type (`jl_type_hash`, Base's `_jl_type_hash`), for
`map_type_value`: computed natively for the module's types, when the code generator builds the
table, so `hash(::Type)` gives the native values in Wasm. (A new object each time, without a
cache: natively, in a session of patches, any task's `hash(::Type)` calls it; the code
generator keeps one per type, `map_value!`.)
"""
type_hash(@nospecialize(T)) = TypeHash(ccall(:jl_type_hash, UInt, (Any,), T))

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

"""
    by_type(f, x, y) -> Bool

`f(x, y, typeof(x))` for the type of `x`, if the module has a case of `f` for it: the code
generator compiles `f(x, y, T)` for each type `T` of the module `f` is for (`BY_TYPE_CASES`), and
calls the one of the type of `x` (`false` if none). The call of a function of a value of a type
not known at compile time that a closed world can make, by its type. Natively, `false`.
"""
@noinline by_type(f::F, @nospecialize(x), @nospecialize(y)) where {F} = (NO_BY_TYPE[] = x; NO_CASE[])
const NO_BY_TYPE = Ref{Any}(nothing)
# (read through a global, so that inference does not fold the result into the callers)
const NO_CASE = Ref(false)

"""
    getfield_as(x, Val(S), Val(f))

`getfield(x, f)` of `x`, an `S`, as `Any`: the case of `S` of `getfield` of a value whose type
is not concrete (abstract, a `Union`, a `UnionAll`), which natively the `getfield` builtin
finds by the value's type at run time (see `getfield_any_func!`). Its errors are the native
ones: a `FieldError` for a name `S` has no field of, a `BoundsError` for an index out of its
fields, an `UndefRefError` for a field not defined. (`S` in a `Val`, so that the case's only
parameter is `x`: `Type{S}` is not a ghost for every `S`.)
"""
getfield_as(@nospecialize(x), ::Val{S}, ::Val{f}) where {S,f} = Base.inferencebarrier(getfield(x::S, f))
# a tuple whose concrete type the module does not have (an object of `Tuple`): no field has a
# name (natively a FieldError of its concrete type, which the module does not have: of `Tuple`)
getfield_as(@nospecialize(x), ::Val{Tuple}, ::Val{f}) where {f} =
    f isa Symbol ? throw(FieldError(Tuple, f)) : Base.inferencebarrier(getfield(x::Tuple, f))

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

## `Core.apply_type` and `new` of types known only at run time (see `reflection.jl`)

"""
    new_as(C, x1, …, xn)

`new(C, x1, …, xn)` of fields of any type, as `jl_new_structv` does natively: each field is
checked (`TypeError(:new, "", fieldtype, value)`, the first that does not fit), then the
object is built (as an `Any`). A case of `new` of a type known only at run time, compiled for
each concrete type of the module it may be (`add_new_cases!`, `emit_new_rt!`).
"""
function new_as end

# (the generated body: checks in field order, then `new` of the checked values)
function new_as_body(@nospecialize(C), n::Int)
    xs = [Symbol(:x, i) for i in 1:n]
    body = Expr(:block)
    for i in 1:n
        FT = fieldtype(C, i)
        push!(body.args, :($(xs[i]) isa $FT || throw(TypeError(:new, "", $FT, $(xs[i])))))
    end
    push!(body.args, :(return Base.inferencebarrier($(Expr(:new, C, (:($(xs[i])::$(fieldtype(C, i))) for i in 1:n)...)))))
    return body
end

"The most fields `new` of a type known only at run time is compiled for."
const MAX_NEW_FIELDS = 16
for n in 0:MAX_NEW_FIELDS
    xs = [Symbol(:x, i) for i in 1:n]
    @eval @generated function new_as(::Type{C}, $(xs...)) where {C}
        return new_as_body(C, $n)
    end
end

"""
The error of `new(T, …)` of a type known only at run time that is not a concrete type of the
module with that many fields: natively the `TypeError` of a type that is not a concrete
`DataType` (and the same for a type the module does not have, which no value of it can need).
"""
@noinline throw_new_not_concrete(@nospecialize(T)) = throw(TypeError(:new, "", DataType, T))

"""
The error of `Core.apply_type(W, …)` whose result is not one of the module's types (`msg`
names `W`): the closed-world limit, not a native error. The application is valid (natively's
errors of one that is not come before it, `apply_type_check`), but types are not made at run
time: the module has the types its code names.
"""
# (`apply_type` does not throw for inference, which may have removed the handlers around it:
# the message is also written to `Core.stderr`, as `throw_typeof_unknown`'s)
@noinline function throw_apply_type_unknown(msg::String)
    Core.println(Core.stderr, "WasmCodegen: ", msg)
    error(msg)
end

"The error of `new(T, …)` of a concrete type `T` with a number of fields it cannot have."
@noinline throw_invalid_struct_allocation() = error("invalid struct allocation")

"""
The error of `new(T, …)` of a type known only at run time that is a concrete type the module
compiled no case of `new` for: the closed-world limit (the type was not among the module's
when its cases were compiled, or `new` of it is not supported: `String`, `Memory`, …), not a
native error.
"""
@noinline throw_new_closed_world() = error(string(
    "WasmCodegen: closed-world limit: `new` of a type known only at run time that this module ",
    "compiled no constructor case for (not among its types when the cases were compiled, or ",
    "one `new` is not supported for)"))

"""
The error of `Core.apply_type(Tuple, …)` of a last parameter that is a `Vararg`, which changes
the number of parameters (`Tuple{Int, Vararg{Int,2}}` is `Tuple{Int,Int,Int}`): not supported.
"""
@noinline function throw_apply_type_vararg()
    msg = string("WasmCodegen: Core.apply_type(Tuple, …) of a Vararg last parameter is not supported ",
                 "(it changes the number of parameters, known only at run time)")
    Core.println(Core.stderr, msg)
    error(msg)
end

## the errors of `Core.apply_type` of parameters known only at run time (`jl_f_apply_type`,
## `jl_apply_type`, `check_datatype_parameters`): checked where the parameters are not those of
## one of the module's instantiations, before the closed world's error (see `reflection.jl`)

"""
    valid_param_kind(T) -> Symbol

`:valid` if the values of the type `T` may be parameters of types, else `:invalid`
(`jl_valid_type_param`, which depends only on the value's type): a function of types, for a
table over the module's types (`map_type_symbol`).
"""
function valid_param_kind(@nospecialize(T))
    T isa DataType || return :invalid
    (T.name === Tuple.name || T.name === NamedTuple.body.body.name) &&
        return nestable_type_param(T) ? :valid : :invalid
    T === Core.TypeofVararg && return :invalid
    return T <: Type || T === TypeVar || T === Symbol || T === Module || isbitstype(T) ? :valid : :invalid
end

# `is_nestable_type_param`: a tuple or named tuple type whose values may be type parameters
function nestable_type_param(@nospecialize(t))
    t isa DataType && t.name === NamedTuple.body.body.name && (t = t.parameters[2])
    (t isa DataType && t.name === Tuple.name) || return false
    for p in t.parameters
        (p === Symbol || (p isa DataType && isbitstype(p)) || nestable_type_param(p)) || return false
    end
    return true
end

"`jl_valid_type_param`: whether `p` may be a parameter of a type."
valid_type_param(@nospecialize(p)) = map_type_symbol(valid_param_kind, typeof(p)) === :valid

"`within_typevar`: whether `p` is within the bounds `lb`, `ub` of a type variable."
within_typevar(@nospecialize(p), @nospecialize(lb), @nospecialize(ub)) =
    p isa TypeVar || (p isa Type ? (lb <: p && p <: ub) : (lb === Union{} && ub === Any))

# `jl_type_error_rt`: the `TypeError` of `func` (in `context`), whose `expected` may be a
# `TypeVar`, as the C runtime builds it, without `new`'s check of the field's type `Type` (run
# in the module only; `expected` hidden from inference, which would find that `new` throws)
@eval type_error_rt(func::Symbol, context::String, @nospecialize(expected), @nospecialize(got)) =
    $(Expr(:new, TypeError, :func, :context, :(Base.inferencebarrier(expected)), :got))

# the checks of `jl_f_apply_type(W, ps...)`: that each parameter may be one, in order
function apply_type_valid_body(@nospecialize(W), ps)
    body = Expr(:block)
    n = length(ps)
    for (i, p) in enumerate(ps)
        if W === Tuple
            push!(body.args, :(if $p isa Core.TypeofVararg
                                   $(i == n ? :(throw_apply_type_vararg()) : :(throw(TypeError(:Tuple, "non-final parameter", Type, $p))))
                               elseif !valid_type_param($p)
                                   throw(TypeError(:Tuple, "parameter", Type, $p))
                               end))
        else
            push!(body.args, :(valid_type_param($p) ||
                               throw(TypeError(:Type, "parameter", $p isa Number ? Int : Type, $p))))
        end
    end
    push!(body.args, :(return nothing))
    return body
end

"""
    apply_type_bounds(W, n) -> Vector{Tuple{Int,Symbol,TypeVar}}

The bounds `jl_apply_type(W, ps...)` checks, in order, as (the parameter's index, the
function the `TypeError` names, the variable): of `W`'s variables, then (of an alias of a
type, not its wrapper) of the parameters of the type it makes (`check_datatype_parameters`).
A bound that depends on an earlier variable is not checked (that needs the type made of the
earlier parameters): an application outside it is the closed world's error.
"""
function apply_type_bounds(@nospecialize(W), n::Int)
    checks = Tuple{Int,Symbol,TypeVar}[]
    W === Tuple && return checks
    vars = TypeVar[]
    w = W
    while w isa UnionAll
        push!(vars, w.var)
        w = w.body
    end
    D = w
    fixed(v::TypeVar) = !Base.has_free_typevars(v.lb) && !Base.has_free_typevars(v.ub)
    if D isa DataType && W === D.name.wrapper
        for (i, v) in enumerate(vars)
            i <= n && fixed(v) && push!(checks, (i, D.name.name, v))
        end
        return checks
    end
    for (i, v) in enumerate(vars)
        i <= n && fixed(v) && push!(checks, (i, D isa DataType ? D.name.name : :Type, v))
    end
    if D isa DataType && D.name !== Tuple.name
        wvars = TypeVar[]
        w = D.name.wrapper
        while w isa UnionAll
            push!(wvars, w.var)
            w = w.body
        end
        for (j, e) in enumerate(D.parameters)
            i = findfirst(v -> v === e, vars)
            (i === nothing || i > n || j > length(wvars)) && continue
            fixed(wvars[j]) && push!(checks, (i, D.name.name, wvars[j]))
        end
    end
    return checks
end

# the checks of `jl_f_apply_type`, then the bounds of `jl_apply_type` (`apply_type_bounds`);
# of `Tuple`, then `inst_datatype_inner`'s of a `Union{}` element; of more parameters than `W`
# has variables, `jl_apply_type`'s error once past them (no bound of theirs is checked natively:
# a wrapper's are left to `check_datatype_parameters`, which is not reached)
function apply_type_check_body(@nospecialize(W), ps)
    body = apply_type_valid_body(W, ps)
    pop!(body.args)
    if W === Tuple
        for p in ps
            push!(body.args, :($p === Union{} && error("Tuple field type cannot be Union{}")))
        end
        push!(body.args, :(return nothing))
        return body
    end
    U = Base.unwrap_unionall(W)
    vars = TypeVar[]
    w = W
    while w isa UnionAll
        push!(vars, w.var); w = w.body
    end
    if length(ps) > length(vars)
        # (natively the loop of `jl_apply_type`: each variable's bound as it instantiates, but a
        # wrapper's first, left to `check_datatype_parameters`, which is not reached)
        for (i, f, v) in apply_type_bounds(W, length(vars))
            (v === vars[i] && !(i == 1 && U isa DataType && W === U.name.wrapper)) || continue
            p = ps[i]
            push!(body.args, :(within_typevar($p, $(QuoteNode(v.lb)), $(QuoteNode(v.ub))) ||
                               throw(type_error_rt($(QuoteNode(f)), $(String(v.name)), $(QuoteNode(v)), $p))))
        end
        push!(body.args, :(error($(string("too many parameters for type ", U isa DataType ? String(U.name.name) : "")))))
        return body
    end
    for (i, f, v) in apply_type_bounds(W, length(ps))
        p = ps[i]
        push!(body.args, :(within_typevar($p, $(QuoteNode(v.lb)), $(QuoteNode(v.ub))) ||
                           throw(type_error_rt($(QuoteNode(f)), $(String(v.name)), $(QuoteNode(v)), $p))))
    end
    push!(body.args, :(return nothing))
    return body
end

"The most parameters `Core.apply_type` of parameters known only at run time is compiled for."
const MAX_APPLY_PARAMS = 16

"""
    apply_type_check(Val(W), ps...)

The errors of `Core.apply_type(W, ps...)` natively: of parameters that may not be ones, and
outside the bounds of `W`'s variables (`apply_type_bounds`); else `nothing`. Compiled for each
`W` the module applies at run time (`emit_apply_type!`), and called where the parameters are
not those of one of the module's instantiations, before the closed world's error.
"""
function apply_type_check end
for n in 0:MAX_APPLY_PARAMS
    ps = Tuple(Symbol(:p, i) for i in 1:n)
    @eval @generated function apply_type_check(::Val{W}, $(ps...)) where {W}
        return apply_type_check_body(W, $ps)
    end
end
