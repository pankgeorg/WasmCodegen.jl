# Regular expressions on the host's engine (`Runtime.HostRegex`, the `julia_regex` imports of
# `js/julia_regex.mjs`, for `Config(host = :wasi, host_extensions = [:julia_regex])`):
# Base's `Regex` API, unchanged, in Wasm against native PCRE2. Each test builds a report of
# its results; in Wasm it prints it, and the output must be the native report.

module RegexTests

const COMPAT = readlines(joinpath(@__DIR__, "regex", "compat.txt"))

# what is reported of a match
function rep(io::IO, m::Union{Nothing,RegexMatch{String}})
    if m === nothing
        print(io, "nothing")
        return
    end
    print(io, m.offset); print(io, ':'); print(io, m.match)
    for (k, c) in zip(m.offsets, m.captures)
        print(io, " ["); print(io, k); print(io, ':')
        c === nothing ? print(io, '-') : print(io, c)
        print(io, ']')
    end
end

# printing without dynamic calls: each value of a concrete type
w(io::IO, x::Union{String,SubString{String},Char,Bool,Int}) = print(io, x)
w(io::IO, ::Nothing) = print(io, "nothing")
w(io::IO, r::UnitRange{Int}) = (print(io, first(r)); print(io, ':'); print(io, last(r)))
function w(io::IO, v::Vector{T}) where {T}
    for (k, x) in enumerate(v)
        k > 1 && print(io, '|')
        w(io, x)
    end
end
w(io::IO, r::Regex) = show(io, r)
# (recursive, not a loop over a tuple of several types)
ln(io::IO) = println(io)
ln(io::IO, x, xs...) = (w(io, x); print(io, ' '); ln(io, xs...))

function matches(io::IO, r::Regex, s::String)
    for m in eachmatch(r, s)
        rep(io, m::RegexMatch{String}); print(io, ';')
    end
    println(io)
end

# Base's Regex API on literals (constants of the image) and patterns made at run time
function api()
    io = IOBuffer()
    s = "Version v1.2.3-rc1+build.5 of Example; ünïcödé 日本 😀 ok"
    rep(io, match(r"v(\d+)\.(\d+)\.(\d+)(?:-(\w+))?", s)); println(io)
    rep(io, match(r"v(\d+)\.(\d+)\.(\d+)(?:-(\w+))?", s, 20)); println(io)
    rep(io, match(r"(?<word>\p{L}+)\s+(?<cjk>\p{Han}+)", s)); println(io)
    m = match(r"(?<maj>\d+)\.(?<min>\d+)", s)::RegexMatch{String}
    ln(io, m["maj"], m[:min], m[2], haskey(m, :maj), haskey(m, "nope"))
    for k in keys(m)
        k isa String ? w(io, k) : w(io, k::Int); print(io, ',')
    end
    println(io)
    ln(io, occursin(r"EXAMPLE"i, s), occursin(r"^Version", s), occursin(r"ok$", s), occursin(r"\bof\b", s))
    ln(io, startswith(s, r"V\w+"), endswith(s, r"\s\w+"), startswith(s, r"x"))
    ln(io, findfirst(r"\d+", s), findnext(r"\d+", s, 13), findall(r"[aeiou]", "education"))
    ln(io, count(r"a", "banana"), count(r"ana", "banana"; overlap=true))
    matches(io, r"(\w)(\w*)", "eachmatch over these words")
    matches(io, r"a*", "baaac")
    matches(io, r"ü|é|😀|.", "aü😀é")
    ln(io, replace("Hello, World", r"o" => "0"), replace("2026-10-28", r"(\d+)-(\d+)-(\d+)" => s"\3/\2/\1"))
    ln(io, replace("#Hello# from Julia", r"#(.+)# from (?<from>\w+)" => s"FROM: \g<from>; MESSAGE: \1"))
    ln(io, replace("a1b22c333", r"\d+" => "<>"), replace("abc", r"" => "-"))
    ln(io, replace("x y  z", r"\s+" => s"_\\\\_"), replace("aaa", r"a" => "b"; count=2))
    ln(io, split("a, b ,c,,d", r"\s*,\s*"), split("  lead  trail  ", r"\s+"))
    ln(io, split("a1b2c3", r"\d"; keepempty=false), split("abc", r""))
    # flags
    ln(io, occursin(r"a.c"s, "a\nc"), occursin(r"a.c", "a\nc"), occursin(r"^b$"m, "a\nb\nc"), occursin(r"^b$", "a\nb\nc"))
    ln(io, occursin(r"a b c"x, "abc"), occursin(r"ÉCOLE"i, "école"), occursin(r"\w"a, "é"), occursin(r"\w", "é"))
    # patterns at run time
    for p in ("^(\\d+)\\.(\\d+)\$", "(?i)straße", "[[:alpha:]]+", "\\p{Lu}\\p{Ll}+", "(a|b)+c", "x{2,3}")
        r = Regex(p)
        w(io, r.pattern); print(io, " => ")
        rep(io, match(r, "Straße 10.25 xxxx ababc Hello"))
        println(io)
    end
    rep(io, match(Regex("é+", "i"), "ÉÉé")); println(io)
    ln(io, Regex("a") * "b" * r"c", r"x"i == Regex("x", "i"))
    # invalid UTF-8 subjects: no match crosses an invalid sequence
    bad = "ab\xffcd\xe2\x82ef"
    matches(io, r"\w+", bad)
    ln(io, occursin(r"b.c", bad), findfirst(r"cd", bad))
    return String(take!(io))
end

# errors: messages as natively for syntax errors
function errors()
    io = IOBuffer()
    # PCRE2 10.47 reports the end of the offending token. Multibyte prefixes and
    # range endpoints check that the translator converts code points to byte offsets.
    for p in ("(", "a)", "é)", "[a", "a{2,1}", "a{999999}", "*a", "+a", "?a", "{2}a",
              "a**", "a{2}*", "a*+?", "^*", "é**", "\\", "\\i", "é\\i", "[\\i]", "[\\R]",
              "[z-a]", "[é-a]", "[z-\\x61]", "[z-\\Qab\\E]", "[𐀀-\\Qéa\\E]",
              "[\\x7a-a]", "[z-\\cA]", "[z-\\n]", "[z-\\d]", "[\\d-a]", "\\cĀ", "[\\cĀ]",
              "(?<a>x)(?<a>y)", "\\k<nope>", "[[:foo:]]")
        try
            Regex(p)
            print(io, p); println(io, ": compiled")
        catch e
            print(io, p); print(io, ": "); println(io, e isa ErrorException ? e.msg::String : "other")
        end
    end
    return String(take!(io))
end

# what the translator rejects (though PCRE2 compiles it): a clear error, natively not
function untranslatable()
    io = IOBuffer()
    for (p, subject) in (("(?R)", "ab"), ("a(?=b)\\K", "ab"), ("(?|(a)|(b))", "ab"), ("(a)?b\\1", "ab"), ("a*", "x\xffy"),
                         ("[\\8]", "\0"), ("[^\\9]", "9"))
        try
            occursin(Regex(p), subject)
            print(io, p); println(io, ": compiled")
        catch e
            print(io, p); print(io, ": "); println(io, e isa ErrorException ? e.msg::String : "other")
        end
    end
    return String(take!(io))
end

# Base's VersionNumber parsing (VERSION_REGEX, with the x flag) of every version in General
# Pkg's semver patterns (Versions.jl) on every [compat] range of General
const VPAT = "v?([0-9]+?)(?:\\.([0-9]+?))?(?:\\.([0-9]+?))?"
const SEMVER = [Regex("^([~^]?)?$VPAT\$"),
                Regex("^((?:≥\\s*)|(?:>=\\s*)|(?:=\\s*)|(?:<\\s*)|(?:=\\s*))v?$VPAT\$"),
                Regex("^[\\s]*$VPAT[\\s]*?\\s-\\s[\\s]*?$VPAT[\\s]*\$")]
function semver()
    io = IOBuffer()
    for s in COMPAT, part in split(s, ',')
        t = strip(part)
        for r in SEMVER
            rep(io, match(r, t)); print(io, ' ')
        end
        println(io)
    end
    return String(take!(io))
end

# Tar's header checks and path splitting
function tar()
    io = IOBuffer()
    for p in ("a/b", "../a", "a/..", "a/../b", "a/..b", "..", "a//b///c", "/x/")
        ln(io, occursin(r"(^|/)\.\.(/|$)", p), split(p, r"/+"), occursin(r"^0* *$", p))
    end
    return String(take!(io))
end

for f in (:api, :errors, :untranslatable, :semver, :tar)
    @eval $(Symbol(f, :_print))() = (print(Core.stdout, $f()); Int32(0))
end

end # RegexTests

using .RegexTests: RegexTests as RX

@testset "regex: host engine (julia_regex)" begin
    cfg = WasmCodegen.Config(host=:wasi, host_extensions=[:julia_regex])
    wcompile(f, at) = WasmCodegen.compile(f, at; config=cfg)
    for (f, g) in ((RX.api, RX.api_print), (RX.errors, RX.errors_print), (RX.semver, RX.semver_print), (RX.tar, RX.tar_print))
        expected = f()
        if f === RX.errors
            @test !occursin(": compiled", expected)
        end
        r = wasm_run(wcompile(g, ()), string(nameof(g)); rettype=Int32)
        @test r == 0
        @test LAST_OUTPUT[] == expected
        if LAST_OUTPUT[] != expected
            a, b = split(expected, '\n'), split(LAST_OUTPUT[], '\n')
            k = findfirst(i -> i > length(b) || a[i] != b[i], eachindex(a))
            @info "first difference in $f" line = k expected = get(a, something(k, 1), "") got = get(b, something(k, 1), "") r
        end
    end
    # untranslatable patterns: an error with the translator's message (natively, they compile)
    r = wasm_run(wcompile(RX.untranslatable_print, ()), "untranslatable_print"; rettype=Int32)
    @test r == 0
    out = LAST_OUTPUT[]
    @test count("is not supported by the Wasm regex translator", out) == 6
    @test occursin("the escape \\8 in a character class", out) && occursin("the escape \\9 in a character class", out)
    # a pattern that can match empty, on invalid UTF-8: rejected at match time
    @test occursin("a*: PCRE.exec error: Wasm regex (julia_regex): matching a pattern that can match an empty string against a string that is not valid UTF-8", out)
    @test !occursin("compiled", out)
    # the module imports the julia_regex namespace
    c = wcompile(RX.api_print, ())
    imports = Set(f.imported for f in c.cgm.mod.funcs if f.imported !== nothing)
    @test ("julia_regex", "compile") in imports && ("julia_regex", "match") in imports
    # without the extension: unsupported, naming it; for JavaScript, naming WASI
    for (c, hint) in ((WasmCodegen.Config(host=:wasi), "host_extensions = [:julia_regex]"),
                      (WasmCodegen.Config(), "host = :wasi"))
        err = try
            WasmCodegen.compile(RX.api_print, (); config=c)
            nothing
        catch e
            e
        end
        @test err isa WasmCodegen.UnsupportedConstructs && occursin(hint, sprint(showerror, err))
    end
end
