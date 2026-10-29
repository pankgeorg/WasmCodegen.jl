# The pseudo-runtime's waits: `sleep` on a host timer (`Runtime.Host.sleep_ns`: the
# `julia_io` imports `timer_start` and `poll` in Wasm, a method of `WASM_METHODS`; Base's
# `sleep` natively), in place of libuv's `Timer`, which needs the scheduler. The module is a
# program of one task: the whole program waits (the host's event loop runs), and `Timer`,
# `Condition` waits and `@async` remain unsupported. Applied with juliac's trim patches (see
# `patches.jl`).

let sleep_ns = WasmCodegen.Runtime.Host.sleep_ns
    @eval Base function sleep(sec::Real)
        sec ≥ 0 || throw(ArgumentError("cannot sleep for $sec seconds"))
        s = Float64(sec)
        $sleep_ns(s >= 9.2e9 ? typemax(Int64) : round(Int64, s * 1e9))
        nothing
    end
end
