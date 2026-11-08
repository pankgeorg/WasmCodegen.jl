# The names of helpers and globals are for debugging (the name section) and are of a type's
# name, not of the type printed: printing the types of a program's closures and generated
# functions can take seconds each. A name is unique by a counter or the type's id, and a
# compilation's bytes are the same each time it is repeated in a process.

struct TNBox{T}
    x::T
end

@noinline tn_id(x) = x
const TN_TYPES = Any[Int, Float64]

# memory of, boxes of, type objects of, `isa` of, fields of objects of, tuples of unknown
# length of and `apply_type` of `TNBox` types, in a closure over a nested named tuple of them
function tn_program(i::Int)
    v = TNBox{Int}[TNBox(i), TNBox(2i)]
    push!(v, TNBox(3))
    a = Any[TNBox(i), TNBox(1.5), TNBox{Int}, TNBox{Float64}]
    n = 0
    for x in a
        x isa TNBox{Int} && (n += x.x)
        x isa DataType && (n += 100)
        x isa TNBox && (n += 1000)
    end
    t = ntuple(j -> TNBox(j), i)
    b = Any[t]
    push!(b, (TNBox(1),))
    nt = (a = (b = (c = TNBox(i), d = TNBox(2.0)), e = v), f = (TNBox(i), TNBox(0x01)))
    g = () -> nt.a.b.c.x + length(nt.f) + Int(nt.a.b.d.x) + length(nt.a.e)
    T = Core.apply_type(TNBox, tn_id(TN_TYPES)[mod1(i, 2)])
    return n + sum(s -> s.x, v) + (tn_id(a[3]) === TNBox{Int}) + tn_id(g)() +
           (b[1] === t) + (getfield(tn_id(a)[1], :x)::Int) + (T === TNBox{Int}) + length(b[1]::Tuple{Vararg{TNBox{Int}}})
end

@testset "type names" begin
    @test Base.invokelatest(tn_program, 1) isa Int   # (not an exception, which a trap would match)
    @wtest tn_program(1)
    @wtest tn_program(2)
    config = test_config()
    c = WasmCodegen.compile([(tn_program, (Int,))]; config)
    # the type objects' globals: of the type's name and id
    @test any(g -> startswith(g.name, "jl_type_TNBox_"), c.cgm.mod.globals)
    tnames = [g.name for g in c.cgm.mod.globals if startswith(g.name, "jl_type_")]
    @test allunique(tnames)
    # helpers and functions: unique names
    fnames = [f.name for f in c.cgm.mod.funcs if f.imported === nothing]
    @test allunique(fnames)
    @test any(n -> occursin("TNBox", n), fnames)
    # of the name of the type, not of the type printed (its module and parameters)
    @test !any(n -> occursin(r"TNBox.*(Int64|Float64)|type_names", n), [tnames; fnames])
    # the same bytes when repeated, optimized or not (with the name section)
    @test WasmCodegen.compile([(tn_program, (Int,))]; config).bytes == c.bytes
    raw = test_config(optimize=nothing)
    @test WasmCodegen.compile([(tn_program, (Int,))]; config=raw).bytes ==
          WasmCodegen.compile([(tn_program, (Int,))]; config=raw).bytes
end
