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
tm(t::Real) = (x = Base.Libc.TmStruct(t); (x.sec, x.min, x.hour, x.mday, x.month, x.year, x.wday, x.yday, x.isdst))
timeval_fields() = (x = Base.Libc.TimeVal(); (x.sec, x.usec))
end

@testset "time" begin
    T = TimeTests
    cfg = WasmCodegen.Config(host=:wasi)
    # Fixed UTC calendar tuples, independent of Runtime.Time.utc_fields. Include
    # century leap rules, weekday/year-day rollover, and pre-epoch fractions.
    integer_cases = (
        (0, (0, 0, 0, 1, 0, 70, 4, 0, 0)), # 1970-01-01T00:00:00+00:00
        (-2203891201, (59, 59, 23, 28, 1, 0, 3, 58, 0)), # 1900-02-28T23:59:59+00:00
        (-2203891200, (0, 0, 0, 1, 2, 0, 4, 59, 0)), # 1900-03-01T00:00:00+00:00
        (951782399, (59, 59, 23, 28, 1, 100, 1, 58, 0)), # 2000-02-28T23:59:59+00:00
        (951782400, (0, 0, 0, 29, 1, 100, 2, 59, 0)), # 2000-02-29T00:00:00+00:00
        (951868800, (0, 0, 0, 1, 2, 100, 3, 60, 0)), # 2000-03-01T00:00:00+00:00
        (4107542399, (59, 59, 23, 28, 1, 200, 0, 58, 0)), # 2100-02-28T23:59:59+00:00
        (4107542400, (0, 0, 0, 1, 2, 200, 1, 59, 0)), # 2100-03-01T00:00:00+00:00
        (946684799, (59, 59, 23, 31, 11, 99, 5, 364, 0)), # 1999-12-31T23:59:59+00:00
        (946684800, (0, 0, 0, 1, 0, 100, 6, 0, 0)), # 2000-01-01T00:00:00+00:00
        (-2522892345, (15, 34, 20, 19, 0, -10, 0, 18, 0)), # 1890-01-19T20:34:15+00:00
        (1730000000, (20, 33, 3, 27, 9, 124, 0, 300, 0)), # 2024-10-27T03:33:20+00:00
        (4102444799, (59, 59, 23, 31, 11, 199, 4, 364, 0)), # 2099-12-31T23:59:59+00:00
        (1709251199, (59, 59, 23, 29, 1, 124, 4, 59, 0)), # 2024-02-29T23:59:59+00:00
    )
    c = WasmCodegen.compile(T.tm, (Int,); config=cfg)
    for (t, expected) in integer_cases
        @test wasm_run(c, "tm", t; rettype=NTuple{9,Int32}) == expected
    end
    c = WasmCodegen.compile(T.tm, (Float64,); config=cfg)
    for (t, expected) in (
        (-0.25, (59, 59, 23, 31, 11, 69, 3, 364, 0)),
        (-86400.25, (59, 59, 23, 30, 11, 69, 2, 363, 0)),
        (951868799.75, (59, 59, 23, 29, 1, 100, 2, 59, 0)))
        @test wasm_run(c, "tm", t; rettype=NTuple{9,Int32}) == expected
    end
    c = WasmCodegen.compile(T.timeval_fields, (); config=cfg)
    # Native time() bounds around each call, including the Wasm call. The
    # integer-second bounds allow for TimeVal's microsecond truncation.
    for get_time in (T.timeval_fields,
                     () -> wasm_run(c, "timeval_fields"; rettype=Tuple{Int64,Int64}))
        before = time()
        sec, usec = get_time()
        after = time()
        @test floor(Int64, before) <= sec <= floor(Int64, after)
        @test 0 <= usec < 1_000_000
        @test before - 1e-6 <= sec + usec / 1_000_000 <= after
    end
end
