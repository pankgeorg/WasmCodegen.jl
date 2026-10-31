# Errors of the code generator.

"""
    WasmCodegen.Unsupported(parts...)

Thrown when code uses a construct the code generator does not support. The message is the
concatenation of `parts`.
"""
struct Unsupported <: Exception
    parts::Vector{Any}
    context::Vector{Any}
    Unsupported(parts...) = new(Any[parts...], Any[])
end

function Base.showerror(io::IO, e::Unsupported)
    print(io, "WasmCodegen: unsupported: ", diagnostic_string(e.parts...))
    for c in e.context
        print(io, "\n  in ", diagnostic_string(c))
    end
end

"""
    limited_sprint(f, args...; maxlen=DIAGNOSTIC_MAXLEN) -> String

`sprint(f, args...)` with `:limit` set, cut off after `maxlen` bytes (marked with `…`):
printing stops there, so a value of a deeply nested type costs no more than `maxlen` to render.
"""
function limited_sprint(f, args...; maxlen::Int=DIAGNOSTIC_MAXLEN)
    lio = LimitedIO(IOBuffer(), maxlen)
    truncated = try
        f(IOContext(lio, :limit => true), args...)
        false
    catch err
        err isa LimitReached || rethrow()
        true
    end
    s = String(take!(lio.buf))
    truncated || return s
    isvalid(s) || (s = s[1:prevind(s, lastindex(s))])
    return s * "…"
end

const DIAGNOSTIC_MAXLEN = 500

"`xs` printed as [`limited_sprint`](@ref) prints them, method instances included."
diagnostic_string(xs...) = limited_sprint(print_diagnostic, xs...)

function print_diagnostic(io::IO, xs...)
    for x in xs
        x isa Union{Core.MethodInstance,Core.CodeInstance} ? print_instance(io, x) : print(io, x)
    end
end

"""
    diagnostic_statement(stmt, typ) -> String

The statement `stmt` of type `typ` as `show` prints them, bounded as
[`limited_sprint`](@ref) bounds it, the method and code instances it refers to included.
"""
diagnostic_statement(@nospecialize(stmt), @nospecialize(typ)) =
    string(limited_sprint(show, streamed_instances(stmt)), "::", limited_sprint(show, typ))

# `show` prints a method or code instance by rendering its signature whole before writing any of
# it: in a statement, each is replaced by a value printing it as it goes
struct StreamedInstance
    x::Union{Core.MethodInstance,Core.CodeInstance}
end
Base.show(io::IO, s::StreamedInstance) = print_instance(io, s.x)

function streamed_instances(@nospecialize(x))
    x isa Union{Core.MethodInstance,Core.CodeInstance} && return StreamedInstance(x)
    x isa Expr || return x
    return Expr(x.head, Any[streamed_instances(a) for a in x.args]...)
end

# as `show` prints a method or code instance, writing the signature as it goes
function print_instance(io::IO, ci::Core.CodeInstance)
    ci.def isa Core.MethodInstance || return show(io, ci)
    print(io, "CodeInstance for ")
    print_instance(io, ci.def)
end

function print_instance(io::IO, mi::Core.MethodInstance)
    m = mi.def
    sig, tvars, outer = mi.specTypes, Any[], io
    while sig isa UnionAll
        push!(tvars, sig.var)
        io = IOContext(io, :unionall_env => sig.var)
        sig = sig.body
    end
    (m isa Method && !(isdefined(m, :generator) && mi === m.generator) &&
     sig isa DataType && !isempty(sig.parameters)) || return show(io, mi)
    print(io, "MethodInstance for ")
    Base.show_signature_function(io, sig.parameters[1], false, "", false, true)
    print(io, "(")
    for (i, T) in enumerate(sig.parameters[2:end])
        print(io, i > 1 ? ", ::" : "::", T)
    end
    print(io, ")")
    Base.show_method_params(outer, tvars)
end

struct LimitReached <: Exception end

# an IO that takes `left` more bytes, then throws `LimitReached`
mutable struct LimitedIO <: IO
    buf::IOBuffer
    left::Int
end

function Base.unsafe_write(io::LimitedIO, p::Ptr{UInt8}, n::UInt)
    k = min(Int(n), io.left)
    unsafe_write(io.buf, p, UInt(k))
    io.left -= k
    k < Int(n) && throw(LimitReached())
    return n
end
Base.write(io::LimitedIO, b::UInt8) = (io.left > 0 || throw(LimitReached()); io.left -= 1; write(io.buf, b))

"Throw an [`Unsupported`](@ref) error with the message `parts`."
unsupported(parts...) = throw(Unsupported(parts...))

"""
    UnsupportedConstructs

The program uses constructs the code generator cannot compile (with `trim = :safe`): every
one, with the function it is in, as juliac's verifier reports dynamic dispatch. The report
counts constructs as distinct by their printed (bounded) messages: two whose messages differ
only past `DIAGNOSTIC_MAXLEN` bytes of a part are one.
"""
struct UnsupportedConstructs <: Exception
    errors::Vector{Pair{Core.MethodInstance,Unsupported}}
end

function Base.showerror(io::IO, e::UnsupportedConstructs)
    # one line per distinct construct, with how often it occurs
    counts = Dict{String,Int}()
    order = String[]
    for (mi, err) in e.errors
        msg = string("WasmCodegen: unsupported: ", diagnostic_string(err.parts...),
                     join(("\n    in " * diagnostic_string(c) for c in err.context[1:end-1]), ""),
                     "\n    in ", diagnostic_string(mi))
        haskey(counts, msg) || push!(order, msg)
        counts[msg] = get(counts, msg, 0) + 1
    end
    print(io, length(e.errors), " unsupported constructs (", length(order), " distinct):")
    for msg in order
        print(io, "\n", msg, counts[msg] > 1 ? "  (×$(counts[msg]))" : "")
    end
end
