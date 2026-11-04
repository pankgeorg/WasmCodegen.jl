# Regular expressions: Base's `Regex` is PCRE2's, a C library; here its functions (the
# `pcre2_*_8` foreign calls of Base's `pcre.jl`, see `RUNTIME_CCALLS`) are the host's regex
# engine, through the `julia_regex` imports (specified in `js/julia_regex.mjs`, which implements
# them for JavaScript): the host translates the pattern to its own syntax (V8's `RegExp`), and
# matches with UTF-8 byte offsets. Base's
# `regex.jl` and `pcre.jl` are unchanged but for `get_local_match_context` (`wasm-regex.jl`).
#
# The pointers PCRE2 hands out are pointers to objects of this module: a compiled pattern
# (`Code`) and a match's data (`MatchData`), made by `pointer_from_objref` and taken back by
# `unsafe_pointer_to_objref`, so that the `Regex` holding one keeps it alive (no finalizer
# ever runs). The ovector and the name table are Julia arrays, which Base reads through the
# pointers to them.

"""
    HostRegex

The `pcre2_*_8` functions Base calls, on the host's regex engine (the `julia_regex` imports).
"""
module HostRegex

using ..Staging

# the `julia_regex` imports (scalar arguments; records in the linear memory)
compile_import(pat_off::UInt32, pat_len::UInt32, options::UInt32, out_off::UInt32, out_cap::UInt32) =
    ccall((:compile, "julia_regex"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32),
          pat_off, pat_len, options, out_off, out_cap)
subject_import(off::UInt32, len::UInt32, append::Int32) =
    ccall((:subject, "julia_regex"), Int32, (UInt32, UInt32, Int32), off, len, append)
match_import(h::Int32, start::UInt32, options::UInt32, out_off::UInt32, out_cap::UInt32) =
    ccall((:match, "julia_regex"), Int32, (Int32, UInt32, UInt32, UInt32, UInt32),
          h, start, options, out_off, out_cap)
errmsg_import(out_off::UInt32, cap::UInt32) =
    ccall((:errmsg, "julia_regex"), Int32, (UInt32, UInt32), out_off, cap)

# WASI errnos the imports return (negated)
const EBADF = Int32(8)
const EINVAL = Int32(28)
const ENOBUFS = Int32(42)

# PCRE2's error codes Base sees
const ERROR_NOMATCH = Int32(-1)
const ERROR_BADOFFSET = Int32(-33)
const ERROR_BADDATA = Int32(-29)
const ERROR_NOSUBSTRING = Int32(-49)
const ERROR_UNSET = Int32(-55)
const ERROR_NOMEMORY = Int32(-48)
# not PCRE2's: an error of the host's engine, whose message is the host's
const ERROR_HOST = Int32(-1000)

const INFO_CAPTURECOUNT = UInt32(4)
const INFO_NAMECOUNT = UInt32(17)
const INFO_NAMEENTRYSIZE = UInt32(18)
const INFO_NAMETABLE = UInt32(19)

"A compiled pattern: the host's handle, its captures, and PCRE2's name table."
mutable struct Code
    handle::Int32
    ncap::UInt32
    names::Vector{String}          # by name, as the name table
    groups::Vector{UInt32}
    entrysize::UInt32
    nametable::Vector{UInt8}       # PCRE2's layout: 2 bytes (big-endian group), name, NUL, padding
end

"A match's data: the ovector (byte offsets; `typemax(UInt)` unset), and the subject it is of."
mutable struct MatchData
    code::Code
    ovector::Vector{UInt}
    subject::Ptr{UInt8}
    subject_len::UInt
end

# the message of the last error the host reported, by its code (`pcre2_get_error_message_8`)
const LAST_CODE = Ref{Int32}(0)
const LAST_MESSAGE = Ref{String}("")

function set_error!(code::Integer, msg::String)
    LAST_CODE[] = Int32(code)
    LAST_MESSAGE[] = msg
    return nothing
end

# the host's last error message
host_message() = Staging.with_scope(host_message_scoped)
function host_message_scoped()
    off = Staging.alloc_record(1024; align=1)
    n = errmsg_import(off, UInt32(1024))
    buf = Vector{UInt8}(undef, max(Int(n), 0))
    Staging.copy_from_linear!(buf, 1, off, length(buf))
    return String(buf)
end

code_of(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::Code
data_of(p::Ptr{Cvoid}) = unsafe_pointer_to_objref(p)::MatchData

## compiling

"`pcre2_compile_8(pattern, length, options, errorcode, erroroffset, ccontext)`"
function compile(pattern::Ptr{UInt8}, len::UInt, options::UInt32, errorcode::Ptr{Cint},
                 erroroffset::Ptr{UInt}, ccontext::Ptr{Cvoid})
    cap = 4096
    while true
        need, code = Staging.with_scope(() -> compile_scoped(pattern, len, options, errorcode, erroroffset, cap))
        need == 0 && return code
        cap = need
    end
end

# one attempt, with an output record of `cap` bytes: (0, the pointer or null), or (the size
# the record needs, null)
function compile_scoped(pattern::Ptr{UInt8}, len::UInt, options::UInt32, errorcode::Ptr{Cint},
                        erroroffset::Ptr{UInt}, cap::Int)
    pat = Staging.alloc_data(Int(len); align=1)
    Staging.copy_ptr_to_linear!(pat, pattern, Int(len))
    out = Staging.alloc_record(cap)
    h = compile_import(pat, UInt32(len), options, out, UInt32(cap))
    if h == -ENOBUFS
        return (Int(Staging.get_u32(out)), C_NULL)
    elseif h == -EINVAL
        code = Int32(Staging.get_u32(out))
        at = Staging.get_u32(out + UInt32(4))
        msg, _ = Staging.get_str(out + UInt32(8))
        return (0, compile_failed(errorcode, erroroffset, code, at, msg))
    elseif h < 0
        return (0, compile_failed(errorcode, erroroffset, ERROR_HOST, 0, host_message()))
    end
    return (0, pointer_from_objref(read_code(h, out)))
end

function compile_failed(errorcode::Ptr{Cint}, erroroffset::Ptr{UInt}, code::Integer, at::Integer, msg::String)
    set_error!(code, msg)
    (unsafe_pointer_to_objref(errorcode)::Base.RefValue{Cint})[] = Cint(code)
    (unsafe_pointer_to_objref(erroroffset)::Base.RefValue{UInt})[] = UInt(at)
    return C_NULL
end

# the compile record: u32 ncap, u32 nnames, (u32 group, str name)*
function read_code(h::Int32, out::UInt32)
    ncap = Staging.get_u32(out)
    n = Int(Staging.get_u32(out + UInt32(4)))
    names = String[]
    groups = UInt32[]
    off = out + UInt32(8)
    for _ in 1:n
        g = Staging.get_u32(off)
        name, off = Staging.get_str(off + UInt32(4))
        push!(names, name)
        push!(groups, g)
    end
    # PCRE2's name table, sorted by name
    perm = sortperm(names)
    names, groups = names[perm], groups[perm]
    entrysize = UInt32(3 + maximum(sizeof, names; init=0))
    table = zeros(UInt8, Int(entrysize) * n)
    for k in 1:n
        base = (k - 1) * Int(entrysize)
        table[base+1] = UInt8(groups[k] >> 8)
        table[base+2] = UInt8(groups[k] & 0xff)
        cu = codeunits(names[k])
        for j in 1:length(cu)
            table[base+2+j] = cu[j]
        end
    end
    return Code(h, ncap, names, groups, entrysize, table)
end

"`pcre2_jit_compile_8(code, options)`: nothing to do (the host compiles)."
jit_compile(code::Ptr{Cvoid}, options::UInt32) = Cint(0)

"`pcre2_code_free_8(code)`: the object is collected (and the host keeps its handle)."
code_free(code::Ptr{Cvoid}) = nothing

"`pcre2_pattern_info_8(code, what, where)`"
function pattern_info(code::Ptr{Cvoid}, what::UInt32, where::Ptr{Cvoid})
    c = code_of(code)
    buf = unsafe_pointer_to_objref(where)
    if what == INFO_CAPTURECOUNT || what == INFO_NAMECOUNT || what == INFO_NAMEENTRYSIZE
        v = what == INFO_CAPTURECOUNT ? c.ncap : what == INFO_NAMECOUNT ? UInt32(length(c.names)) : c.entrysize
        (buf::Base.RefValue{UInt32})[] = v
        return Cint(0)
    elseif what == INFO_NAMETABLE
        (buf::Base.RefValue{Ptr{UInt8}})[] = pointer(c.nametable)
        return Cint(0)
    end
    error("PCRE pattern information $what is not available in Wasm (julia_regex)")
end

"`pcre2_substring_number_from_name_8(code, name)`"
function substring_number_from_name(code::Ptr{Cvoid}, name::Cstring)
    c = code_of(code)
    s = Runtime_cstr(name)
    for k in 1:length(c.names)
        c.names[k] == s && return Cint(c.groups[k])
    end
    return Cint(ERROR_NOSUBSTRING)
end

Runtime_cstr(p::Cstring) = unsafe_string(convert(Ptr{UInt8}, p))

## matching

"`pcre2_match_data_create_from_pattern_8(code, gcontext)`"
function match_data_create(code::Ptr{Cvoid}, gcontext::Ptr{Cvoid})
    c = code_of(code)
    md = MatchData(c, fill(typemax(UInt), 2 * (Int(c.ncap) + 1)), Ptr{UInt8}(0), UInt(0))
    return pointer_from_objref(md)
end

"`pcre2_match_data_free_8(match_data)`: the object is collected."
match_data_free(md::Ptr{Cvoid}) = nothing

"`pcre2_get_ovector_pointer_8(match_data)`"
ovector_pointer(md::Ptr{Cvoid}) = pointer(data_of(md).ovector)

"`pcre2_get_ovector_count_8(match_data)`"
ovector_count(md::Ptr{Cvoid}) = UInt32(data_of(md).code.ncap + 1)

"`pcre2_match_8(code, subject, length, startoffset, options, match_data, mcontext)`"
function match(code::Ptr{Cvoid}, subject::Ptr{UInt8}, len::UInt, start::UInt, options::UInt32,
               md::Ptr{Cvoid}, mcontext::Ptr{Cvoid})
    c = code_of(code)
    d = data_of(md)
    start > len && return ERROR_BADOFFSET
    # the subject, in chunks of the data arena
    i = 0
    while true
        k = min(Int(len) - i, Int(Staging.CHUNK))
        st = let p = subject + i, k = k, first = i == 0   # (not capturing `i`, which changes)
            Staging.with_scope(() -> send_subject(p, k, first))
        end
        if st != 0
            # (the host's staged subject is incomplete: the next upload starts a new one)
            set_error!(ERROR_HOST, string("Wasm regex (julia_regex): staging the subject failed: ", host_message()))
            return ERROR_HOST
        end
        i += k
        i >= Int(len) && break
    end
    rc = Staging.with_scope(() -> match_scoped(c, d, start, options))
    d.subject = subject
    d.subject_len = len
    rc > 0 && return rc
    rc == 0 && return ERROR_NOMATCH
    rc == -EINVAL && return ERROR_BADOFFSET
    set_error!(ERROR_HOST, string("Wasm regex (julia_regex): ", host_message()))
    return ERROR_HOST
end

# a chunk of the subject to the host: its status (0, or a WASI errno)
function send_subject(p::Ptr{UInt8}, k::Int, first::Bool)
    off = Staging.alloc_data(k; align=1)
    Staging.copy_ptr_to_linear!(off, p, k)
    return subject_import(off, UInt32(k), Int32(first ? 0 : 1))
end

# the host's match, its ovector copied to the match data's: the host's result
function match_scoped(c::Code, d::MatchData, start::UInt, options::UInt32)
    n = 2 * (Int(c.ncap) + 1)
    out = Staging.alloc_record(4n)
    rc = match_import(c.handle, UInt32(start), options, out, UInt32(4n))
    if rc > 0
        for j in 1:n
            v = Staging.get_u32(out + UInt32(4(j - 1)))
            @inbounds d.ovector[j] = v == typemax(UInt32) ? typemax(UInt) : UInt(v)
        end
    end
    return rc
end

"`pcre2_substring_length_bynumber_8(match_data, number, length)`"
function substring_length_bynumber(md::Ptr{Cvoid}, number::Cint, len::Ptr{UInt})
    d = data_of(md)
    0 <= number <= d.code.ncap || return Cint(ERROR_NOSUBSTRING)
    a, b = d.ovector[2number+1], d.ovector[2number+2]
    a == typemax(UInt) && return Cint(ERROR_UNSET)
    (unsafe_pointer_to_objref(len)::Base.RefValue{UInt})[] = b - a
    return Cint(0)
end

"`pcre2_substring_copy_bynumber_8(match_data, number, buffer, bufflen)`"
function substring_copy_bynumber(md::Ptr{Cvoid}, number::UInt32, buffer::Ptr{UInt8}, bufflen::Ptr{UInt})
    d = data_of(md)
    number <= d.code.ncap || return Cint(ERROR_NOSUBSTRING)
    a, b = d.ovector[2number+1], d.ovector[2number+2]
    a == typemax(UInt) && return Cint(ERROR_UNSET)
    lenref = unsafe_pointer_to_objref(bufflen)::Base.RefValue{UInt}
    n = b - a
    n + 1 > lenref[] && return Cint(ERROR_NOMEMORY)
    for k in UInt(1):n
        unsafe_store!(buffer, unsafe_load(d.subject, a + k), k)
    end
    unsafe_store!(buffer, 0x00, n + 1)
    lenref[] = n
    return Cint(0)
end

## errors

const MESSAGES = (ERROR_NOMATCH => "no match", ERROR_BADOFFSET => "bad offset value",
                  ERROR_NOSUBSTRING => "unknown substring", ERROR_UNSET => "requested value is not set",
                  ERROR_NOMEMORY => "no more memory")

"""
`pcre2_get_error_message_8(errorcode, buffer, bufflen)`: the message, NUL-terminated, and its
length; `PCRE2_ERROR_NOMEMORY` if it doesn't fit (truncated, as PCRE2 does, when `bufflen > 0`).
"""
function get_error_message(errorcode::Cint, buffer::Ptr{UInt8}, bufflen::UInt)
    msg = errorcode == LAST_CODE[] ? LAST_MESSAGE[] : ""
    if isempty(msg)
        for (c, m) in MESSAGES
            c == errorcode && (msg = m)
        end
    end
    isempty(msg) && return Cint(ERROR_BADDATA)
    bufflen == 0 && return Cint(ERROR_NOMEMORY)
    cu = codeunits(msg)
    n = min(length(cu), Int(bufflen) - 1)
    for k in 1:n
        unsafe_store!(buffer, cu[k], k)
    end
    unsafe_store!(buffer, 0x00, n + 1)
    return n < length(cu) ? Cint(ERROR_NOMEMORY) : Cint(n)
end

end # HostRegex
