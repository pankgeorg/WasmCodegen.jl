# try/catch: Julia's exceptions on Wasm's (see src/exceptions.jl)

struct CodedError <: Exception
    code::Int
end

function catch_div(a::Int, b::Int)
    try
        return div(a, b)
    catch
        return -999
    end
end
function catch_bounds(i::Int)
    v = [1, 2, 3]
    try
        v[i]
    catch e
        e isa BoundsError ? -1 : -2
    end
end
function catch_memory_bounds(i::Int)
    m = Memory{Int}(undef, 3)
    fill!(m, 4)
    try
        m[i]
    catch e
        e isa BoundsError ? -1 : -2
    end
end
function catch_finally(i::Int)
    r = Ref(0)
    try
        try
            i > 2 && error("big")
            r[] += 1
        finally
            r[] += 10
        end
    catch
        r[] += 100
    end
    r[]
end
function catch_parse(i::Int)
    s = ("12", "-7", "x", "")[i]
    try
        parse(Int, s)
    catch e
        e isa ArgumentError ? -1 : -2
    end
end
function catch_rethrow(i::Int)
    try
        try
            i > 1 && throw(DomainError(i))
            0
        catch
            rethrow()
        end
    catch e
        e isa DomainError ? (e.val::Int) * 10 : -1
    end
end
function catch_custom(i::Int)
    s = 0
    for k in 1:i
        try
            k % 3 == 0 && throw(CodedError(k))
            s += k
        catch e
            s -= (e::CodedError).code
        end
    end
    s
end
function catch_message(i::Int)
    try
        i > 0 && error("bad ", i)
        0
    catch e
        ncodeunits((e::ErrorException).msg::String)
    end
end
function catch_typeassert(i::Int)
    x = Any[1, "s", 2.5][i]
    try
        (x::Int) + 1
    catch e
        e isa TypeError ? -1 : -2
    end
end
function catch_overflow(i::Int)
    try
        Base.checked_add(typemax(Int) - 1, i)
    catch e
        e isa OverflowError ? -1 : -2
    end
end
function catch_inexact(i::Int)
    try
        Int(Int8(i * 50))
    catch e
        e isa InexactError ? -1 : -2
    end
end
function return_finally(i::Int, r::Base.RefValue{Int})
    try
        i > 1 && return 100
        r[] += 1
    finally
        r[] += 10
    end
    return r[]
end
return_through_finally(i::Int) = (r = Ref(0); return_finally(i, r) + 1000 * r[])
# a return out of the try of try/catch/finally (and of a try/catch in a try/finally): the
# value it returns also feeds the catch, which never reads it (its argument is of type Union{})
@noinline coded_work(i::Int) = i > 2 ? throw(CodedError(i)) : i + 1
function return_catch_finally(i::Int, r::Base.RefValue{Int})
    try
        return coded_work(i)
    catch
        return -1
    finally
        r[] += 10
    end
end
return_through_catch_finally(i::Int) = (r = Ref(0); return_catch_finally(i, r) + 1000 * r[])
function return_nested_catch_finally(i::Int)
    r = Ref(0)
    v = i * 3
    x = try
        try
            coded_work(i)
            return v + r[]
        catch e
            (e::CodedError).code
        end
    finally
        r[] += 1
    end
    return x + 100 * r[]
end
# a variable assigned after the try's last statement that may throw: the catch's argument is
# of the type the catch can see, not of the type assigned (another type, or a wider one)
function catch_sees_other_type(i::Int)
    x = "s"
    try
        x = coded_work(i)
    catch
    end
    return x isa Int ? x : length(x)
end
function catch_sees_narrower_type(i::Int)
    x = 1
    try
        coded_work(i)
        x = i > 1 ? nothing : i
    catch
    end
    return x === nothing ? -7 : x
end
function catch_sees_narrower_boxed(i::Int)
    x = 1
    try
        coded_work(i)
        x = Base.inferencebarrier(i > 1 ? "z" : i)
    catch
    end
    return x isa Int ? x : -9
end
function catch_nested(i::Int)
    acc = 0
    try
        try
            i == 1 && throw(CodedError(1))
            acc += 1
        catch
            acc += 10
            i == 1 && rethrow()
        end
        i == 2 && throw(CodedError(2))
    catch e
        acc += (e::CodedError).code * 100
    end
    acc
end
# an exception nothing catches
uncaught(i::Int) = i > 0 ? throw(CodedError(i)) : (try i catch; -1 end)

@testset "exceptions" begin
    for b in -1:1
        @wtest catch_div(7, b)
    end
    @wtest catch_div(typemin(Int), -1)
    for i in 0:4
        @wtest catch_bounds(i)
        @wtest catch_memory_bounds(i)
        @wtest catch_finally(i)
        @wtest catch_custom(i + 3)
        @wtest catch_inexact(i)
        @wtest return_through_finally(i)
        @wtest return_through_catch_finally(i)
        @wtest return_nested_catch_finally(i)
        @wtest catch_sees_other_type(i)
        @wtest catch_sees_narrower_type(i)
        @wtest catch_sees_narrower_boxed(i)
    end
    for i in 1:4
        @wtest catch_parse(i)
    end
    for i in 0:3
        @wtest catch_rethrow(i)
        @wtest catch_message(i)
        @wtest catch_nested(i)
    end
    for i in 1:3
        @wtest catch_typeassert(i)
    end
    for i in 0:2
        @wtest catch_overflow(i)
    end
    @wtest uncaught(0)
    @wtest uncaught(1)
    # what a program needs of exceptions decides how they are compiled
    @test wcompile(catch_div, (Int, Int)).cgm.exceptions === :control
    @test wcompile(catch_message, (Int,)).cgm.exceptions === :values
end
