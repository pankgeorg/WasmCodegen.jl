# `Dict{K,V}` of pairs of different types, as `Dict{String,Any}("a" => 1, "b" => "x")`: Base's
# constructor iterates the pairs (`for p in ps`), so its element is the abstract `Pair{String}`,
# whose fields the module cannot take from a value of that type. The same entries, in the same
# order, by a fold over the pairs (each of its own type). Applied with juliac's trim patches
# (see `patches.jl`).

@eval Base function Dict{K,V}(ps::Pair...) where V where K
    h = Dict{K,V}()
    sizehint!(h, length(ps))
    afoldl((d, p) -> (d[p.first] = p.second; d), h, ps...)
    return h
end
