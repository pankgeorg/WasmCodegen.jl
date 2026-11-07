# Tuples of unknown length as fields (`Tuple{Vararg{Union{UInt64,String}}}`, a VersionNumber's
# prerelease and build parts): `===` against `()`, comparison, isempty/length/iterate/getindex;
# also in a module that limits inference to one method per call (`@max_methods 1`, as Pkg's
# modules do). Tuples of unknown length of singletons (`Tuple{Vararg{Nothing}}`, the `ntuple` of
# `selectdim`'s indices), whose elements are not stored.

module VarargTupleTests

using Test
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen

const VS = [v"1.2.3", v"1.2.3-alpha", v"1.2.3-alpha.1", v"1.2.3+build.7", v"1.2.3-rc.2+b5",
            v"0.0.0", v"1.13.2", v"1.13.2-DEV.1+abc.2", v"2.0.0-0.3.7", v"1.0.0-x.7.z.92"]
const N = length(VS)

vn_egal(i::Int, j::Int) = VS[i] === VS[j]
vn_cmp(i::Int, j::Int) = (VS[i] == VS[j], isequal(VS[i], VS[j]), VS[i] < VS[j], isless(VS[j], VS[i]))
vn_parts(i::Int) = (v = VS[i]; (isempty(v.prerelease), length(v.prerelease), isempty(v.build), length(v.build),
                                v.prerelease === (), v.build === (), () === v.build))
function vn_iter(i::Int)
    v = VS[i]
    s = 0
    for x in v.prerelease; s = 31s + (x isa String ? sizeof(x) : Int(x)); end
    for k in 1:length(v.build); x = v.build[k]; s = 37s + (x isa String ? sizeof(x) : Int(x)); end
    return s
end

# one method per call
module MaxMethods1
Base.Experimental.@max_methods 1
# (the parts, not a VersionNumber: its constructor checks them with a Regex before Julia 1.13)
firstpre(v::VersionNumber) = isempty(v.prerelease) ? () : (v.prerelease[1],)
same(a::VersionNumber, b::VersionNumber) = a === b
npre(v::VersionNumber) = (n = 0; for _ in v.prerelease; n += 1; end; n)
# a function's own limit still applies: with two candidates, a call of it stays dynamic
Base.Experimental.@max_methods 1 function kind end
kind(::Tuple{}) = 0
kind(t::Tuple) = length(t)
own_limit(v::VersionNumber) = kind(v.prerelease)
end
# a module's limit above the default still applies: four candidate methods, one call
module MaxMethods4
Base.Experimental.@max_methods 4
k(::Any) = 0; k(::Int) = 1; k(::Float64) = 2; k(::Bool) = 3
k_any(n::Int) = k(Base.inferencebarrier(isodd(n) ? n : n / 2))
end
function vn_maxmethods1(i::Int)
    v = VS[i]
    p = MaxMethods1.firstpre(v)
    return (MaxMethods1.same(v, VS[i]), p === (), length(p), v.build === (), MaxMethods1.npre(v))
end

# tuples of singletons of a run-time length (ntuple's ladder: up to 10 and beyond)
struct Unit end
ghost_len(n::Int) = length(ntuple(Returns(nothing), n))
ghost_empty(n::Int) = ntuple(Returns(nothing), n) === ()
ghost_elems(n::Int) = (t = ntuple(Returns(Unit()), n); c = 0; for x in t; c += x === Unit(); end; (c, t[end] === Unit()))
ghost_colons(n::Int) = (t = ntuple(Returns(:), n); (length(t), isempty(t) || t[1] === (:)))
# (selectdim's indices: `ntuple(Returns(:), d - 1)` for its BoundsError)
vec_selectdim(n::Int, d::Int) = (y = collect(1.0:n); selectdim(y, d, 1) .*= 2; sum(y))

@testset "tuples of unknown length" begin
    @testset "of singletons" begin
        for n in (0, 1, 3, 10, 11)
            @wtest ghost_len(n)
            @wtest ghost_empty(n)
            @wtest ghost_colons(n)
        end
        for n in (1, 4, 12)
            @wtest ghost_elems(n)
        end
        @wtest vec_selectdim(5, 1)
    end
    for f in (vn_parts, vn_iter, vn_maxmethods1)
        @testset "$(nameof(f))" begin
            for i in 1:N
                @wtest f(i)
            end
        end
    end
    @wtest MaxMethods4.k_any(3)
    @wtest MaxMethods4.k_any(4)
    # (natively the call is dynamic too, but works)
    @test MaxMethods1.own_limit(VS[3]) == 2
    @test_throws WasmCodegen.UnsupportedConstructs wcompile(MaxMethods1.own_limit, (VersionNumber,))
    @testset "egal and comparison" begin
        for (i, j) in ((1, 1), (2, 3), (3, 3), (4, 1), (5, 5), (8, 7), (9, 10))
            @wtest vn_egal(i, j)
            @wtest vn_cmp(i, j)
        end
    end
end

end
