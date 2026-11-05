# The exceptions of the code generator's own checks, where a program reads the exceptions
# it catches (see `exceptions.jl`): those Julia's C runtime throws for the same errors.

@noinline throw_bounds_error(@nospecialize(a), i::Int) = throw(BoundsError(a, i))
@noinline throw_divide_error() = throw(DivideError())
@noinline throw_undefref_error() = throw(UndefRefError())
@noinline throw_undefvar_error(s::Symbol) = throw(UndefVarError(s))
@noinline throw_undefvar_error(s::Symbol, m::Module) = throw(UndefVarError(s, m))
@noinline throw_type_error(@nospecialize(expected), @nospecialize(got)) =
    throw(TypeError(:typeassert, "", expected::Type, got))
@noinline throw_new_type_error(@nospecialize(expected), @nospecialize(got)) =
    throw(TypeError(:new, "", expected::Type, got))
@noinline throw_method_error(@nospecialize(f), @nospecialize(args)) = throw(MethodError(f, args))
@noinline throw_field_error(@nospecialize(T), s::Symbol) = throw(FieldError(T::DataType, s))
@noinline throw_rethrow_error() = error("rethrow() not allowed outside a catch block")
@noinline throw_rethrow_other_error() = error("rethrow(exc) not allowed outside a catch block")
@noinline throw_concurrency_error(msg::String) = throw(ConcurrencyViolationError(msg))
# a Memory of `n` elements: negative, or larger than a Wasm array
@noinline throw_memory_size_error(n::Int) = n < 0 ?
    throw(ArgumentError("invalid GenericMemory size: the number of elements is either negative or too large for system address width")) :
    throw(OutOfMemoryError())

"The C runtime's `jl_gc_have_pending_finalizers`, as code reads it: none ever are."
const PENDING_FINALIZERS = Ref{Cint}(0)
