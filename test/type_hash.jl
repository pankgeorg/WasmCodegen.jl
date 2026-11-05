# `hash` of types (trim/wasm-base.jl): the C runtime's `jl_type_hash` from a table of the
# module's types, so the hashes are the native ones, and Dicts keyed by values that hash their
# type (`Base.SHA1`: `hash((SHA1, a.bytes), h)`) find their keys.

module TypeHashTests

using Test
using Base: SHA1
using ..Main: @wtest

const TYPES = Type[Int, String, SHA1, Vector{String}, Dict{String, Any}, Union{Int, Nothing},
                   Tuple{Int, Float64}, Type{Int}, Nothing, Vector]
type_hash(i::Int) = (hash(TYPES[i]), hash(TYPES[i], UInt(7)))
sha1_at(i::Int) = SHA1(UInt8[UInt8((i * k) % 256) for k in 1:20])
sha1_hash(i::Int) = (hash(sha1_at(i)), hash(sha1_at(i), UInt(42)))
function sha1_dict(n::Int)
    d = Dict{SHA1, Int}()
    for i in 1:n
        d[sha1_at(i)] = i
    end
    return (length(d), d[sha1_at(3)], get(d, sha1_at(n + 1), -1), haskey(d, sha1_at(n)))
end
# a Dict{SHA1} built at compile time (in the image) and looked up at run time
const IMAGE_DICT = Dict{SHA1, Int}(sha1_at(i) => i for i in 1:5)
image_dict(i::Int) = get(IMAGE_DICT, sha1_at(i), 0)

@testset "hash of types" begin
    for i in 1:length(TYPES)
        @wtest type_hash(i)
    end
    for i in 1:4
        @wtest sha1_hash(i)
    end
    @wtest sha1_dict(9)
    for i in 0:6
        @wtest image_dict(i)
    end
end

end
