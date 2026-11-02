# Calls of C libraries: what the compiler imports and what it refuses. No C runs here; that is
# lib/WasmCLink's test.
using Test, WasmCodegen, LinearAlgebra
using WasmCodegen: requirements, Config, UnsupportedConstructs
using Base.Libc.Libdl: LazyLibrary

const raw = Config(optimize=nothing)
reqs(f) = requirements(compile([(f, ())]; config=raw))
message(f) = try
    compile([(f, ())]; config=raw)
    ""
catch e
    e isa UnsupportedConstructs || rethrow()
    sprint(showerror, e)
end

const LIBM = "libopenlibm.so.4"
libvar::String = "/some/artifact/lib/libfoo.so"
const lazylib = LazyLibrary("libbar.so.2")

scalars() = ccall((:sin, LIBM), Cdouble, (Cdouble,), 0.5) + ccall((:ldexp, LIBM), Cdouble, (Cdouble, Cint), 1.0, 2) +
            ccall((:scalbln, LIBM), Cdouble, (Cdouble, Clong), 1.0, 2)
fl32() = ccall((:sinf, LIBM), Cfloat, (Cfloat,), 0.5f0)
novalue() = (ccall((:reset_state, LIBM), Cvoid, ()); nothing)
strname() = ccall(("cos", LIBM), Cdouble, (Cdouble,), 0.5)
nonconst() = ccall((:f, libvar), Cdouble, (Cdouble,), 0.5)
lazy() = ccall((:g, lazylib), Cdouble, (Cdouble,), 0.5)
atccall() = @ccall LIBM.tan(0.5::Cdouble)::Cdouble
both() = ccall((:version, "liba.so"), Cint, ()) + ccall((:version, "libb.so"), Cint, ())

ptr_arg() = ccall((:frexp2, LIBM), Cdouble, (Ptr{Cvoid},), C_NULL)
ref_arg() = (r = Ref(0.0); ccall((:modf2, LIBM), Cdouble, (Ref{Cdouble},), r))
ptr_res() = ccall((:version_ptr, LIBM), Ptr{UInt8}, ())
cstr_res() = ccall((:version_str, LIBM), Cstring, ())
cstr_arg() = ccall((:nan2, LIBM), Cdouble, (Cstring,), "x")
any_arg() = ccall((:anyf, LIBM), Cint, (Any,), 1)
struct_val() = ccall((:cabs, LIBM), Cdouble, (ComplexF64,), 1.0 + 2.0im)
int8_arg() = ccall((:i8f, LIBM), Cint, (Int8,), Int8(1))
bool_res() = ccall((:boolf, LIBM), Bool, ())
variadic() = @ccall LIBM.printf2(1.0::Cdouble; 1::Cint)::Cint
twosigs() = ccall((:twice, LIBM), Cdouble, (Cdouble,), 1.0) + ccall((:twice, LIBM), Cdouble, (Cdouble, Cdouble), 1.0, 2.0)
noreturn() = ccall((:abort2, LIBM), Union{}, ())
shadow(p::Ptr{Cvoid}) = ccall((:free, "libfoo.so"), Cvoid, (Ptr{Cvoid},), p)
shadow() = shadow(C_NULL)
shadow2() = ccall((:memchr, "libfoo.so"), Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), C_NULL, 0, 0)


global unset_lib::String
unset() = ccall((:f, unset_lib), Cdouble, (Cdouble,), 0.5)
bare() = ccall(:sin2, Cdouble, (Cdouble,), 0.5)
hinted() = ccall((:pcre2_config_8, "libpcre2-8"), Cint, (Cuint, Ptr{Cvoid}), 0, C_NULL)
blas(n) = (x = fill(2.0, n); dot(x, x))

WasmCodegen.with_trim_patches() do _, _
@testset "imports" begin
    r = reqs(scalars)
    @test [x.symbol for x in r] == ["ldexp", "scalbln", "sin"]
    @test all(x -> x.library == "libopenlibm", r)
    @test r[1].argtypes == Any[Float64, Int32] && r[1].rettype === Float64
    @test r[2].argtypes == Any[Float64, Int64]
    @test only(reqs(fl32)).rettype === Float32
    @test only(reqs(novalue)).rettype === Cvoid
    @test only(reqs(strname)).symbol == "cos"
    @test only(reqs(atccall)).symbol == "tan"
    # a JLL's binding is not constant, and its value is the build process's path
    x = only(reqs(nonconst)); @test x.library == "libfoo"
    @test only(reqs(lazy)).library == "libbar"
    # one symbol in two libraries is two imports
    @test [(x.library, x.symbol) for x in reqs(both)] == [("liba", "version"), ("libb", "version")]
    c = compile([(both, ())]; config=raw)
    mods = Set(f.imported[1] for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test "c:liba" in mods && "c:libb" in mods
end

@testset "refused, naming the symbol" begin
    for (f, sym) in ((ptr_arg, "frexp2"), (ref_arg, "modf2"), (ptr_res, "version_ptr"), (cstr_res, "version_str"),
                     (cstr_arg, "nan2"), (any_arg, "anyf"), (struct_val, "cabs"), (int8_arg, "i8f"), (bool_res, "boolf"),
                     (twosigs, "twice"), (noreturn, "abort2"), (shadow, "free"), (shadow2, "memchr"))
        m = message(f)
        @test occursin("the C function $sym of ", m)
    end
    @test occursin("a pointer in its signature", message(ptr_arg))
    @test occursin("a pointer in its signature", message(ref_arg))
    @test occursin("a pointer in its signature", message(cstr_res))
    @test occursin("the type ComplexF64", message(struct_val))
    @test occursin("printf2", message(variadic))
end

@testset "not C calls" begin
    @test occursin("the foreign call", message(unset))
    @test occursin("the foreign call sin2", message(bare))
    @test occursin("Regex", message(hinted))
    # BLAS is the runtime's, by its library
    c = compile([(blas, (Int,))]; config=raw)
    @test isempty(requirements(c))
    @test !any(f -> f.imported !== nothing && startswith(f.imported[1], "c:"), c.cgm.mod.funcs)
    # WASI stays the host's
    wasi() = ccall((:sched_yield, "wasi_snapshot_preview1"), Int32, ())
    c = compile([(wasi, ())]; config=Config(optimize=nothing, host=:wasi))
    @test isempty(requirements(c))
end
end
