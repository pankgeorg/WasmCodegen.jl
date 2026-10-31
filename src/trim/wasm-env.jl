# Iterating `ENV` (the C library's `environ` natively): the runtime's environment in Wasm
# (`runtime/env.jl`), through a twin. Applied with juliac's trim patches (see `patches.jl`).

let E = WasmCodegen.Runtime.Env
    @eval Base begin
        function iterate(::EnvDict, i=0)
            while true
                env = $(E.env_entry)(Int(i))
                env === nothing && return nothing
                i += 1
                m = findfirst('=', env)
                if m === nothing
                    @warn "malformed environment entry" env
                    continue
                end
                return (Pair{String,String}(env[1:prevind(env, m)], env[nextind(env, m):end]), i)
            end
        end
    end
end
