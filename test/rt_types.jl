# `Core.apply_type` and `new` of types known only at run time (`reflection.jl`): the builtins at
# run time over the module's types. Native results where the module has the type; the errors
# native code gives for invalid applications; and the closed-world limits, which are told apart
# from them (a type the module was not compiled with, the shapes it does not support).

module RTTypes

struct Box{T}; x::T; end
mutable struct MBox{T}; x::T; end
struct Empty end
primitive type Odd24 24 end   # (a primitive type of 3 bytes: not supported)

# (a TypeError's context, of a declared type of several)
ctx_is(e::TypeError, s::String) = (c = e.context; c isa String && c == s)
msg_is(e::ErrorException, s::String) = (m = e.msg; m isa String && m == s)
msg_has(e::ErrorException, s::String) = (m = e.msg; m isa String && occursin(s, m))

# a `new` that always throws (a field of type `Union{}`) among the cases: native field error
@noinline boxtype3(i::Int) = i == 1 ? Box{Int} : i == 2 ? Box{Float64} : Box{Union{}}
@generated newbottom(i::Int, x::Int) = Expr(:new, :(boxtype3(i)), :x)
function newbottom_caught(i::Int, x::Int)
    try
        b = newbottom(i, x)
        return b isa Box{Int} ? b.x : b isa Box{Float64} ? -1 : -4
    catch e
        # (the whole TypeError: function, context, expected type and value)
        return e isa TypeError && e.func === :new && ctx_is(e, "") && e.got === x ?
            (e.expected === Union{} ? -2 : e.expected === Float64 ? -3 : -5) : -6
    end
end

# a bound inference gives (`Type{<:Box}`, of `apply_type` at run time) whose types have a
# constructor the module cannot compile: the program's error, as `trim = :safe` checks
const FIELDTYPES = Any[Int, Float64, Odd24]
@noinline oddtype(i::Int) = Box{FIELDTYPES[i]}
@generated newodd(i::Int, x::Int) = Expr(:new, :(oddtype(i)), :x)
oddname() = Box{Odd24}   # (named by the code: the module's type)
newodd_val(i::Int, x::Int) = (b = newodd(i, x); b isa Box{Int} ? 1 : b isa Box{Float64} ? 2 : typeof(b) === oddname() ? 3 : 4)
function newodd_caught(i::Int, x::Int)
    try
        newodd_val(i, x)
    catch e
        e isa TypeError && e.func === :new && e.expected === Float64 && e.got === x ? -1 : -2
    end
end

# `new` of the wrong number of fields: native "invalid struct allocation"
@noinline arity_type(flag::Bool) = flag ? Empty : Box{Int}
@generated newarity(flag::Bool) = Expr(:new, :(arity_type(flag)))
function newarity_caught(flag::Bool)
    try
        newarity(flag) isa Empty ? 1 : 2
    catch e
        e isa ErrorException && msg_is(e, "invalid struct allocation") ? -1 : -2
    end
end

# `new` does not convert (natively no `convert` is called): a field of another type is the
# TypeError, and a `convert` method with a side effect is not run
struct Conv; v::Int; end
const CONVERTED = Ref(0)
Base.convert(::Type{Conv}, x::Int) = (CONVERTED[] += 1; Conv(x))
@noinline convtype(flag::Bool) = flag ? Box{Conv} : Box{Int}
@generated newconv(flag::Bool, x::Int) = Expr(:new, :(convtype(flag)), :x)
function newconv_caught(flag::Bool, x::Int)
    CONVERTED[] = 0
    r = try
        b = newconv(flag, x)
        b isa Box{Int} ? b.x : -1
    catch e
        e isa TypeError && e.func === :new && e.expected === Conv && e.got === x ? -2 : -3
    end
    return (r, CONVERTED[])
end

# partial construction: an inline field holding references left out, of a type known only
# at run time (and of one known at compile time): undefined, as natively (`isdefined` false,
# reading it an UndefRefError), in mutable and immutable holders
struct Leaf; n::Int; s::String; end
mutable struct Holder{T}
    a::Int
    tail::T
    Holder{T}(a::Int) where {T} = new{T}(a)
    Holder{T}(a::Int, t) where {T} = new{T}(a, t)
end
struct ImmHolder{T}
    a::Int
    tail::T
    ImmHolder{T}(a::Int) where {T} = new{T}(a)
    ImmHolder{T}(a::Int, t) where {T} = new{T}(a, t)
end
function tail_of(h)
    d = isdefined(h, :tail)
    v = try
        t = h.tail
        t isa Leaf ? t.n + length(t.s) : Int(t)
    catch e
        e isa UndefRefError ? -1 : -2
    end
    return (h.a, d, v)
end
@noinline holdertype(i::Int) = i == 1 ? Holder{Leaf} : i == 2 ? Holder{Int} : ImmHolder{Leaf}
@generated newpartial(i::Int, a::Int) = Expr(:new, :(holdertype(i)), :a)
partial_rt(i::Int, a::Int) = tail_of(newpartial(i, a))
partial_mutable(a::Int) = tail_of(Holder{Leaf}(a))
partial_immutable(a::Int) = tail_of(ImmHolder{Leaf}(a))
full_immutable(a::Int) = tail_of(ImmHolder{Leaf}(a, Leaf(a, "xy")))
full_mutable(a::Int) = tail_of(Holder{Leaf}(a, Leaf(a, "xyz")))

# a `NamedTuple` type of names known only at run time, and `new` of it
@noinline names_of(flag::Bool) = flag ? (:a,) : (:b,)
nt_names(flag::Bool) = (T = NamedTuple{names_of(flag), Tuple{Int}}; T === NamedTuple{(:a,), Tuple{Int}} ? 1 : T === NamedTuple{(:b,), Tuple{Int}} ? 2 : 0)
@generated nt_new(flag::Bool, x::Int) = Expr(:new, :(NamedTuple{names_of(flag), Tuple{Int}}), :x)
nt_value(flag::Bool, x::Int) = (nt = nt_new(flag, x); nt isa NamedTuple{(:a,), Tuple{Int}} ? nt.a : nt isa NamedTuple{(:b,), Tuple{Int}} ? -nt.b : 0)

# type-cache equality: `Val{P}` and `Val{Q}` are one type natively where `P == Q` though not
# `P === Q` (type variables of other names; a `UnionAll` equal to a `DataType`)
const TT = Tuple{T,T} where T
const KEYS = Any[TT, Tuple{S,S} where S, Tuple{Vararg{Int}}, Tuple{Vararg{Int,N}} where N, Int]
valkey(i::Int) = (T = Val{KEYS[i]}; T === Val{TT} ? 1 : T === Val{Tuple{Vararg{Int}}} ? 2 : T === Val{Int} ? 3 : 0)

# invalid applications: the native errors (a parameter out of its bound, one that is not a
# valid parameter, too many parameters, a `Union{}` element of a tuple type)
struct Bounded{T<:Integer}; x::T; end
const PARAMS = Any[Int, String, 3, "a", Union{}, :s]
bounded(i::Int) = (T = Bounded{PARAMS[i]}; T === Bounded{Int} ? 1 : T === Bounded{Union{}} ? 2 : 0)
valparam(i::Int) = (T = Val{PARAMS[i]}; T === Val{Int} ? 1 : T === Val{3} ? 2 : T === Val{:s} ? 3 : T === Val{Union{}} ? 4 : T === Val{String} ? 5 : 0)
tupleparam(i::Int) = (T = Tuple{PARAMS[i], Int}; T === Tuple{Int,Int} ? 1 : T === Tuple{3,Int} ? 2 : T === Tuple{:s,Int} ? 3 : T === Tuple{String,Int} ? 4 : 0)
toomany(i::Int) = (x = PARAMS[i]; T = Vector{x, x}; T === Vector{Int} ? 1 : 0)
function caught(f, i::Int)
    try
        f(i)
    catch e
        # (the TypeError's function, context and value; of a bound, `expected` is its type
        # variable, checked in test/regressions.jl)
        e isa TypeError ? (e.func === :Bounded && ctx_is(e, "T") ? -10 :
                           e.func === :Type && ctx_is(e, "parameter") && e.expected === Type ? -20 :
                           e.func === :Tuple && ctx_is(e, "parameter") && e.expected === Type ? -30 : -40) +
                          (e.got === String ? -1 : e.got === 3 ? -2 : (g = e.got; g isa String && g == "a") ? -3 : 0) :
        e isa ErrorException ? (msg_is(e, "too many parameters for type Array") ? -50 :
                                msg_is(e, "Tuple field type cannot be Union{}") ? -60 :
                                msg_has(e, "closed-world limit") ? -70 : -80) : -90
    end
end
bounded_caught(i::Int) = caught(bounded, i)
valparam_caught(i::Int) = caught(valparam, i)
tupleparam_caught(i::Int) = caught(tupleparam, i)
toomany_caught(i::Int) = caught(toomany, i)

# the closed-world limit: a type the module was not compiled with (natively `Val{4}`)
valint(n::Int) = (T = Val{n}; T === Val{1} ? 1 : T === Val{2} ? 2 : 0)
valint_caught(n::Int) = caught(valint, n)

# shapes not supported (refused when compiling): a `Vararg` parameter of a tuple type, which
# changes its number of parameters (natively `Tuple{Vararg{Int,2}}` is `Tuple{Int,Int}`); an
# alias that normalizes parameters away (`NTuple{0,T}` is `Tuple{}` for every `T`)
const VARARGS = Any[Int, Vararg{Int,2}]
tuple_vararg(i::Int) = (T = Tuple{VARARGS[i]}; T === Tuple{Int} ? 1 : T === Tuple{Int,Int} ? 2 : 0)
tuple_vararg_caught(i::Int) = caught(tuple_vararg, i)
@noinline varargof(flag::Bool) = flag ? Vararg{Int,2} : Vararg{Int,3}
tuple_vararg_known(flag::Bool) = Tuple{varargof(flag)} === Tuple{Int,Int}
ntuplen(n::Int) = NTuple{n, Int} === Tuple{}

end # module RTTypes

const RT = RTTypes

# the helpers of `apply_type` and `new` at run time are in the module (the call was not folded)
rt_helpers(c) = [k for k in keys(c.cgm.helpers) if k isa Tuple && k[1] in (:apply_type, :new_rt)]
has_apply_type(c, W, n) = any(k -> k[1] === :apply_type && k[2] === W && k[3] == n, rt_helpers(c))
has_new(c, n) = any(k -> k[1] === :new_rt && k[2] == n, rt_helpers(c))
unsupported_report(f, argtypes; kw...) = try
    WasmCodegen.compile(f, argtypes; config=test_config(; kw...))
    ""
catch e
    e isa WasmCodegen.UnsupportedConstructs || rethrow()
    sprint(showerror, e)
end

@testset "apply_type and new at run time" begin
    # a case that always throws
    for i in 1:3
        @wtest RT.newbottom_caught(i, 5)
    end
    @test has_new(wcompile(RT.newbottom_caught, (Int, Int)), 1)

    # the cases of a bound are the program's code: `trim = :safe` reports what they cannot compile
    let report = unsupported_report(RT.newodd_caught, (Int, Int))
        @test occursin("new_as", report) && occursin("Odd24", report)
    end
    let c = WasmCodegen.compile(RT.newodd_caught, (Int, Int); config=test_config(trim=:unsafe))
        @test has_new(c, 1) && has_apply_type(c, RT.Box, 1)
        @test wasm_run(c, "newodd_caught", 1, 7; rettype=Int) == RT.newodd_caught(1, 7)
        @test wasm_run(c, "newodd_caught", 2, 7; rettype=Int) == RT.newodd_caught(2, 7)
    end

    for flag in (true, false)
        @wtest RT.newarity_caught(flag)
        @wtest RT.newconv_caught(flag, 3)
        @wtest RT.nt_names(flag)
        @wtest RT.nt_value(flag, 4)
    end
    @test has_new(wcompile(RT.newarity_caught, (Bool,)), 0)
    @test has_new(wcompile(RT.newconv_caught, (Bool, Int)), 1)
    @test has_apply_type(wcompile(RT.nt_names, (Bool,)), NamedTuple, 2)
    let c = wcompile(RT.nt_value, (Bool, Int))
        @test has_apply_type(c, NamedTuple, 2) && has_new(c, 1)
    end

    # partial construction, inline fields holding references
    for i in 1:3
        @wtest RT.partial_rt(i, 6)
    end
    @test has_new(wcompile(RT.partial_rt, (Int, Int)), 1)
    @wtest RT.partial_mutable(2)
    @wtest RT.partial_immutable(2)
    @wtest RT.full_mutable(2)
    @wtest RT.full_immutable(2)

    # type-cache equality
    for i in eachindex(RT.KEYS)
        @wtest RT.valkey(i)
    end
    @test has_apply_type(wcompile(RT.valkey, (Int,)), Val, 1)

    # invalid applications: native errors
    for i in eachindex(RT.PARAMS)
        @wtest RT.bounded_caught(i)
        @wtest RT.valparam_caught(i)
        @wtest RT.tupleparam_caught(i)
    end
    @wtest RT.toomany_caught(1)
    @test has_apply_type(wcompile(RT.bounded_caught, (Int,)), RT.Bounded, 1)
    @test has_apply_type(wcompile(RT.valparam_caught, (Int,)), Val, 1)
    @test has_apply_type(wcompile(RT.tupleparam_caught, (Int,)), Tuple, 2)
    @test has_apply_type(wcompile(RT.toomany_caught, (Int,)), Vector, 2)

    # the closed-world limit: an error that says so (natively 0), also written to stderr
    for n in 1:2
        @wtest RT.valint_caught(n)
    end
    let c = wcompile(RT.valint_caught, (Int,))
        # (caught, or where inference knows the application valid, so that it does not throw
        # for it, and removed the handler, a trap)
        r = wasm_run(c, "valint_caught", 4; rettype=Int)
        @test r == -70 || (r isa Tuple && r[1] === :trap)
        @test occursin("closed-world limit", LAST_OUTPUT[]) && occursin("not compiled into this module", LAST_OUTPUT[])
    end

    # unsupported shapes: refused, or at run time an error that says so (not a missing type)
    let c = WasmCodegen.compile(RT.tuple_vararg_caught, (Int,); config=test_config(trim=:unsafe))
        @test has_apply_type(c, Tuple, 1)
        @test wasm_run(c, "tuple_vararg_caught", 1; rettype=Int) == 1
        @test wasm_run(c, "tuple_vararg_caught", 2; rettype=Int) == -80   # (natively 2)
        @test occursin("not supported", LAST_OUTPUT[]) && !occursin("not compiled into", LAST_OUTPUT[])
    end
    @test occursin("Vararg", unsupported_report(RT.tuple_vararg_known, (Bool,)))
    @test occursin("NTuple", unsupported_report(RT.ntuplen, (Int,)))
end
