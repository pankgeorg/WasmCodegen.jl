# `Config(progress = true)`: a line on stderr per phase of the compilation, with its time;
# nothing without it.
progress_prog(x::Float64) = sum(sin(x * i) for i in 1:4)

function stderr_of(f)
    mktemp() do path, io
        redirect_stderr(f, io)
        close(io)
        read(path, String)
    end
end

@testset "progress" begin
    local c
    out = stderr_of(() -> (c = WasmCodegen.compile(progress_prog, (Float64,); config = test_config(progress = true))))
    lines = filter(startswith("WasmCodegen: "), split(out, '\n'))
    phases = [split(l, ':')[2] for l in lines]
    @test phases == [" collect", " emit", " finish", " write", " validate", " optimize"]
    @test all(l -> occursin(r": .*\b\d+\.\d s", l), lines)
    @test occursin(r"emit: \d+ functions \(exceptions: \w+\), 0 unsupported constructs, \d+\.\d s \(structurizing \d+\.\d s\)", out)
    @test occursin(r"write: \d+ bytes", out)
    @test occursin("optimize: $(length(c.bytes)) bytes after wasm-opt -O3", out)
    @test wasm_run(c, "progress_prog", 0.5; rettype = Float64) ≈ progress_prog(0.5)

    @test c.cgm.structurize_ns > 0
    local q
    quiet = stderr_of(() -> (q = WasmCodegen.compile(progress_prog, (Float64,); config = test_config(optimize = nothing))))
    @test !occursin("WasmCodegen: ", quiet)
    @test q.cgm.structurize_ns == 0   # not timed
end
