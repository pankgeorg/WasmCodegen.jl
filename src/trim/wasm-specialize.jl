# Base methods whose calls a closed world cannot resolve as they are written, redefined with
# the same behaviour, from the Julia installation's Base sources, the bodies unchanged:
# - `with_output_color(f::Function, color, io, args...; ...)` (what `printstyled` calls):
#   `f` is `@nospecialize`d and `args` is a splat, so `f(IOContext(buf, io), args...)` is a
#   dynamic call. Redefined with `f::F` and `args::Vararg{Any,N}` type parameters (the same
#   signature: it replaces the method, and deleting it restores the method).
# - `repeat(c::Char, r::BitInteger)` and `repeat(s::String, r::BitInteger)` (what `rpad`,
#   `lpad` and `^` call) call the generic method with `@invoke repeat(c::Char, r::Integer)`,
#   an invoke of the instance for an abstract `Integer`, which native inference does not
#   compile for a closed world (juliac's verifier: "unresolved invoke"). Redefined with the
#   generic method's body (and the same `:foldable` effects).

let basedir = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base")
    # the `function` definition of `name` in `file` whose signature `sel` accepts
    function definition(file::String, name::Symbol, sel)
        for ex in Meta.parseall(read(file, String); filename=file).args
            def = Meta.isexpr(ex, :macrocall) && length(ex.args) >= 4 ? ex.args[end] : ex
            Meta.isexpr(def, :function) || continue
            call = def.args[1]
            Meta.isexpr(call, :call) && call.args[1] === name && sel(call) || continue
            return def
        end
        error("wasm-specialize.jl: no definition of $name in $file")
    end
    positional(call) = [a for a in call.args[2:end] if !Meta.isexpr(a, :parameters)]

    # with_output_color(@nospecialize(f::Function), color, io::IO, args...; kws...)
    def = definition(joinpath(basedir, "util.jl"), :with_output_color,
                     c -> Meta.isexpr(positional(c)[1], :macrocall))
    call = def.args[1]
    args = map(call.args) do a
        Meta.isexpr(a, :macrocall) ? :(f::WasmF) :            # @nospecialize(f::Function)
        Meta.isexpr(a, :...) ? :(args::Vararg{Any,WasmN}) : a  # args...
    end
    sig = Expr(:where, Expr(:call, args...), :(WasmF<:Function), :WasmN)
    Core.eval(Base, Expr(:function, sig, def.args[2]))

    # repeat(c::Char, r::BitInteger), repeat(s::String, r::BitInteger): the generic bodies
    for (file, generic, specific) in
            (("strings/string.jl", :(c::AbstractChar), :(c::Char)),
             ("strings/substring.jl", :(s::Union{String, SubString{String}}), :(s::String)))
        def = definition(joinpath(basedir, file), :repeat,
                         c -> positional(c) == [generic, :(r::Integer)])
        Core.eval(Base, :(Base.@assume_effects :foldable $(Expr(:function,
            Expr(:call, :repeat, specific, :(r::BitInteger)), def.args[2]))))
    end
end
