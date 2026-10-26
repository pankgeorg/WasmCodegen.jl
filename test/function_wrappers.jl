# FunctionWrappers through typed function references (`Config(funcref_wrappers = true)`): wrappers built
# at compile time and serialized, and wrappers built at run time; by-value arguments and results.
# FunctionWrappers is loaded here, after WasmCodegen (run alone, this file checks that the compiler does
# not need it loaded first).
using FunctionWrappers: FunctionWrapper

struct Scale
    c::Float64
end
(s::Scale)(x::Float64) = s.c * x + 1.0
const FWS = FunctionWrapper{Float64, Tuple{Float64}}(Scale(2.0))
fw_const(x::Float64) = FWS(x)
function fw_runtime(x::Float64, c::Float64)
    fw = FunctionWrapper{Float64, Tuple{Float64}}(Scale(c))
    return fw(x) + fw(2x)
end
const ACC = Ref(0.0)
const FWN = FunctionWrapper{Nothing, Tuple{Float64, Int}}((x, k) -> (ACC[] += k * x; nothing))
function fw_nothing(x::Float64)
    ACC[] = 0.0
    FWN(x, 1)
    FWN(x, 3)
    return ACC[]
end
# wrappers of one signature over different object types side by side
const FWV = [FunctionWrapper{Float64, Tuple{Float64}}(Scale(3.0)), FunctionWrapper{Float64, Tuple{Float64}}(x -> x - 1.0)]
fw_vector(x::Float64) = FWV[1](x) + FWV[2](x)
fw_bool(x::Float64) = FunctionWrapper{Bool, Tuple{Float64, Float64}}(>)(x, 1.0)
# a singleton argument (FunctionWrappers passes it as `Ref{T}` in the cfunction, `Any` in the ccall),
# e.g. `FunctionWrapper{Float64, Tuple{Float64, SciMLBase.NullParameters}}`
struct NoParams end
struct Shift
    c::Float64
end
(s::Shift)(x::Float64, ::NoParams) = x - s.c
const FWG = FunctionWrapper{Float64, Tuple{Float64, NoParams}}(Shift(0.25))
fw_singleton_const(x::Float64) = FWG(x, NoParams())
fw_singleton(x::Float64) = FWG(x, NoParams()) + FunctionWrapper{Float64, Tuple{Float64, NoParams}}(Shift(x))(2x, NoParams())
# a singleton argument next to an `Any` one
struct Either
    c::Float64
end
(e::Either)(x, ::NoParams) = x === nothing ? -e.c : e.c
const FWA = FunctionWrapper{Float64, Tuple{Any, NoParams}}(Either(0.5))
fw_any_singleton(x::Float64) = FWA(nothing, NoParams()) + 3 * FWA(x, NoParams())
# nine arguments with a singleton one: beyond the trampolines' arities, rejected
struct Nine end
(::Nine)(a, b, c, d, e, f, g, h, ::NoParams) = a + b + c + d + e + f + g + h
const FW9 = FunctionWrapper{Float64, Tuple{ntuple(_ -> Float64, 8)..., NoParams}}(Nine())
fw_nine(x::Float64) = FW9(x, x, x, x, x, x, x, x, NoParams())

# boxed arguments (FunctionWrappers passes an argument that is not stored inline, such as a Vector, as
# `Ref{T}` in the cfunction and `Any` in the ccall): an ODE right-hand side f(du, u, t) behind a wrapper
struct Rhs
    k::Float64
end
(r::Rhs)(du::Vector{Float64}, u::Vector{Float64}, t::Float64) = (du .= -r.k .* u .+ t; nothing)
const FWR = FunctionWrapper{Nothing, Tuple{Vector{Float64}, Vector{Float64}, Float64}}(Rhs(2.0))
function fw_boxed(x::Float64)
    u = [x, 2x, 3x]
    du = zeros(3)
    FWR(du, u, 0.5)
    w = FunctionWrapper{Nothing, Tuple{Vector{Float64}, Vector{Float64}, Float64}}(Rhs(x))
    w(u, du, 1.0)
    return sum(du) + 10 * sum(u)
end

# pointer identity, as natively: wrappers of one callable type built alike share a code pointer,
# different callables have different ones, an object has one pointer (from the wrapper or from
# `pointer_from_objref`), none is null. (Natively, a wrapper built inline in another function gets
# that call site's own `@cfunction` pointer; whether it equals a serialized wrapper's is not tested.)
function fw_pointers(c::Float64)
    w = FunctionWrapper{Float64, Tuple{Float64}}(Scale(c))
    return (FWS.ptr != FWV[2].ptr) + 2 * (FWS.ptr == FWV[1].ptr) +
           8 * (FWS.objptr != FWV[1].objptr) + 16 * (w.objptr != FWS.objptr) +
           32 * (FWS.objptr == pointer_from_objref(FWS.obj::Base.RefValue{Scale})) + 64 * (w.ptr != C_NULL)
end
# a wrapper reachable again from its own callable (through a mutable holder)
mutable struct Holder
    fw::Any
end
struct Back
    h::Holder
end
(b::Back)(x::Float64) = x + 1.0
const HOLD = Holder(nothing)
const FWB = FunctionWrapper{Float64, Tuple{Float64}}(Back(HOLD))
HOLD.fw = FWB
fw_cycle(x::Float64) = FWB(x) + (HOLD.fw === FWB ? 10.0 : 0.0) +
                       (unsafe_pointer_to_objref(FWB.objptr) === FWB.obj ? 100.0 : 0.0)
# the same cycle serialized from the callable's side, so that the wrapper is reached while its `Ref` is in progress
const REFB = FWB.obj::Base.RefValue{Back}
function fw_cycle_ref(x::Float64)
    w = REFB[].h.fw::FunctionWrapper{Float64, Tuple{Float64}}
    return w(x) + (unsafe_pointer_to_objref(w.objptr) === REFB ? 100.0 : 0.0)
end

const FWC = WasmCodegen.Config(funcref_wrappers = true)

const DUMP = get(ENV, "WCG_TEST_DUMP", "")
function fwrapper_test(f, args...)
    expected = Base.invokelatest(f, args...)
    c = WasmCodegen.compile(f, map(Core.Typeof, args); config = FWC, validate = isempty(DUMP))
    if !isempty(DUMP)
        mkpath(DUMP); write(joinpath(DUMP, string(nameof(f), ".wasm")), c.bytes)
        WasmBuilder.validate(c.bytes)
    end
    got = wasm_run(c, string(nameof(f)), args...; rettype = typeof(expected))
    @test got === expected
end

@testset "llvm.assume detection reads the entry" begin
    assume_ir = """
        declare void @llvm.assume(i1)
        define void @fw_assume(i8) {
            %v = trunc i8 %0 to i1
            call void @llvm.assume(i1 %v)
            ret void
        }"""
    @test WasmCodegen.llvm_assume_only((assume_ir, "fw_assume"))
    # an assume-only helper before an entry that stores: the call is not an assume
    two = assume_ir * """

        define void @entry(i64) {
            %p = inttoptr i64 %0 to i8*
            store i8 1, i8* %p
            ret void
        }"""
    @test !WasmCodegen.llvm_assume_only((two, "entry"))
    @test !WasmCodegen.llvm_assume_only((two, "fw_assume"))   # the entry must be the only definition
    @test !WasmCodegen.llvm_assume_only((assume_ir, "missing"))
    # a brace in a comment must not end the entry's body early
    commented = """
        declare void @llvm.assume(i1)
        define void @entry(i8* %p) ; {call void @llvm.assume(i1 %v)}
        {
            store i8 1, i8* %p
            ret void
        }"""
    @test !WasmCodegen.llvm_assume_only((commented, "entry"))
end

@testset "FunctionWrappers as funcrefs" begin
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(fw_const, (Float64,); config = WasmCodegen.Config(verify = :off))
    fwrapper_test(fw_const, 1.5)
    fwrapper_test(fw_runtime, 1.5, 4.0)
    fwrapper_test(fw_nothing, 2.5)
    fwrapper_test(fw_vector, 5.0)
    fwrapper_test(fw_bool, 2.0)
    fwrapper_test(fw_bool, 0.5)
    fwrapper_test(fw_singleton_const, 1.5)
    fwrapper_test(fw_any_singleton, 2.0)
    fwrapper_test(fw_boxed, 1.5)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(fw_nine, (Float64,); config = FWC)
    fwrapper_test(fw_pointers, 4.0)
    fwrapper_test(fw_cycle, 1.5)
    fwrapper_test(fw_cycle_ref, 1.5)
    # natively on Julia 1.13 a wrapper built and called in one function can return a wrong value
    # (JuliaLang/FunctionWrappers.jl#36), so the module is compared with the unwrapped calls
    c = WasmCodegen.compile(fw_singleton, (Float64,); config = FWC, validate = isempty(DUMP))
    @test wasm_run(c, "fw_singleton", 1.5; rettype = Float64) === Shift(0.25)(1.5, NoParams()) + Shift(1.5)(3.0, NoParams())
end
