# Elements at run-time indices of tuples of mixed types (`t[k]`, as `string` and `print` read
# their arguments), tested with `isa` and narrowed: no object for the union of the element
# types. Results equal native, also where the element is used otherwise (boxed) or the index
# is out of bounds.

module SplitUnionTests

using Test
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen

# a String, compared by its length and bytes
digest(s::String) = (sizeof(s), foldl((h, b) -> 31h + b, codeunits(s); init=UInt64(7)))
kstr(i::Int) = digest(string("k", i % 1000))
mixed_str(i::Int, x::Float64) = digest(string(i, "-", x, 'c', i % 3 == 0))
function mixed_sum(i::Int)
    t = (i, "abc", 2.5, nothing, Int32(i))
    s = 0.0
    for k in 1:length(t)
        x = t[k]
        if x isa Int
            s += 3x
        elseif x isa String
            s += sizeof(x)
        elseif x isa Float64
            s += x / 2
        elseif x isa Int32
            s -= x
        end
    end
    return s
end
# an index out of bounds: a BoundsError
function at_index(i::Int, k::Int)
    t = (i, "abc", 1.5)
    try
        x = t[k]
        return x isa Int ? x + 1 : x isa String ? sizeof(x) : 7
    catch e
        return e isa BoundsError && e.a === t && e.i === k ? -100 : -200
    end
end
# the selected member's own value, for each field of each kind of member
function payloads(i::Int, k::Int)
    t = (i % 2 == 0, Char(0x3b1 + i), Int8(-i), nothing, Int16(-300i), i, 2i, "é$i", Int32(i))
    x = t[k]
    x isa Bool && return 1000 + Int(x)
    x isa Char && return 2000 + Int(x)
    x isa Int8 && return 3000 + Int(x)
    x isa Nothing && return 4000
    x isa Int16 && return 5000 + Int(x)
    x isa Int && return 6000 + x
    x isa String && return 7000 + sizeof(x)
    return 8000 + Int(x::Int32)
end
# `isa` that the member type does not decide (of a type object): an object
const IntegerType = Type{<:Integer}
types_isa(k::Int) = (DataType[Int][1], 5)[k] isa IntegerType
# a field by its name at run time
by_name(i::Int, j::Int) = (x = getfield((a=i, b="xy"), (:a, :b, :c)[j]); x isa Int ? x : sizeof(x::String))
# the element read in a `catch` (an upsilon use): an object
function in_catch(i::Int, k::Int)
    t = (i, "abc")
    x = t[1]
    try
        x = t[k]
        x isa Int && k == 1 && throw(ArgumentError("one"))
        return x isa Int ? 0 : -1
    catch
        return x isa Int ? x : -2
    end
end
# the element also used as a value of the union: an object
const kept = Any[]
function escaping(i::Int, k::Int)
    empty!(kept)
    t = (i, "ab", 0.5)
    x = t[k]
    push!(kept, x)
    x isa Int && (i += x)
    return (i, kept[1] isa Int ? kept[1]::Int : kept[1] isa String ? sizeof(kept[1]::String) : -1)
end
# the same, through a narrowing to a smaller union
function escaping_narrowed(i::Int, k::Int)
    empty!(kept)
    x = (i, "ab", 0.5)[k]
    x isa Float64 && return -1
    push!(kept, x)
    return kept[1] isa Int ? kept[1]::Int : sizeof(kept[1]::String)
end
# the element through `iterate` (a φ of the union): an object
function iterated_sum(i::Int)
    s = 0
    for x in (i, "abc", 'q')
        s += x isa Int ? x : x isa String ? sizeof(x) : Int(x)
    end
    return s
end

# whether a function compiled for one of `names` boxes a value of type `T` (calls its helper)
function emits_box(c, names, @nospecialize(T))
    box = get(c.cgm.helpers, (:box, T), nothing)
    box === nothing && return false
    infos = [info for (mi, info) in c.cgm.funcs if mi.def isa Method && mi.def.name in names]
    isempty(infos) && error("no function compiled for ", names)
    return any(info -> any(i -> i.op === :call && i.imm[1] === box, info.func.body), infos)
end

@testset "split unions" begin
    for i in (0, 7, -12, 123456789)
        @wtest kstr(i)
        @wtest mixed_str(i, 0.25)
        @wtest mixed_sum(i)
        @wtest iterated_sum(i)
    end
    for k in (-1, 0, 1, 2, 3, 4, typemin(Int), typemax(Int))
        @wtest at_index(5, k)
    end
    for i in (1, 6), k in 1:9
        @wtest payloads(i, k)
    end
    for k in 1:2
        @wtest types_isa(k)
    end
    @wtest in_catch(4, 1)
    for j in 1:3
        @wtest by_name(3, j)
    end
    for k in 1:3
        @wtest escaping(4, k)
        @wtest escaping_narrowed(4, k)
    end
    @test !emits_box(wcompile(kstr, (Int,)), (:kstr, :print_to_string), Int)
    @test !emits_box(wcompile(mixed_sum, (Int,)), (:mixed_sum,), Int)
    @test !emits_box(wcompile(payloads, (Int, Int)), (:payloads,), Int)
    @test emits_box(wcompile(escaping, (Int, Int)), (:escaping,), Int)
    @test emits_box(wcompile(escaping_narrowed, (Int, Int)), (:escaping_narrowed,), Int)
    @test emits_box(wcompile(in_catch, (Int, Int)), (:in_catch,), Int)
end

end
