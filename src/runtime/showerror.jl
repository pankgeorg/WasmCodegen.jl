# The text of exceptions of types not known at compile time. In a closed world, a caught
# exception (`catch e`) is an `Any`, and `showerror(io, e)` or `sprint(showerror, e)` of it is
# a dynamic call: `showerror_any` shows the exceptions of Base whose message is text, each
# as Base shows it, by testing for their types. Needs `Errno` (`staging.jl`) before it.

"""
    showerror_any(io, e)

`showerror(io, e)` of an exception of a type not known at compile time (`catch e`), where
`showerror(io, e::Any)` would be a dynamic call: the exceptions of Base whose message is
text, each as Base shows it. A program with exceptions of its own tests for them before
calling this. Of another exception, a line saying it cannot be shown (the type of an `Any`
is not known to the runtime).
"""
function showerror_any(io::Base.IO, @nospecialize(e))
    if e isa ErrorException
        print_text(io, e.msg)
    elseif e isa ArgumentError
        print(io, "ArgumentError: "); print_text(io, e.msg)
    elseif e isa AssertionError
        print(io, "AssertionError: "); print_text(io, e.msg)
    elseif e isa OverflowError
        print(io, "OverflowError: "); print_text(io, e.msg)
    elseif e isa DimensionMismatch
        print(io, "DimensionMismatch: "); print_text(io, e.msg)
    elseif e isa Base.IOError
        showerror(io, e::Base.IOError)
    elseif e isa SystemError
        se = e::SystemError
        print(io, "SystemError: ", se.prefix, ": ", Errno.strerror(se.errnum))
    elseif e isa DivideError
        showerror(io, e::DivideError)
    elseif e isa UndefRefError
        showerror(io, e::UndefRefError)
    elseif e isa EOFError
        showerror(io, e::EOFError)
    elseif e isa ConcurrencyViolationError
        print(io, "ConcurrencyViolationError("); show_text(io, e.msg); print(io, ")")
    elseif e isa KeyError
        print(io, "KeyError: key "); show_scalar(io, e.key); print(io, " not found")
    else
        print(io, "an exception of a type the runtime cannot show")
    end
    return nothing
end

# the text of a message (an `AbstractString` field), printed as it is (not a `LazyString`,
# whose parts are of types not known at compile time)
function print_text(io::Base.IO, @nospecialize(s))
    if s isa String
        print(io, s::String)
    elseif s isa SubString{String}
        print(io, s::SubString{String})
    else
        print(io, "(a message of a type the runtime cannot show)")
    end
end
function show_text(io::Base.IO, @nospecialize(s))
    s isa String ? show(io, s::String) : s isa SubString{String} ? show(io, s::SubString{String}) :
    print(io, "(a message of a type the runtime cannot show)")
end

# `show` of a key of the types of keys of `Dict`s of scalars: as Base shows them
function show_scalar(io::Base.IO, @nospecialize(x))
    if x isa String
        show(io, x::String)
    elseif x isa SubString{String}
        show(io, x::SubString{String})
    elseif x isa Symbol
        show_symbol(io, x::Symbol)
    elseif x isa Char
        show(io, x::Char)
    elseif x isa Bool
        show(io, x::Bool)
    elseif x isa Nothing
        show(io, nothing)
    elseif show_scalar_number(io, x)
    else
        print(io, "(a key of a type the runtime cannot show)")
    end
end

# `show(io, s::Symbol)`: an identifier as `:s` (Base's rule, `Base.isidentifier`); a symbol
# of operator characters (no letter, digit, space, quote or bracket) as `:s`, as Base shows an
# operator (not exactly: Base asks the parser, `jl_is_operator`, which the runtime has not;
# `:(=>)`-style forms and non-operators like `Symbol("!!!")` differ); others as `Symbol("s")`
function show_symbol(io::Base.IO, s::Symbol)
    str = string(s)
    if Base.isidentifier(str)
        print(io, ':', str)
    elseif !isempty(str) && all(c -> !(isletter(c) || isdigit(c) || isspace(c) || c in "\"'`()[]{},;"), str)
        print(io, ':', str)
    else
        print(io, "Symbol(")
        show(io, str)
        print(io, ")")
    end
end

# a number of a primitive type: shown (true), or not one (false)
function show_scalar_number(io::Base.IO, @nospecialize(x))
    if x isa Int64
        show(io, x::Int64)
    elseif x isa Int32
        show(io, x::Int32)
    elseif x isa Int16
        show(io, x::Int16)
    elseif x isa Int8
        show(io, x::Int8)
    elseif x isa Int128
        show(io, x::Int128)
    elseif x isa UInt64
        show(io, x::UInt64)
    elseif x isa UInt32
        show(io, x::UInt32)
    elseif x isa UInt16
        show(io, x::UInt16)
    elseif x isa UInt8
        show(io, x::UInt8)
    elseif x isa UInt128
        show(io, x::UInt128)
    elseif x isa Float64
        show(io, x::Float64)
    elseif x isa Float32
        show(io, x::Float32)
    elseif x isa Float16
        show(io, x::Float16)
    else
        return false
    end
    return true
end
