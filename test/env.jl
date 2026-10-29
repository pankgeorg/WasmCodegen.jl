# The environment (`ENV`, for WASI) and the time of day: the same operations natively and in
# Wasm, from the same state (every variable removed first, and restored afterwards natively).

module EnvTests

checksum(s::String) = foldl((h, b) -> h * 31 + b, codeunits(s); init=UInt64(length(s)))

function env_ops()
    old = Pair{String,String}[k => v for (k, v) in ENV]
    out = IOBuffer()
    try
        for (k, _) in old
            delete!(ENV, k)
        end
        print(out, "empty ", isempty(ENV), " ", length(ENV), ";")
        ENV["B_VAR"] = "2"
        ENV["A_VAR"] = "1"
        ENV["C_VAR"] = "x=y"         # a value with `=`
        ENV["B_VAR"] = "22"          # replaced
        ENV["UNI"] = "ünï"
        print(out, "eq ", get(ENV, "C_VAR=x", "missing"), " ", haskey(ENV, "C_VAR=x=y"), " ", haskey(ENV, "C_VAR=z"), ";")
        print(out, "get ", ENV["A_VAR"], " ", get(ENV, "NOPE", "def"), " ", get(() -> "f", ENV, "NOPE"),
              " ", haskey(ENV, "C_VAR"), " ", haskey(ENV, "NOPE"), ";")
        print(out, "iter ", join(sort([string(k, "=", v) for (k, v) in ENV]), ","), " ", length(ENV), ";")
        delete!(ENV, "A_VAR")
        print(out, "deleted ", haskey(ENV, "A_VAR"), " ", sort(collect(keys(ENV))), ";")
        print(out, "bool ", Base.get_bool_env("BOOLV", false), " ")
        ENV["BOOLV"] = "yes"
        print(out, Base.get_bool_env("BOOLV", false), ";")
        # (not `withenv`: its saved values are of type Any, a dynamic call)
        print(out, "after ", get(ENV, "W", "-"), " ", ENV["B_VAR"], ";")
        e = try
            ENV["MISSING"]
            "none"
        catch err
            err isa KeyError ? string("KeyError ", err.key::String) : "other"
        end
        print(out, "missing ", e, ";")
        e2 = try
            ENV[""] = "x"
            "none"
        catch err
            err isa SystemError ? string("SystemError ", err.prefix, " ", err.errnum) : "other"
        end
        print(out, "invalid ", e2, ";")
    finally
        for (k, _) in collect(ENV)
            delete!(ENV, k)
        end
        for (k, v) in old
            ENV[k] = v
        end
    end
    return String(take!(out))
end

env_check() = checksum(env_ops())
env_from_host() = Int32(length(get(ENV, "FROM_HOST", "")) + haskey(ENV, "NOT_SET") * 10)
env_print() = (print(Core.stdout, env_ops()); Int32(0))

end # EnvTests

@testset "environment" begin
    E = EnvTests
    expected = E.env_ops()
    c = WasmCodegen.compile(E.env_print, (); config=WasmCodegen.Config(host=:wasi))
    @test wasm_run(c, "env_print"; rettype=Int32, wasi_env=Dict("FROM_HOST" => "1")) == 0
    @test LAST_OUTPUT[] == expected
    LAST_OUTPUT[] == expected || println(Core.stdout, "environment: native ", repr(expected), "\n wasm ", repr(LAST_OUTPUT[]))
    # the host's environment, read on first use
    c = WasmCodegen.compile(E.env_from_host, (); config=WasmCodegen.Config(host=:wasi))
    @test wasm_run(c, "env_from_host"; rettype=Int32, wasi_env=Dict("FROM_HOST" => "abc", "X" => "")) == 3
    # (an empty host environment)
    @test wasm_run(c, "env_from_host"; rettype=Int32, wasi_env=Dict{String,String}()) == 0
end

## the time of day: the host's clock; local time is UTC in Wasm

module TimeTests
tm(t::Int) = (x = Base.Libc.TmStruct(t); (x.sec, x.min, x.hour, x.mday, x.month, x.year, x.wday, x.yday, x.isdst))
timeval_sec() = Base.Libc.TimeVal().sec
end

@testset "time" begin
    T = TimeTests
    cfg = WasmCodegen.Config(host=:wasi)
    c = WasmCodegen.compile(T.tm, (Int,); config=cfg)
    for t in (0, 951782400, 951868800, -2522892345, 1730000000, 4102444799, 1709251199)
        f = WasmCodegen.Runtime.Time.utc_fields(Int64(t))
        @test wasm_run(c, "tm", t; rettype=NTuple{9,Int32}) == (f..., Int32(0))
    end
    c = WasmCodegen.compile(T.timeval_sec, (); config=cfg)
    @test abs(wasm_run(c, "timeval_sec"; rettype=Int64) - Base.Libc.TimeVal().sec) <= 5
    # natively, Base's own (local time)
    @test T.tm(0)[6] == Base.Libc.TmStruct(0).year
end

