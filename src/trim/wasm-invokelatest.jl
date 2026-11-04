# `@invokelatest f(args...)`, which Base lowers to `invokelatest_gr(GlobalRef(M, :f), args...)`:
# the value of the global in the latest world (`jl_eval_globalref`), called in that world. A
# trimmed program's world does not advance, so the latest world is the program's: the call is
# of the global's value, which for a constant global (a function, as Base.TOML.Printer's
# `is_tabular`, `print_table`) is a direct call. Applied with juliac's trim patches (see
# `patches.jl`).

@eval Base function invokelatest_gr(gr::GlobalRef, args...; kwargs...)
    @inline
    f = getglobal(gr.mod, gr.name)
    return f(args...; kwargs...)
end
