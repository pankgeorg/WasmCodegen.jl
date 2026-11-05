# Sessions of patches with project patches (`Config(extra_patches, patch_bindings)`): the
# patches apply to the compilation, and are removed after it, whether it succeeds, fails
# to compile, or a patch file fails.

module PatchTarget
greeting() = "native"
greeting_length() = Int32(sizeof(greeting()))
untrimmable(n::Int) = Base.inferencebarrier(n) + 1
end

@testset "patch sessions" begin
    P = PatchTarget
    ok = joinpath(@__DIR__, "patches", "greeting.jl")
    broken = joinpath(@__DIR__, "patches", "broken.jl")
    config(files) = WasmCodegen.Config(extra_patches=files, patch_bindings=[:PatchTarget => P])
    # (a function the patch added keeps its binding, without methods)
    no_added() = !isdefined(P, :added_by_patch) ||
                 isempty(methods(Base.invokelatest(getglobal, P, :added_by_patch)))
    restored() = Base.invokelatest(P.greeting) == "native" && no_added()
    nmethods = length(methods(P.greeting))

    # success: the program is compiled with the patch, the session's world without it after
    c = WasmCodegen.compile(P.greeting_length, (); config=config([ok]))
    @test wasm_run(c, "greeting_length"; rettype=Int32) == sizeof("patched!")
    @test restored()
    @test length(methods(P.greeting)) == nmethods

    # a compile error (dynamic dispatch, trim = :safe)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.untrimmable, (Int,); config=config([ok]))
    @test restored()

    # an error in a patch file, after it defined a method
    @test_throws LoadError WasmCodegen.compile(P.greeting_length, (); config=config([ok, broken]))
    @test restored()
    @test length(methods(P.greeting)) == nmethods
    # (the default patches are removed too: Base works natively as before)
    @test sprint(show, Int) == "Int64"

    # a session within a session with other patches or bindings: an error
    WasmCodegen.with_trim_patches() do _, _
        @test_throws ErrorException WasmCodegen.compile(P.greeting_length, (); config=config([ok]))
        @test_throws ErrorException WasmCodegen.with_trim_patches(() -> nothing; bindings=[:PatchTarget => P])
        # the same patches: shared
        @test WasmCodegen.with_trim_patches((_, _) -> 1) == 1
    end
    @test restored()
end

# `Config(pre_image_hooks)`: called after inference and before the image reads globals, their
# restores when the compilation ends (also when it fails); and `Config(abi_version)`
module HookTarget
global state::Int = 1
read_state() = state
untrimmable(n::Int) = Base.inferencebarrier(n) + 1
end

@testset "pre-image hooks and the interface version" begin
    H = HookTarget
    calls = String[]
    hook() = (push!(calls, "hook"); H.state = 42; () -> (push!(calls, "restore"); H.state = 1))
    c = WasmCodegen.compile(H.read_state, ();
                            config=WasmCodegen.Config(pre_image_hooks=Any[hook], abi_version="test_abi" => Int32(7)))
    # (the image holds the value the hook set; the build process has its own back)
    @test wasm_run(c, "read_state"; rettype=Int) == 42
    @test H.state == 1 && calls == ["hook", "restore"]
    @test wasm_run(c, "test_abi"; rettype=Int32) == 7
    # a failing compilation restores too
    empty!(calls)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(H.untrimmable, (Int,);
                                                                      config=WasmCodegen.Config(pre_image_hooks=Any[hook]))
    @test H.state == 1 && calls == ["hook", "restore"]
    # a restore that fails fails the compilation, whatever it throws (here `nothing`)
    thrown = try
        WasmCodegen.compile(H.read_state, (); config=WasmCodegen.Config(pre_image_hooks=Any[() -> () -> throw(nothing)]))
        :returned
    catch e
        e
    end
    @test thrown === nothing
    # the interface version's export may not be another export's
    @test_throws ArgumentError WasmCodegen.compile(H.read_state, ();
                                                   config=WasmCodegen.Config(abi_version="read_state" => Int32(1)))
    @test_throws ArgumentError WasmCodegen.compile(H.read_state, ();
                                                   config=WasmCodegen.Config(host=:wasi, abi_version="memory" => Int32(1)))
end

# a method of `Runtime.WASM_METHODS`: the native method it replaces (and what only that
# reaches) is not verified, as the module compiles the replacement instead; the same code
# reached from an entry is
module ReplacedTarget
import WasmCodegen
@noinline helper(x::Int) = Base.inferencebarrier(x) + 1
@noinline replaced(x::Int)::Int = helper(x)
WasmCodegen.Runtime.@wasm_method replaced(x::Int) = x + 1
through_replaced(x::Int) = replaced(x) * 2
direct(x::Int) = helper(x)::Int * 2
# a replacement is verified: this one calls the dynamic helper
@noinline replaced_dynamic(x::Int)::Int = x + 1
WasmCodegen.Runtime.@wasm_method replaced_dynamic(x::Int) = helper(x)::Int
through_dynamic(x::Int) = replaced_dynamic(x) * 2
# a replaced method whose native body calls another one, whose native body calls the helper
@noinline outer(x::Int)::Int = inner(x)
@noinline inner(x::Int)::Int = helper(x)
WasmCodegen.Runtime.@wasm_method outer(x::Int) = x + 1
WasmCodegen.Runtime.@wasm_method inner(x::Int) = x + 2
through_outer(x::Int) = outer(x) * 2
# a less specific method reached by `invoke` is not the one a replacement replaces
@noinline invoked(x::Number)::Int = helper(Int(x))
invoked(x::Int) = x + 1
WasmCodegen.Runtime.@wasm_method invoked(x::Int) = x + 1
through_invoke(x::Int) = invoke(invoked, Tuple{Number}, x)
end

@testset "methods of WASM_METHODS and the verifier" begin
    T = ReplacedTarget
    c = WasmCodegen.compile(T.through_replaced, (Int,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "through_replaced", 20; rettype=Int) == T.through_replaced(20) == 42
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.direct, (Int,); config=WasmCodegen.Config(verify=:error))
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.through_dynamic, (Int,); config=WasmCodegen.Config(verify=:error))
    c = WasmCodegen.compile(T.through_outer, (Int,); config=WasmCodegen.Config(verify=:error))
    @test wasm_run(c, "through_outer", 20; rettype=Int) == T.through_outer(20) == 42
    @test_throws WasmCodegen.TrimFailure WasmCodegen.compile(T.through_invoke, (Int,); config=WasmCodegen.Config(verify=:error))
end

# no method of `WASM_METHODS`, or of an extension's table, is more `:consistent` than the native
# one it replaces: inference evaluates calls at compile time with the native methods (see
# `@wasm_method`)
@testset "methods of WASM_METHODS" begin
    R = WasmCodegen.Runtime
    tables = Any[(Symbol[], R.WASM_METHODS); [([ext], mt) for (ext, mt) in R.EXTENSION_METHODS]]
    @test length(tables) > 1
    WasmCodegen.with_trim_patches() do _, w
        for (extensions, mt) in tables
            ms = Method[]
            Base.visit(m -> Base.moduleroot(m.module) === WasmCodegen && push!(ms, m), mt)
            @test !isempty(ms)
            interp = WasmCodegen.WasmInterpreter(; world=w, extensions)
            for m in ms
                sig = Base.unwrap_unionall(m.sig)
                ft = sig.parameters[1]
                ft === typeof(Core.kwcall) && continue
                f = Base.issingletontype(ft) ? ft.instance : ft.parameters[1]
                tt = Tuple(sig.parameters[2:end])
                # (the module's method is this one)
                @test Base.Compiler.findsup(m.sig, WasmCodegen.WasmMethodTable(w, extensions))[1].method === m
                replacement = Base.infer_effects(f, tt; interp, world=w)
                native = Base.infer_effects(f, tt; world=w)
                @test !Base.Compiler.is_consistent(replacement) || Base.Compiler.is_consistent(native)
            end
        end
    end
end

# the code cache is keyed on the overlay tables themselves: an extension's table replaced by
# another with as many methods is not taken for it
module TableIdentity
cache_g(x::Int) = x
Base.Experimental.@MethodTable(A)
Base.Experimental.@MethodTable(B)
Base.Experimental.@overlay A cache_g(x::Int) = x + 1
Base.Experimental.@overlay B cache_g(x::Int) = x + 2
cache_h(x::Int) = cache_g(x)
end

@testset "the code cache and the extensions' tables" begin
    R, T = WasmCodegen.Runtime, TableIdentity
    cfg = WasmCodegen.Config(host_extensions=[:test_tables])
    try
        WasmCodegen.with_trim_patches() do _, _
            R.EXTENSION_METHODS[:test_tables] = T.A
            c = WasmCodegen.compile(T.cache_h, (Int,); config=cfg)
            @test wasm_run(c, "cache_h", 10; rettype=Int) == 11
            R.EXTENSION_METHODS[:test_tables] = T.B
            c = WasmCodegen.compile(T.cache_h, (Int,); config=cfg)
            @test wasm_run(c, "cache_h", 10; rettype=Int) == 12
        end
    finally
        delete!(R.EXTENSION_METHODS, :test_tables)
    end
end

# a log call's file names its package's root instead of the build host's directory; other
# strings and Symbols, `@__FILE__` too, are as natively
module RelocTests
@noinline rl_id(s) = s
function rl_print()
    # (the file of a log call, as the logging macros pass it)
    println(Core.stdout, Base.fixup_stdlib_path(@__FILE__))
    return Int32(0)
end
# (left as they are: data, compared and looked up as natively)
const FILE = @__FILE__
const SYM = Symbol(FILE)
const SYMTAB = Dict(SYM => Int32(73))
const STRTAB = Dict(FILE => Int32(91))
const FILES = [FILE]
const DATA = joinpath(dirname(@__FILE__), "data.toml")
const OTHER = string("/elsewhere", @__FILE__)
# (not below the root once normalized; text that only looks like a log id)
const ESCAPING = string(dirname(@__FILE__), "/../outside.jl")
const LOGLIKE = string("Mod:", @__FILE__, ":7\n")
function rl_print_kept()
    for s in (FILE, DATA, OTHER, ESCAPING, LOGLIKE)
        println(Core.stdout, rl_id(s))
    end
    return Int32(0)
end
lookup_sym() = get(SYMTAB, SYM, Int32(-1))
lookup_str() = get(STRTAB, FILE, Int32(-1))
compare_file(i::Int) = FILES[i] == FILE && Symbol(FILES[i]) === SYM
end
@testset "image: relocatable source paths" begin
    R = RelocTests
    root = rstrip(pkgdir(WasmCodegen), '/')
    file = R.FILE
    @test startswith(file, string(root, '/'))
    relocated = replace(file, string(root, '/') => "@WasmCodegen/")
    c = WasmCodegen.compile(R.rl_print, (); config=WasmCodegen.Config(optimize=nothing))
    @test wasm_run(c, "rl_print"; rettype=Int32) == 0
    @test LAST_OUTPUT[] == string(relocated, "\n")
    @test isempty(WasmCodegen.SOURCE_ROOTS[])
    # other strings and Symbols keep their values: printed, compared and looked up as natively
    c = WasmCodegen.compile(R.rl_print_kept, (); config=WasmCodegen.Config(optimize=nothing))
    @test wasm_run(c, "rl_print_kept"; rettype=Int32) == 0
    @test LAST_OUTPUT[] == join(string.((R.FILE, R.DATA, R.OTHER, R.ESCAPING, R.LOGLIKE), "\n"))
    c = WasmCodegen.compile([WasmCodegen.Entry(R.lookup_sym, ()), WasmCodegen.Entry(R.lookup_str, ()),
                             WasmCodegen.Entry(R.compare_file, (Int,))]; config=WasmCodegen.Config(optimize=nothing))
    @test wasm_run(c, "lookup_sym"; rettype=Int32) == R.lookup_sym() == 73
    @test wasm_run(c, "lookup_str"; rettype=Int32) == R.lookup_str() == 91
    @test wasm_run(c, "compare_file", 1; rettype=Bool) == R.compare_file(1) == true
    # each compilation its own roots, restored after a compilation within it (from a hook),
    # also when that one fails
    seen = Any[]
    function hook()
        before = copy(WasmCodegen.SOURCE_ROOTS[])
        WasmCodegen.compile(R.rl_print, ())
        try
            WasmCodegen.compile(PatchTarget.untrimmable, (Int,))
        catch
        end
        push!(seen, (!isempty(before), WasmCodegen.SOURCE_ROOTS[] == before))
        return nothing
    end
    WasmCodegen.compile(R.rl_print, (); config=WasmCodegen.Config(pre_image_hooks=Any[hook]))
    @test seen == [(true, true)]
    @test isempty(WasmCodegen.SOURCE_ROOTS[])
end
