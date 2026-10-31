# The pseudo-runtime's printing of values in the context of their type (`:typeinfo` of an
# `IOContext`, a value of type `Any`): Base tests and takes apart that type with `isa`, `==`
# and `fieldtype`, here through typed type operations (`<:` and `==` of types are tables of
# the module's types, `Runtime.map_type` a table of a function of types; see
# `reflection.jl`). The same results as Base's. Applied with juliac's trim patches (see
# `patches.jl`).

let R = WasmCodegen.Runtime
    @eval Base begin
        # (`get(io, :typeinfo, Any) == typeof(p)`: the context's type, if a type, equal to the pair's)
        function isdelimited(io::IO, p::Pair)
            t = get(io, :typeinfo, Any)
            return !(has_tight_type(p) || (t isa Type && t == typeof(p)))
        end
        # (`p isa typeinfo <: Pair`: a pair's type is concrete, so `p isa t` is `typeof(p) <: t`)
        function gettypeinfos(io::IO, p::Pair)
            t = get(io, :typeinfo, Any)
            # (as Base's `p isa typeinfo` where the context's is no type)
            t isa Type || throw(TypeError(:isa, "", Type, t))
            typeof(p) <: t && t <: Pair || return Pair{Type,Type}(Any, Any)
            return Pair{Type,Type}($(R.map_type)($(R.pair_first_type), t), $(R.map_type)($(R.pair_second_type), t))
        end
        # (Base's loop over the two fields, of two types, unrolled; the context's entries
        # `Pair{Symbol,Any}`s, whatever the type)
        function show(io::IO, p::Pair)
            isdelimited(io, p) && return show_pairtyped(io, p)
            typeinfos = gettypeinfos(io, p)
            _show_pair_part(io, typeinfos.first, p.first)
            print(io, get(io, :compact, false)::Bool ? "=>" : " => ")
            _show_pair_part(io, typeinfos.second, p.second)
            return nothing
        end
        function _show_pair_part(io::IO, typeinfo::Type, x)
            io_i = IOContext(io, Pair{Symbol,Any}(:typeinfo, typeinfo))
            isdelimited(io_i, x) || print(io, "(")
            show(io_i, x)
            isdelimited(io_i, x) || print(io, ")")
        end
        # (`X isa typeinfo` is `typeof(X) <: typeinfo`; `typeinfo_eltype` a table, `nothing` as
        # `Runtime.NoEltype`)
        function typeinfo_prefix(io::IO, X)
            typeinfo = get(io, :typeinfo, Any)::Type
            if !(typeof(X) <: typeinfo)
                typeinfo = Any
            end
            e = $(R.map_type)($(R.typeinfo_eltype), typeinfo)
            eltype_ctx = e === $(R.NoEltype) ? nothing : e
            eltype_X = eltype(X)
            if X isa AbstractDict
                if eltype_X == eltype_ctx
                    sprint(show_type_name, typeof(X).name; context=io), false
                elseif !isempty(X) && _typeinfo_implicit(keytype(X)) && _typeinfo_implicit(valtype(X))
                    sprint(show_type_name, typeof(X).name; context=io), true
                else
                    sprint(print, typeof(X); context=io), false
                end
            else
                if eltype_X == eltype_ctx
                    "", false
                elseif !isempty(X) && _typeinfo_implicit(eltype_X)
                    "", true
                elseif print_without_params(eltype_X)
                    sprint(show_type_name, unwrap_unionall(eltype_X).name; context=io), false
                else
                    sprint(print, eltype_X; context=io), false
                end
            end
        end
        # (a set is no tuple: `itr isa typeinfo <: Tuple` never holds, and each element is shown
        # in the context's `typeinfo`)
        function show_delim_array(io::IO, itr::AbstractSet, op, delim, cl, delim_one, i1=1, n=typemax(Int))
            print(io, op)
            if !show_circular(io, itr)
                recur_io = IOContext(io, :SHOWN_SET => itr)
                y = iterate(itr)
                first = true
                while i1 > 1 && y !== nothing
                    y = iterate(itr, y[2])
                    i1 -= 1
                end
                if y !== nothing
                    typeinfo = get(io, :typeinfo, Any)
                    while true
                        x = y[1]
                        y = iterate(itr, y[2])
                        show(IOContext(recur_io, Pair{Symbol,Any}(:typeinfo, typeinfo)), x)
                        i1 += 1
                        if y === nothing || i1 > n
                            delim_one && first && print(io, delim)
                            break
                        end
                        first = false
                        print(io, delim)
                        print(io, ' ')
                    end
                end
            end
            print(io, cl)
        end
    end
end
