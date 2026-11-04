# `trim/wasm-specialize.jl`: `with_output_color` (`printstyled`) with its callback and
# arguments specialized on, and `repeat` of a Char or a String (`rpad`, `lpad`, `^`), against
# native, and trim-safe (juliac's verifier).

# the text as a number (strings are compared by their bytes)
spec_digest(s::String) = foldl((h, b) -> h * 0x100000001b3 + b, codeunits(s); init=UInt64(0xcbf29ce484222325))

# (`string` of at most 10 arguments: juliac's patches specialize it on no more)
function spec_repeat(n::Int)
    s = string(string(repeat('x', n), repeat('é', n), repeat('😀', n), repeat("ab", n), repeat(" ", n)),
               string(repeat("", n), rpad("ab", n), lpad("ab", n, '-'), rpad(:sym, n + 3, "=+"), "é"^n, 'q'^n))
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

@testset "specialized Base methods: with_output_color, repeat" begin
    @wtest spec_repeat(0)
    @wtest spec_repeat(1)
    @wtest spec_repeat(7)
    @wtest spec_repeat_negative(2)
    @wtest spec_styled(3)
    @wtest spec_styled(200)
    # trim-safe as juliac checks (these were juliac verifier errors)
    for f in (spec_repeat, spec_styled)
        @test (WasmCodegen.compile(f, (Int,); config=WasmCodegen.Config(verify=:error)); true)
    end
end
