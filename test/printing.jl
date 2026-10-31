# Printing in a closed world, in Wasm against Base's printing natively (the references of
# test/printing_fixtures.jl, computed before the trim patches).

module PrintingTests2
using Test
using ..Main: wcompile, wasm_run, WasmCodegen, LAST_OUTPUT

using ..PrintingTests: TYPES, ENUMS, FUNCS, REFS, type_str, enum_shown, fruit_shown, invalid_shown,
    func_shown, func_printed, show_typeinfo, show_typeinfo_wasm, many

@testset "printing in a closed world" begin
    @testset "type names" begin
        # (Wasm prints types without their modules, juliac's way: compared with that text)
        c = wcompile(type_str, (Int,))
        for i in 1:length(TYPES)
            s = String(WasmCodegen.Runtime.simple_type_name(TYPES[i]))
            @test wasm_run(c, "type_str", i; rettype=Tuple{Int,UInt}) == (sizeof(s), hash(s))
        end
    end
    @testset "show of enums and functions" begin
        ref(c, f, args...) = wasm_run(c, string(nameof(f)), args...; rettype=Tuple{Int,UInt}) == REFS[(nameof(f), args...)]
        c = wcompile(enum_shown, (Int,))
        for i in 1:length(ENUMS)
            @test ref(c, enum_shown, i)
        end
        c = wcompile(fruit_shown, (Int,))
        @test ref(c, fruit_shown, 1) && ref(c, fruit_shown, 2)
        @test ref(wcompile(invalid_shown, ()), invalid_shown)
        cs, cp = wcompile(func_shown, (Int,)), wcompile(func_printed, (Int,))
        for i in 1:length(FUNCS)
            @test ref(cs, func_shown, i)
            @test ref(cp, func_printed, i)
        end
        # (juliac's verifier: the tables' functions run natively, `map_type_value`'s body is not
        # part of the module)
        world = Base.get_world_counter()
        for (f, at) in ((enum_shown, (Int,)), (fruit_shown, (Int,)), (func_shown, (Int,)))
            r = WasmCodegen.trim_check([WasmCodegen.entry_instance(f, at; world)]; world, onlywarn=true)
            @test !occursin("Error", r)
        end
    end
    @testset "typeinfo contexts" begin
        # (the functions of types `map_type` tabulates are total over the module's types, `Union{}` too)
        R = WasmCodegen.Runtime
        for T in (Union{}, Pair, Pair{String}, Pair{String,Int}, Union{Pair{Int,Int},Pair{String,String}}, Int, Any)
            @test R.pair_first_type(T) isa Type && R.pair_second_type(T) isa Type && R.typeinfo_eltype(T) isa Type
        end
        @test R.pair_second_type(Pair{String,Int}) === Int && R.pair_first_type(Union{}) === Any
        # (natively, as Base: the patches return what Base's methods do and throw where they throw)
        @test show(IOBuffer(), "x" => 1) === nothing
        @test_throws TypeError show(IOContext(IOBuffer(), :typeinfo => nothing), "x" => 1)
        c = wcompile(show_typeinfo_wasm, (Int,))
        for n in (1, 2)
            @test wasm_run(c, "show_typeinfo_wasm", n; rettype=Int32) == 0
            @test LAST_OUTPUT[] == REFS[(:show_typeinfo, n)]
        end
    end
    @testset "print of many arguments" begin
        @test wasm_run(wcompile(many, (Int,)), "many", 3; rettype=Tuple{Int,UInt}) == REFS[(:many, 3)]
        @test (WasmCodegen.compile(many, (Int,); config=WasmCodegen.Config(verify=:error)); true)
    end
end

end
