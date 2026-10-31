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


# Printing with many arguments: a method of a function with varargs is specialized on at most
# `max_args` arguments (juliac's patch raises print's, println's and print_to_string's to 10),
# beyond which the rest is a `Vararg{Any}`, elements of type `Any`: calls juliac's verifier
# cannot resolve (`string(...)` of 14 pieces). 32 for the printing
# functions, and their methods defined again as Base's (the same code): so that what was
# inferred before the session, under the lower limits, is inferred again.
let
    for f in (print, println, Base.print_to_string, string, Base.string_with_env)
        setfield!(typeof(f).name, :max_args, Int32(32), :monotonic)
    end
    @eval Base begin
        function print(io::IO, xs...)
            lock(io)
            try
                for i in 1:nfields(xs)
                    print(io, xs[i])
                end
            finally
                unlock(io)
            end
            return nothing
        end
        println(io::IO, xs...) = print(io, xs..., "\n")
        function print_to_string(xs...)
            if isempty(xs)
                return ""
            end
            siz::Int = 0
            for i in 1:nfields(xs)
                siz += _str_sizehint(xs[i])
            end
            s = IOBuffer(sizehint=siz)
            for i in 1:nfields(xs)
                print(s, xs[i])
            end
            takestring!(s)
        end
        string(xs...) = print_to_string(xs...)
    end
end
