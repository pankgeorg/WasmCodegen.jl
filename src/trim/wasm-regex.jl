# The pseudo-runtime's regular expressions: a Wasm module has no PCRE2 JIT, and so no JIT
# stacks or the match contexts that hold them. The match context is null, and Base's table of
# them per thread (`THREAD_MATCH_CONTEXTS`, which holds pointers of the build process) is out
# of the image. Applied with juliac's trim patches (see `patches.jl`).

@eval Base.PCRE begin
    get_local_match_context() = C_NULL
end
