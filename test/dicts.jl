# Dictionaries and sets: Base's Dict, Set and their hashing, as Julia computes them (a Dict
# built at compile time is found at run time, symbols included).

function dict_int(n::Int)
    d = Dict{Int,Int}()
    for i in 1:n
        d[i * 7 % 101] = i
    end
    delete!(d, 7)
    s = 0
    for (k, v) in d
        s += k * v
    end
    return (length(d), s, get(d, 14, -1), haskey(d, 7), d[21])
end
function dict_growth(n::Int)
    d = Dict{Int,Float64}()
    for i in 1:n
        d[i^2] = sqrt(i)
    end
    for i in 1:2:n
        pop!(d, i^2)
    end
    return (length(d), sum(values(d)), maximum(keys(d)))
end
function dict_string(n::Int)
    words = split("the quick brown fox jumps over the lazy dog the fox", ' ')
    counts = Dict{String,Int}()
    for _ in 1:n, w in words
        counts[String(w)] = get(counts, String(w), 0) + 1
    end
    return (length(counts), counts["the"], counts["fox"], haskey(counts, "cat"))
end
function dict_symbol(x::Float64)
    d = Dict{Symbol,Float64}(:a => x, :b => 2x, :c => 3x)
    d[:d] = d[:a] + d[:c]
    return (d[:d], length(d), get(d, :zz, -1.0))
end
function dict_tuple(n::Int)
    d = Dict{Tuple{Int,Int},Int}()
    for i in 1:n, j in 1:n
        d[(i, j)] = i * j
    end
    return (length(d), d[(3, 4)], get(d, (n + 1, 1), 0))
end
function dict_float(n::Int)
    d = Dict{Float64,Int}()
    for i in 1:n
        d[i / 4] = i
    end
    d[-0.0] = 100
    d[0.0] = 200
    return (length(d), d[0.5], d[-0.0], d[0.0])
end
function dict_getmerge(n::Int)
    a = Dict{Int,Vector{Int}}()
    for i in 1:n
        push!(get!(() -> Int[], a, i % 5), i)
    end
    b = merge(Dict(1 => 10, 2 => 20), Dict(2 => 200, 3 => 300))
    return (sum(length, values(a)), sum(a[0]), b[2], length(b))
end
function sets(n::Int)
    s = Set{Int}()
    for i in 1:n
        push!(s, i % 17)
    end
    t = Set(10:30)
    return (length(s), length(intersect(s, t)), length(union(s, t)), 5 in s, 40 in t)
end
function sorted_keys(n::Int)
    d = Dict(i => n - i for i in 1:n)
    ks = sort!(collect(keys(d)))
    return ks[1] + ks[end] * 1000 + d[2]
end
# built at compile time, serialized into the module
const STRTAB = Dict("alpha" => 1, "beta" => 2, "gamma" => 3)
const SYMTAB = Dict(:alpha => 1, :beta => 2, :gamma => 3)
lookup_const(i::Int) = STRTAB[("alpha", "beta", "gamma")[i]] + length(STRTAB)
lookup_symbol(i::Int) = SYMTAB[(:alpha, :beta, :gamma)[i]]
# a symbol made at run time: its hash is computed as Julia's runtime does
lookup_made_symbol(i::Int) = SYMTAB[Symbol(("al", "be", "gam")[i], ("pha", "ta", "ma")[i])]
function made_symbol_keys(n::Int)
    d = Dict{Symbol,Int}()
    for i in 1:n
        d[Symbol("k", i % 7)] = i
    end
    return (length(d), d[:k3], objectid(Symbol("k", 5)) == objectid(:k5))
end

# a Dict of pairs of different types (trim/wasm-dicts.jl), as TOML and package metadata are built
function dict_mixed_pairs(i::Int)
    d = Dict{String,Any}("a" => i, "b" => "x", "c" => [1.5, 2.5], "d" => nothing, "e" => i => 2i)
    e = Dict{String,Union{Int,String}}("n" => i, "s" => string(i))
    return (length(d), d["a"]::Int, hash(d["b"]::String), sum(d["c"]::Vector{Float64}), d["d"] === nothing,
            (d["e"]::Pair{Int,Int}).second, e["n"]::Int, hash(e["s"]::String), collect(keys(d)) == collect(keys(Dict{String,Any}(
            "a" => 1, "b" => 2, "c" => 3, "d" => 4, "e" => 5))))
end

@testset "dictionaries" begin
    @wtest dict_mixed_pairs(7)
    @wtest dict_int(50)
    @wtest dict_growth(300)
    @wtest dict_string(3)
    @wtest dict_symbol(1.5)
    @wtest dict_tuple(6)
    @wtest dict_float(9)
    @wtest dict_getmerge(23)
    @wtest sets(40)
    @wtest sorted_keys(20)
    @wtest lookup_const(2)
    @wtest lookup_symbol(3)
    @wtest lookup_made_symbol(1)
    @wtest lookup_made_symbol(3)
    @wtest made_symbol_keys(30)
end
