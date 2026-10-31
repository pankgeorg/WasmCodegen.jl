# `trim/wasm-specialize.jl`: `with_output_color` (`printstyled`) with its callback and
# arguments specialized on, `repeat` of a Char or a String (`rpad`, `lpad`, `^`), and `sprint`
# of an argument of an abstract type (and juliac's, with keywords, broadcast too), against
# native, and trim-safe (juliac's verifier).

# the text as a number (strings are compared by their bytes)
spec_digest(s::String) = foldl((h, b) -> h * 0x100000001b3 + b, codeunits(s); init=UInt64(0xcbf29ce484222325))

function spec_repeat(n::Int)
    s = string(repeat('x', n), repeat('é', n), repeat('😀', n), repeat("ab", n), repeat(" ", n),
               repeat("", n), rpad("ab", n), lpad("ab", n, '-'), rpad(:sym, n + 3, "=+"), "é"^n, 'q'^n)
    return spec_digest(s)
end
spec_repeat_negative(n::Int) = spec_digest(repeat('x', -n))

function spec_styled(n::Int)
    io = IOBuffer()
    printstyled(io, "a", n, "b"; color=:red, bold=true)
    printstyled(IOContext(io, :color => true), "x\ny\n", n, :s; color=:blue, underline=true)
    printstyled(IOContext(io, :color => true), "z"; color=n)
    Base.with_output_color(print, :green, IOContext(io, :color => true), "q", 2.5; reverse=true)
    Base.with_output_color(join, :cyan, io, ["u", "v"], ", ")
    return spec_digest(String(take!(io)))
end

@noinline spec_opaque(x) = x
spec_show(io::IO, @nospecialize(e)) = print(io, "E:", e isa ArgumentError ? e.msg::String : e isa ErrorException ? e.msg::String : "?")
spec_pair(io::IO, t::Tuple{String, Bool}) = print(io, t[1], t[2] ? "+" : "-")
function spec_sprint(n::Int)
    # of the abstract type Exception (the element of a vector of them)
    e = spec_opaque(Exception[n > 0 ? ArgumentError(string("bad ", n)) : ErrorException("err")])[1]
    x = n > 1 ? n : "s"
    c = spec_opaque(ArgumentError("c"))
    return spec_digest(string(sprint(spec_show, e), sprint(print, x), sprint(spec_show, c; context=:a => 1),
                              sprint(print, n; sizehint=4), sprint(spec_show, c; context=(:a => 1,)),
                              join(sprint.(spec_pair, [("a", n > 2), ("b", true)]; context=:a => n))))
end

# the callback's buffer as juliac's sprint gives it (sizehint 0)
spec_capacity(io::IO, x) = print(io, length(io.data), x)

@testset "specialized Base methods: with_output_color, repeat, sprint" begin
    @test sprint(spec_capacity, 1) == sprint(spec_capacity, 1; sizehint=0)
    @wtest spec_repeat(0)
    @wtest spec_repeat(1)
    @wtest spec_repeat(7)
    @wtest spec_repeat_negative(2)
    @wtest spec_styled(3)
    @wtest spec_styled(200)
    @wtest spec_sprint(0)
    @wtest spec_sprint(1)
    @wtest spec_sprint(5)
    # trim-safe as juliac checks (these were juliac verifier errors)
    for f in (spec_repeat, spec_styled, spec_sprint)
        @test (WasmCodegen.compile(f, (Int,); config=WasmCodegen.Config(verify=:error)); true)
    end
end
