# The pseudo-runtime's regular expressions: Base's PCRE2 calls are the host's regex engine
# (`Runtime.HostRegex`), which has no match contexts (nor JIT stacks): the match context is
# null, and Base's table of them per thread (`THREAD_MATCH_CONTEXTS`, which holds pointers of
# the build process) is out of the image. Applied with juliac's trim patches (see `patches.jl`).

@eval Base.PCRE begin
    get_local_match_context() = C_NULL
end
