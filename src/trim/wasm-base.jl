# The pseudo-runtime's patches of Base: code that natively reflects on types or memory at run
# time, made to do so at compile time. Applied with juliac's trim patches (see `patches.jl`).

let Runtime = WasmCodegen.Runtime
    @eval Base begin
        # reinterpreting isbits values: by their leaves (see `runtime/reinterpret.jl`)
        @inline function _reinterpret(::Type{Out}, x::In) where {Out, In}
            isbitstype(Out) || throw(ArgumentError("Target type for `reinterpret` must be isbits"))
            isbitstype(In) || throw(ArgumentError("Source type for `reinterpret` must be isbits"))
            inpackedsize = $(Runtime.packedsize)(In)
            outpackedsize = $(Runtime.packedsize)(Out)
            inpackedsize == outpackedsize ||
                throw(ArgumentError(LazyString("Packed sizes of types ", Out, " and ", In,
                    " do not match; got ", outpackedsize, " and ", inpackedsize, ", respectively.")))
            if $(Runtime.struct_subpadding)(Out, In)
                return $(Runtime.reinterpret_bits)(Out, x)
            else
                return _reinterpret_padding(Out, x)
            end
        end
        # a call in the latest world (to keep it unspecialized natively): a direct call, which
        # specializes it on the type, so its reflection is done at compile time
        _typeinfo_implicit(@nospecialize(T)) = typeinfo_implicit(T)::Bool
        # printing a type: juliac's (which reflects on the type, see juliac-trim-base.jl),
        # computed at compile time: a constant for a type known then, else from a table of
        # the module's types (`Runtime.simple_type_name`, the same text as `_show_type`)
        Base.@assume_effects :foldable _type_name(@nospecialize(T::Type)) =
            $(Runtime.map_type_symbol)($(Runtime.simple_type_name), T)
        show(io::IO, T::Type) = print(io, _type_name(T))
        # showing a function or an enum: the bindings that name it, and their visibility from
        # `show`'s default module, at compile time (`Runtime.function_show`/`enum_show`);
        # another module in the `IOContext`'s `:module` is not in Wasm
        function show_function(io::IO, f::Function, compact::Bool, fallback::Function)
            s = $(Runtime.map_type_value)($(Runtime.function_show), typeof(f))::$(Runtime.FunctionShow)
            if s.fallback
                fallback(io, f)
            elseif compact
                print(io, s.name)
            elseif s.bound && s.value === f
                mod = get(io, :module, UsesBaseOnly)
                visible = mod === s.mod || (mod === UsesBaseOnly ? s.visible :
                    error("show of a function with an IOContext :module other than Base.UsesBaseOnly is not in Wasm"))
                visible || print(io, s.mod, ".")
                show_sym(io, s.name)
            else
                fallback(io, f)
            end
        end
        function show(io::IO, x::Enums.Enum)
            sym = Enums._symbol(x)
            if !(get(io, :compact, false)::Bool)
                from = get(io, :module, Main)
                s = $(Runtime.map_type_value)($(Runtime.enum_show), typeof(x))::$(Runtime.EnumShow)
                # (a value not of an instance, `<invalid #n>`, is no binding: never visible)
                visible = from === nothing ? false : from === s.def ? sym in s.names : from === Main ? sym in s.visible :
                    error("show of an enum with an IOContext :module other than Main is not in Wasm")
                if !visible
                    show(io, s.def)
                    print(io, ".")
                end
            end
            print(io, sym)
        end
        # (`typesplit` reflects on and makes types: a table of the module's types instead)
        nonnothing_nonmissing_typeinfo(io::IO) =
            $(Runtime.map_type)($(Runtime.nonnothing_nonmissing), get(io, :typeinfo, Any))
        function _show_type_param(io::IO, @nospecialize(p))
            if p isa Int
                show(io, p)
            elseif p isa Type
                _show_type(io, p)
            elseif p isa Symbol
                print(io, ":")
                print(io, p)
            elseif p isa TypeVar
                print(io, p.name)
            else
                print(io, "?")
            end
        end
        function _show_type(io::IO, @nospecialize(T::Type))
            if T isa DataType
                print(io, T.name.name)
                if T !== T.name.wrapper && length(T.parameters) > 0
                    print(io, "{")
                    first = true
                    for p in T.parameters
                        first || print(io, ", ")
                        first = false
                        _show_type_param(io, p)
                    end
                    print(io, "}")
                end
            elseif T isa Union
                print(io, "Union{")
                _show_type_param(io, T.a)
                print(io, ", ")
                _show_type_param(io, T.b)
                print(io, "}")
            elseif T isa UnionAll
                _show_type(io, T.body::Type)
                print(io, " where ")
                print(io, T.var.name)
            end
        end
    end
end
