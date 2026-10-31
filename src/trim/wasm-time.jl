# The time of day: the runtime's (`runtime/time.jl`), through twins. Applied with juliac's
# trim patches (see `patches.jl`).

let T = WasmCodegen.Runtime.Time
    @eval Base.Libc begin
        TimeVal() = $(T.timeval)()
        TmStruct(t::Real) = $(T.tmstruct)(t)
    end
end
