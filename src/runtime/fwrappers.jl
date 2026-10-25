# FunctionWrappers as typed Wasm function references (`Config(funcref_wrappers = true)`).
#
# A `FunctionWrapper{Ret,Args}` holds a `cfunction` pointer to `CallWrapper{Ret}()` specialized on the
# wrapped object's type and a pointer to a `Ref` of the object, and calls them with `ccall`. Wasm has no
# code addresses: the code generator compiles `fw_trampoline` for each (object type, callee, argument
# types) and keeps a typed reference to it in a boxed object that becomes the *owner* of the `Ptr`
# (`emit_cfunction!`); a `ccall` through a `Ptr` casts the owner back and `call_ref`s it
# (`emit_indirect_ccall!`). The object pointer's owner is the `Ref` object itself, which the
# trampoline recovers as `unsafe_pointer_to_objref` does natively.

"The marker type of the boxes holding function references (their type id)."
struct FuncPtrBox end

"""
The function behind a `cfunction(w, Ret, (Ref{objT}, Args...))` pointer: `w` applied to the object the
first argument points to and the remaining arguments, as Julia's own C-callable thunk does.
"""
function fw_trampoline(::Type{objT}, w::W, p::Ptr{Cvoid}, args...) where {objT, W}
    r = Base.unsafe_pointer_to_objref(p)::Base.RefValue{objT}
    return w(r.x, args...)
end

"""
`fw_trampoline` for arguments of singleton types, which FunctionWrappers passes as `Ref{T}` in the
`cfunction` and as `Any` in the `ccall`: such an argument arrives as the object itself and is asserted
back to its type. `S` holds, for the arguments after the object's `Ref`, each such argument's type
`T` and `Nothing` for the others (a concrete tuple type, so `Type{S}` takes no parameter), and `M`
marks the singleton positions. One method per arity, so that every argument is a parameter of its
own (a vararg tuple with an `Any` element would be one boxed parameter).
"""
function fw_trampoline_singletons end
for n in 1:8
    as = [Symbol(:a, i) for i in 1:n]
    conv = [:(fw_arg(Val(M[$i]), fieldtype(S, $i), $(as[i]))) for i in 1:n]
    @eval function fw_trampoline_singletons(::Type{objT}, ::Type{S}, ::Val{M}, w::W, p::Ptr{Cvoid},
                                            $(as...)) where {objT, S, M, W}
        r = Base.unsafe_pointer_to_objref(p)::Base.RefValue{objT}
        return w(r.x, $(conv...))
    end
end
fw_arg(::Val{true}, ::Type{T}, x) where {T} = x::T
fw_arg(::Val{false}, ::Type, x) = x
