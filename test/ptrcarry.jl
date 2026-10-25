# Pointers carried through loops: a carry that is always the same pointer, moved, keeps the
# origin of its initial value; others go through the owner at run time. Results equal
# native in both cases.

function carry_sum(n::Int)
    a = Float64[i / 3 for i in 1:n]
    s = 0.0
    GC.@preserve a begin
        p = pointer(a)
        for _ in 1:n
            s += unsafe_load(p)
            p += 8
        end
    end
    s
end

function carry_store(n::Int)
    a = zeros(Int64, n)
    GC.@preserve a begin
        p = pointer(a, n)
        k = 0
        while p >= pointer(a)
            unsafe_store!(p, k * k)
            p -= 8
            k += 1
        end
    end
    sum(a .* (1:n))
end

const V4 = NTuple{4,VecElement{Float64}}
function carry_vec(n::Int)
    a = Float64[i * 1.25 for i in 1:4n]
    acc = (VecElement(0.0), VecElement(0.0), VecElement(0.0), VecElement(0.0))
    GC.@preserve a begin
        p = pointer(a)
        for _ in 1:n
            v = unsafe_load(Ptr{V4}(p))
            acc = (VecElement(muladd(v[1].value, 0.5, acc[1].value)), VecElement(muladd(v[2].value, 0.5, acc[2].value)),
                   VecElement(muladd(v[3].value, 0.5, acc[3].value)), VecElement(muladd(v[4].value, 0.5, acc[4].value)))
            p += 32
        end
    end
    acc[1].value + 2acc[2].value + 3acc[3].value + 4acc[4].value
end

# not aligned to the elements, and read as another type
function carry_misaligned(n::Int)
    a = UInt32[i * 0x01020304 for i in 1:n+1]
    s = UInt64(0)
    GC.@preserve a begin
        p = Ptr{UInt8}(pointer(a)) + 1
        for _ in 1:n
            s += unsafe_load(Ptr{UInt32}(p))
            p += 4
        end
    end
    s
end

# two carries swapping arrays: not the same pointer moved, so no origin
function carry_swap(n::Int)
    a = Float64[1:n;]
    b = Float64[n+1:2n;]
    s = 0.0
    GC.@preserve a b begin
        p, q = pointer(a), pointer(b)
        for i in 1:n
            s += i * unsafe_load(p) - unsafe_load(q) / 7
            p, q = q + 8, p + 8
        end
    end
    s
end

# two carries that continue with each other, both moved from one pointer: both keep its origin
function carry_mutual(n::Int)
    a = Float64[i * 0.75 for i in 1:2n+2]
    s = 0.0
    GC.@preserve a begin
        r = pointer(a)
        p, q = r, r + 8
        for i in 1:n
            s += i * unsafe_load(p) + unsafe_load(q)
            p, q = q + 8, p + 8
        end
    end
    s
end

# nested: an inner carry starting from an outer one (a column walk)
function carry_nested(m::Int, n::Int)
    A = Float64[i + 10j for i in 1:m, j in 1:n]
    s = 0.0
    GC.@preserve A begin
        pc = pointer(A)
        for j in 1:n
            p = pc
            for i in 1:m
                s += i * j * unsafe_load(p)
                p += 8
            end
            pc += 8m
        end
    end
    s
end

# whether the function compiled for `f` itself accesses memory through pointers without
# origin (calls the byte-wise helpers); other functions of the module may (Base's copies)
function uses_byte_access(c, f)
    infos = [info for (mi, info) in c.cgm.funcs if mi.def isa Method && mi.def.name === nameof(f)]
    isempty(infos) && error("no function compiled for ", f)
    bytewise(i) = i.op === :call && occursin(r"jl_ptr_(load|store)_byte", i.imm[1].name)
    return any(info -> any(bytewise, info.func.body), infos)
end

@testset "pointer carries" begin
    @wtest carry_sum(7)
    @wtest carry_store(9)
    @wtest carry_vec(5)
    @wtest carry_misaligned(6)
    @wtest carry_swap(5)
    @wtest carry_nested(3, 4)
    @wtest carry_mutual(6)
    for (f, T) in ((carry_sum, (Int,)), (carry_vec, (Int,)), (carry_nested, (Int, Int)), (carry_store, (Int,)),
                   (carry_mutual, (Int,)))
        @test !uses_byte_access(wcompile(f, T), f)
    end
    @test uses_byte_access(wcompile(carry_swap, (Int,)), carry_swap)
end
