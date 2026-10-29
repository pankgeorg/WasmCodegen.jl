# The pseudo-runtime's paths: Base splits paths with regular expressions, which are PCRE's
# (a C library); here the same splits by their bytes (Unix paths, whose separator is '/').
# Applied with juliac's trim patches (see `patches.jl`).

@static if Sys.isunix()
    @eval Base.Filesystem begin
        # `r"^(.*?)(/+)([^/]*)$"`: the last run of separators, and the name after it
        function _splitdir_nodrive(a::String, b::String)
            cu = codeunits(b)
            k = length(cu)
            while k > 0 && cu[k] != UInt8('/')
                k -= 1
            end
            k == 0 && return (a, b)
            j = k
            while j > 1 && cu[j-1] == UInt8('/')
                j -= 1
            end
            return string(a, j == 1 ? "/" : String(cu[1:j-1])), String(cu[k+1:end])
        end
        # `r"^((?:.*/)?(?:\.|[^/\.])[^/]*?)(\.[^/\.]*|)$"`: from the last dot of the name, unless
        # the name starts with it
        function splitext(path::String)
            a, b = splitdrive(path)
            cu = codeunits(b)
            d = length(cu)
            while d > 0 && cu[d] != UInt8('.') && cu[d] != UInt8('/')
                d -= 1
            end
            (d <= 1 || cu[d] == UInt8('/') || cu[d-1] == UInt8('/')) && return (path, "")
            return a * String(cu[1:d-1]), String(cu[d:end])
        end
        # `split(path, r"/+"; keepempty=false)`: the components, by the separator's byte
        function normpath(path::String)
            isabs = isabspath(path)
            isdir = isdirpath(path)
            drive, path = splitdrive(path)
            # (Strings: deleting from a vector of SubStrings does not compile)
            parts = String[String(p) for p in eachsplit(path, '/'; keepempty=false)]
            filter!(!=("."), parts)
            while true
                clean = true
                for j = 1:length(parts)-1
                    if parts[j] != ".." && parts[j+1] == ".."
                        deleteat!(parts, j:j+1)
                        clean = false
                        break
                    end
                end
                clean && break
            end
            if isabs
                while !isempty(parts) && parts[1] == ".."
                    popfirst!(parts)
                end
            elseif isempty(parts)
                push!(parts, ".")
            end
            path = join(parts, path_separator)
            if isabs
                path = path_separator*path
            end
            if isdir && !isdirpath(path)
                path *= path_separator
            end
            string(drive, path)
        end
        # `r"(?:^|/)\.{0,2}$"`
        function isdirpath(path::String)
            cu = codeunits(path)
            k = length(cu)
            while k > 0 && cu[k] == UInt8('.') && length(cu) - k < 2
                k -= 1
            end
            return k == 0 || cu[k] == UInt8('/')
        end
    end
end
