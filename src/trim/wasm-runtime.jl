# The pseudo-runtime's answers to C runtime state Base reads through pointers to C structs
# (`cglobal`s of non-scalars). Applied with juliac's trim patches (see `patches.jl`). The
# patched methods call runtime functions with a native twin (`runtime/jlapi.jl`): the build
# process, where the patches are live, keeps its own answers (its threads, its options); the
# module gets its own.
#
# - `Base.JLOptions()`: the build process's options as the module's (a program compiled into
#   a module runs with the options it was built with), with null pointer fields and one
#   thread (`Runtime.BUILD_JLOPTIONS`, taken now);
# - `Threads._nthreads_in_pool(tpid)`: as natively with `-t 1`.

let R = WasmCodegen.Runtime
    R.BUILD_JLOPTIONS[] = R.sanitized_jloptions()
    @eval Base JLOptions() = $(R.jl_options)()
    @eval Base.Threads _nthreads_in_pool(tpid::Int8) = $(R.nthreads_in_pool)(tpid)
end

