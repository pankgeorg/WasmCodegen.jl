# The arguments of `Expr`s the code generator builds: `Core._expr` (`Expr(head, args...)`)
# and splatting into `Expr` (see `builtins.jl`).

module Exprs

"A `Vector{Any}` of `n` undefined elements, the arguments of a new `Expr`."
expr_args(n::Int) = Vector{Any}(undef, n)

set_arg!(v::Vector{Any}, i::Int, @nospecialize(x)) = (@inbounds v[i] = x; nothing)
push_arg!(v::Vector{Any}, @nospecialize(x)) = (push!(v, x); nothing)

"Append the elements of the iterable `x` to `v`."
function append_args!(v::Vector{Any}, x)
    for a in x
        push!(v, a)
    end
    return nothing
end

"`Expr(v...)`: the head (a `Symbol`, else a `TypeError` as natively), then the arguments."
function expr_from_args(v::Vector{Any})
    isempty(v) && throw(ArgumentError("too few arguments to Expr"))
    head = popfirst!(v)
    head isa Symbol || throw(TypeError(:Expr, "", Symbol, head))
    ex = Expr(head)
    ex.args = v
    return ex
end

end
