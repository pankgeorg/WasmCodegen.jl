# C functions a program implements in Julia (`Config(foreign_functions)`, src/foreigncall.jl):
# here Base's PCRE2 calls, and so Base's `Regex`, on a toy engine of literal patterns. What
# the configuration routes and what it does not, a `Regex` constant of the image compiled again
# on first use (`IMAGE_RESET_FIELDS`), and no match contexts (`trim/wasm-regex.jl`).

module ToyPCRE

# A pattern matches its first occurrence from the start offset (at it, anchored); one with '(' does not compile
# (PCRE2's error 114, "missing closing parenthesis", at its end). As PCRE2 for such patterns.
mutable struct Code
    pattern::Vector{UInt8}
end

mutable struct MatchData
    ovector::Vector{UInt}
    subject::Ptr{UInt8}
end

code(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::Code
data(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::MatchData

"How many patterns were compiled."
const COMPILED = Ref(0)

function compile(pattern::Ptr{UInt8}, len::UInt, options::UInt32, errorcode::Ptr{Cint},
                 erroroffset::Ptr{UInt}, ccontext::Ptr{Cvoid})
    bytes = UInt8[unsafe_load(pattern, i) for i in 1:Int(len)]
    if UInt8('(') in bytes
        (unsafe_pointer_to_objref(errorcode)::Base.RefValue{Cint})[] = Cint(114)
        (unsafe_pointer_to_objref(erroroffset)::Base.RefValue{UInt})[] = len
        return C_NULL
    end
    COMPILED[] += 1
    return pointer_from_objref(Code(bytes))
end

jit_compile(code::Ptr{Cvoid}, options::UInt32) = Cint(-45)    # PCRE2_ERROR_JIT_BADOPTION: no JIT
code_free(code::Ptr{Cvoid}) = nothing

function pattern_info(code::Ptr{Cvoid}, what::UInt32, where::Ptr{Cvoid})
    if what == 19       # PCRE2_INFO_NAMETABLE
        (unsafe_pointer_to_objref(where)::Base.RefValue{Ptr{UInt8}})[] = Ptr{UInt8}(0)
    else                # capture count, name count, name entry size
        (unsafe_pointer_to_objref(where)::Base.RefValue{UInt32})[] = UInt32(0)
    end
    return Cint(0)
end

match_data_create(code::Ptr{Cvoid}, gcontext::Ptr{Cvoid}) =
    pointer_from_objref(MatchData(fill(typemax(UInt), 2), Ptr{UInt8}(0)))
match_data_free(md::Ptr{Cvoid}) = nothing
ovector_pointer(md::Ptr{Cvoid}) = pointer(data(md).ovector)
ovector_count(md::Ptr{Cvoid}) = UInt32(1)

function match(code::Ptr{Cvoid}, subject::Ptr{UInt8}, len::UInt, start::UInt, options::UInt32,
               md::Ptr{Cvoid}, mcontext::Ptr{Cvoid})
    p = ToyPCRE.code(code).pattern
    d = data(md)
    start > len && return Cint(-33)      # PCRE2_ERROR_BADOFFSET
    n = length(p)
    last = options & 0x80000000 != 0 ? min(Int(start), Int(len) - n) : Int(len) - n   # PCRE2_ANCHORED
    for i in Int(start):last
        k = 1
        while k <= n && unsafe_load(subject, i + k) == p[k]
            k += 1
        end
        if k > n
            d.ovector[1], d.ovector[2] = UInt(i), UInt(i + n)
            d.subject = subject
            return Cint(1)
        end
    end
    return Cint(-1)                       # PCRE2_ERROR_NOMATCH
end

function substring_length_bynumber(md::Ptr{Cvoid}, number::Cint, len::Ptr{UInt})
    number == 0 || return Cint(-49)       # PCRE2_ERROR_NOSUBSTRING
    o = data(md).ovector
    (unsafe_pointer_to_objref(len)::Base.RefValue{UInt})[] = o[2] - o[1]
    return Cint(0)
end

function substring_copy_bynumber(md::Ptr{Cvoid}, number::UInt32, buf::Ptr{UInt8}, len::Ptr{UInt})
    number == 0 || return Cint(-49)
    d = data(md)
    ref = unsafe_pointer_to_objref(len)::Base.RefValue{UInt}
    n = d.ovector[2] - d.ovector[1]
    n + 1 > ref[] && return Cint(-48)     # PCRE2_ERROR_NOMEMORY
    for k in UInt(1):n
        unsafe_store!(buf, unsafe_load(d.subject, d.ovector[1] + k), k)
    end
    unsafe_store!(buf, 0x00, n + 1)
    ref[] = n
    return Cint(0)
end

substring_number_from_name(code::Ptr{Cvoid}, name::Cstring) = Cint(-49)

function get_error_message(errorcode::Cint, buf::Ptr{UInt8}, len::UInt)
    msg = errorcode == 114 ? "missing closing parenthesis" : errorcode == -1 ? "no match" : ""
    isempty(msg) && return Cint(-29)      # PCRE2_ERROR_BADDATA
    cu = codeunits(msg)
    for k in 1:length(cu)
        unsafe_store!(buf, cu[k], k)
    end
    unsafe_store!(buf, 0x00, length(cu) + 1)
    return Cint(length(cu))
end

const FUNCTIONS = Pair{Tuple{Symbol,String},Any}[
    (Symbol(:pcre2_, name, :_8), "libpcre2-8") => f for (name, f) in (
        :compile => compile, :jit_compile => jit_compile, :code_free => code_free,
        :pattern_info => pattern_info, :match_data_create_from_pattern => match_data_create,
        :match_data_free => match_data_free, :get_ovector_pointer => ovector_pointer,
        :get_ovector_count => ovector_count, :match => match,
        :substring_length_bynumber => substring_length_bynumber,
        :substring_copy_bynumber => substring_copy_bynumber,
        :substring_number_from_name => substring_number_from_name,
        :get_error_message => get_error_message)]

end # ToyPCRE

const FF_LITERAL = r"lo"
const FF_UNUSED = r"zz"

# Base's Regex API on a constant of the image and on patterns made at run time
function ff_regex(p::String)
    io = IOBuffer()
    s = "hello, yellow world"
    print(io, occursin(FF_LITERAL, s), ' ', findfirst(FF_LITERAL, s), ' ', findnext(FF_LITERAL, s, 5), ' ')
    print(io, count(FF_LITERAL, s), ' ', replace(s, FF_LITERAL => s"<\0>"), ' ')
    for m in eachmatch(Regex(p), s)
        print(io, m.offset, ':', m.match, ';')
    end
    m = match(Regex(p), s, 9)
    m === nothing || print(io, ' ', m.offset)
    print(io, ' ', startswith(s, Regex(p)), ' ', split("a,b,,c", Regex(","))[3] == "")
    return String(take!(io))
end

ff_regexes() = string(ff_regex("ll"), '|', ff_regex("o"), '|', ff_regex("xyz"))
ff_print_regexes() = (print(Core.stdout, ff_regexes()); Int32(0))

function ff_error(p::String)
    try
        Regex(p)
        return "compiled"
    catch e
        return e isa ErrorException ? e.msg::String : "other"
    end
end

ff_errors() = string(ff_error("a("), '|', ff_error("ab"))
ff_print_errors() = (print(Core.stdout, ff_errors()); Int32(0))

# a constant of the image is compiled on first use, once
function ff_compiles()
    fresh = FF_UNUSED.regex == C_NULL
    before = ToyPCRE.COMPILED[]
    a = occursin(FF_UNUSED, "fizz")
    b = occursin(FF_UNUSED, "jazz")
    return fresh && a && b && ToyPCRE.COMPILED[] - before == 1
end

# a function of another library of the same name
ff_other(x::Int32) = ccall((:pcre2_match_data_free_8, "libother"), Int32, (Int32,), x)

# a function that does not return the call's type
ff_wrong_count(md::Ptr{Cvoid}) = 1
ff_count(md::Ptr{Cvoid}) = ccall((:pcre2_get_ovector_count_8, "libpcre2-8"), UInt32, (Ptr{Cvoid},), md)

@testset "foreign functions" begin
    toy(; kw...) = test_config(; foreign_functions = ToyPCRE.FUNCTIONS, kw...)
    c = WasmCodegen.compile(ff_print_regexes, (); config = toy())
    @test wasm_run(c, "ff_print_regexes"; rettype = Int32) == 0
    @test LAST_OUTPUT[] == ff_regexes()
    LAST_OUTPUT[] == ff_regexes() || println(Core.stdout, "native ", repr(ff_regexes()), "\n wasm ", repr(LAST_OUTPUT[]))
    c = WasmCodegen.compile(ff_print_errors, (); config = toy())
    @test wasm_run(c, "ff_print_errors"; rettype = Int32) == 0
    @test LAST_OUTPUT[] == ff_errors() == "PCRE compilation error: missing closing parenthesis at offset 2|compiled"
    c = WasmCodegen.compile(ff_compiles, (); config = toy())
    @test wasm_run(c, "ff_compiles"; rettype = Bool) === true
    # (natively, the constant holds the build process's compiled pattern)
    @test FF_UNUSED.regex != C_NULL

    # without them, Regex is unsupported, and the message names the configuration
    err = try
        WasmCodegen.compile(ff_print_regexes, (); config = test_config())
        nothing
    catch e
        e
    end
    @test err isa WasmCodegen.UnsupportedConstructs
    @test occursin("foreign_functions", sprint(showerror, err))
    # a call naming another library is not claimed
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(ff_other, (Int32,); config = toy())
    # the function must return the call's type
    wrong = Pair{Tuple{Symbol,String},Any}[(:pcre2_get_ovector_count_8, "libpcre2-8") => ff_wrong_count]
    err = try
        WasmCodegen.compile(ff_count, (Ptr{Cvoid},); config = test_config(foreign_functions = wrong))
        nothing
    catch e
        e
    end
    @test err isa WasmCodegen.UnsupportedConstructs
    @test occursin("returns Int64, not the call's UInt32", sprint(showerror, err))
    @test_throws ArgumentError WasmCodegen.compile(ff_count, (Ptr{Cvoid},);
        config = test_config(foreign_functions = Pair{Tuple{Symbol,String},Any}[(:f, "") => ff_wrong_count]))
end
