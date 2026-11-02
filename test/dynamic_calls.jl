# Calls of function values whose types are known only at run time.
include("harness.jl")
const Slot = Base.RefValue{Float64}
struct Add; k::Float64; end
(a::Add)(r::Slot) = (r[] += a.k; nothing)
struct Dbl end
(::Dbl)(r::Slot) = (r[] *= 2; 7)
mutable struct Mut; n::Int; end
(m::Mut)(r::Slot) = (m.n += 1; r[] += m.n; m)
struct NotForSlot end
(::NotForSlot)(x::Int) = x
struct Thrower end
(::Thrower)(r::Slot) = throw(ArgumentError("no"))
const HELD = let k = 3.0
    Any[Add(1.5), Dbl(), r -> (r[] -= k; k), Mut(0), NotForSlot(), Thrower()]
end
function held(i::Int, v::Float64)
    r = Slot(v)
    out = HELD[i](r)
    return r[] + (out isa Int ? out : out isa Float64 ? out : out isa Mut ? out.n : 0)
end
function caught(i::Int, v::Float64)
    try
        return held(i, v)
    catch
        return -1.0
    end
end
const GENERIC = Any[sin, cos, abs]
generic(i::Int, x::Float64) = GENERIC[i](x)::Float64
struct OnlyNew; k::Int; end
(o::OnlyNew)(r::Slot) = (r[] += o.k; nothing)
function only_new(k::Int, v::Float64)
    fs = Any[]
    push!(fs, OnlyNew(k))
    r = Slot(v)
    fs[1](r)
    return r[]
end
const TYPEOBJ = Any[Float64, Int]
function typeobj(i::Int)
    x = TYPEOBJ[i](2)
    return x isa Float64 ? x : x isa Int ? Float64(x) : -1.0
end
twoargs(f, a::Int, b::Float64) = (f::Any)(a, b)
const TWO = Any[(a::Int, b::Float64) -> a + b, (a::Int, b::Float64) -> a * b]
two(i::Int, a::Int, b::Float64) = (TWO[i])(a, b)::Float64

tier = get(ENV, "WCG_DYNAMIC_CALL_TIER", "all")
@testset "dynamic calls, tier $tier" begin
    @wtest held(1, 2.0)
    @wtest held(2, 2.0)
    @wtest held(3, 2.0)
    @wtest held(4, 2.0)
    @wtest caught(6, 2.0)
    @wtest generic(1, 0.3)
    @wtest generic(3, -0.3)
    @wtest two(2, 3, 1.5)
    if tier == "all"
        @wtest only_new(4, 1.0)
    end
    for (name, f, args, rt) in (("a type in code only, tier image", only_new, (4, 1.0), Float64),
                                ("in the image, no method: natively MethodError", held, (5, 2.0), Float64),
                                ("a type object", typeobj, (1,), Float64))
        tier == "all" && f === only_new && continue
        c = wcompile(f, map(typeof, args))
        r = try
            wasm_run(c, string(nameof(f)), args...; rettype=rt)
        catch e
            first(sprint(showerror, e), 120)
        end
        println("TRAP-CASE ", name, ": ", r)
    end
end
