# A precompile workload: the compiler compiles a small program (loops, floats, arrays, mutable
# objects of the image, a math function, broadcasting, a closure, a union, exceptions, a Dict,
# strings), so that its own code, and Julia's inference
# specialized on `WasmInterpreter`, are compiled into the package image instead of the first
# compilation of a session. Without the trim patches, which cannot be defined while a package
# is precompiled; unsupported constructs trap.
module PrecompileWorkload
using PrecompileTools: @setup_workload, @compile_workload
import ..WasmCodegen

mutable struct Acc
    x::Float64
    n::Int
    v::Vector{Float64}
end
function step!(a::Acc, h::Float64)
    for i in eachindex(a.v)
        a.v[i] = muladd(h, sin(a.x + i), a.v[i])
    end
    a.x += h
    a.n += 1
    return a.n > 10 ? sum(a.v) : a.x
end
const ACC = Acc(0.0, 0, zeros(4))
run_acc(h::Float64) = step!(ACC, h)
get_v(i::Int) = ACC.v[i]

# more of what solver code does: broadcasting, vectors of vectors, a closure, a union, exceptions,
# a Dict, string building, tuples
mutable struct Store
    ks::Vector{Vector{Float64}}
    tab::Dict{Symbol,Float64}
    f::Function
    last::Union{Nothing,Float64}
end
const STORE = Store([zeros(3) for _ in 1:3], Dict(:a => 0.5, :b => 2.0), x -> 2x, nothing)
function mix!(s::Store, h::Float64)
    a = s.tab[:a]
    for k in 2:length(s.ks)
        s.ks[k] .= s.ks[k-1] .* a .+ h
    end
    t = (h, a, length(s.ks))
    r = try
        h < 0 && throw(ArgumentError("negative step"))
        sum(s.ks[end]) + t[1]
    catch
        -1.0
    end
    s.last = s.last === nothing ? r : s.last + r
    return isnothing(s.last) ? 0.0 : s.last
end
run_mix(h::Float64) = mix!(STORE, h)
describe(n::Int) = length(string("n = ", n, ", tab = ", STORE.tab[:b]))

@setup_workload begin
    config = WasmCodegen.Config(; verify=:off, trim_patches=false, trim=:unsafe, on_unsupported=:trap,
                                optimize=nothing)
    @compile_workload begin
        WasmCodegen.COMPILER_WORLD[] = Base.get_world_counter()
        try
            WasmCodegen.compile([WasmCodegen.Entry(run_acc, (Float64,)), WasmCodegen.Entry(get_v, (Int,)),
                                 WasmCodegen.Entry(run_mix, (Float64,)), WasmCodegen.Entry(describe, (Int,))];
                                config, validate=false)
        catch err
            @warn "WasmCodegen's precompile workload failed" exception = err
        finally
            WasmCodegen.COMPILER_WORLD[] = typemax(UInt)
        end
    end
end
end
