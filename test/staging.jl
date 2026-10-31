# The runtime's linear memory (`Runtime.Staging`, from the second page) and WASI's functions
# called by `ccall` (imports for `Config(host = :wasi)`): loads and stores (checked as
# natively), the scoped arenas, records, a WASI call and its errors; the memory's size.

module StagingTests

using Test
using ..Main: wasm_run, WasmCodegen
const S = WasmCodegen.Runtime.Staging
const R = WasmCodegen.Runtime

wcfg = WasmCodegen.Config(host=:wasi)
wcomp(f, at) = WasmCodegen.compile(f, at; config=wcfg)

# loads and stores of each width, little-endian, and the bounds check (an ArgumentError, catchable)
function st_roundtrip(x::UInt64)
    off = S.SCRATCH_OUT
    S.store64(off, x)
    a = S.load8(off); b = S.load16(off + 0x2); c = S.load32(off + 0x4)
    S.store32(off + 0x8, 0xdeadbeef)
    S.store16(off + 0xc, 0xbeef)
    S.store8(off + 0xe, 0x5a)
    return (a, b, c, S.load64(off), S.load32(off + 0x8), S.load16(off + 0xc), S.load8(off + 0xe))
end
function st_bounds(k::Int)
    try
        k == 1 ? S.load32(S.SIZE - 0x2) : k == 2 ? S.store8(S.SIZE, 0x01) :
            k == 3 ? S.store16(S.SIZE - 0x1, 0x0101) : S.load64(S.SIZE - 0x4)
        return 0
    catch e
        return e isa ArgumentError ? 1 : 2
    end
end
# (a scope that throws: released)
@noinline function st_throwing_scope()
    try
        S.with_scope() do
            S.alloc_record(100)
            error("inside")
        end
    catch
        return true
    end
    return false
end
@noinline function st_overflow()
    try
        S.with_scope(() -> S.alloc_data(Int(S.CHUNK) + 1))
    catch e
        return e isa ErrorException
    end
    return false
end
# the arenas: scoped, nested, released on a throw; records (u32s and strs)
function st_arenas(n::Int)
    used0 = (S.load32(S.RECORD_USED), S.load32(S.DATA_USED))
    r = S.with_scope() do
        p = string("path/", n)
        a = S.alloc_record(4 + sizeof(p) + 4)
        b = S.alloc_record(4)
        S.put_u32!(b, 0xffffffff)
        off = S.put_str!(a, p)
        S.put_u32!(off, UInt32(n))
        s, next = S.get_str(a)
        S.get_u32(b) == 0xffffffff || error("records overlap")
        d = S.alloc_data(1000; align=8)
        inner = S.with_scope(() -> S.alloc_data(16)) 
        (s == p, Int(S.get_u32(next)), d % 8, inner > d)
    end
    caught = st_throwing_scope()
    overflow = st_overflow()
    return (r..., caught, overflow, (S.load32(S.RECORD_USED), S.load32(S.DATA_USED)) == used0)
end
# a WASI function: the real-time clock, through the scratch region
function st_clock()
    R.wasi_check(R.WASI.clock_time_get(R.WASI.CLOCK_REALTIME, UInt64(1000), S.SCRATCH_OUT), "clock_time_get")
    return S.load64(S.SCRATCH_OUT) > 0x16345785d8a0000   # (after 2017)
end
# a WASI error as libuv's: an invalid clock id is EINVAL
function st_wasi_error()
    try
        R.wasi_check(R.WASI.clock_time_get(UInt32(99), UInt64(1), S.SCRATCH_OUT), "clock_time_get")
        return ""
    catch e
        return e isa Base.IOError && e.msg == "clock_time_get: invalid argument (EINVAL)" ? "ok" : "other"
    end
end
st_wasi_error_ok() = st_wasi_error() == "ok"
# Every WASI error goes through the same check and formatting natively and in Wasm.
function st_errno(e::Int32)
    try
        R.wasi_check(e, "probe")
        return (Int32(0), UInt64(0))
    catch err
        err isa Base.IOError || return (Int32(1), UInt64(0))
        h = foldl((h, b) -> h * 31 + b, codeunits(err.msg); init=UInt64(0))
        return (Int32(err.code), h)
    end
end
st_guest_errno(e::Int32) = R.Errno.guest_errno(e)
st_uv_guest(code::Int32) = R.Errno.uv_to_guest_errno(code)
st_synthetic_uv(code::Int32) = R.Errno._uv_to_guest_errno(code, Int32[-7001, -7002], Int32[13, 36])
function st_guest_error(e::Int32)
    try
        throw(SystemError("probe", Int(R.Errno.guest_errno(e))))
    catch err
        err isa SystemError || return (Int32(-1), UInt64(0))
        msg = R.Errno.strerror(err.errnum)
        h = foldl((h, b) -> h * 31 + b, codeunits(msg); init=UInt64(0))
        return (Int32(err.errnum), h)
    end
end
plain(x::Int) = x + 1
# a WASI call whose pointer is in the runtime's part, without a load or store of it
scratch_only() = R.WASI.clock_time_get(R.WASI.CLOCK_REALTIME, UInt64(1000), S.SCRATCH_OUT)

@testset "linear memory and WASI calls" begin
    for x in (0x0102030405060708, typemax(UInt64))
        c = wcomp(st_roundtrip, (UInt64,))
        @test wasm_run(c, "st_roundtrip", x; rettype=Tuple{UInt8,UInt16,UInt32,UInt64,UInt32,UInt16,UInt8}) == st_roundtrip(x)
    end
    for k in 1:4
        @test st_bounds(k) == 1
        @test wasm_run(wcomp(st_bounds, (Int,)), "st_bounds", k; rettype=Int) == 1
    end
    for n in (0, 7)
        expected = st_arenas(n)
        @test expected == (true, n, 0, true, true, true, true)
        @test wasm_run(wcomp(st_arenas, (Int,)), "st_arenas", n; rettype=typeof(expected)) == expected
    end
    @test wasm_run(wcomp(st_clock, ()), "st_clock"; rettype=Bool)
    @test wasm_run(wcomp(st_wasi_error_ok, ()), "st_wasi_error_ok"; rettype=Bool)
    # the memory: the host interface's page, and the runtime's when it is used
    @test wcomp(plain, (Int,)).cgm.mod.memory.min == 1
    @test wcomp(st_clock, ()).cgm.mod.memory.min == S.PAGES
    # (a WASI call whose pointer is in the runtime's part, without a load or store of it)
    c = wcomp(scratch_only, ())
    @test c.cgm.mod.memory.min == S.PAGES
    @test wasm_run(c, "scratch_only"; rettype=Int32) == 0
    # (none for JavaScript: unsupported)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(st_clock, (); config=WasmCodegen.Config(host=:js))
    # the errno tables, as libuv's and the C library's
    E = R.Errno
    c = wcomp(st_errno, (Int32,))
    for e in vcat(Int32.(-1:76), Int32[77, typemax(Int32)])
        expected = if e == 0
            Int32(0)
        elseif 1 <= e <= 76
            name = e == 76 ? :EACCES : E.WASI_NAMES[e+1]
            uv = Symbol(:UV_, name)
            isdefined(Base, uv) ? Int32(getglobal(Base, uv)) : Int32(Base.UV_EIO)
        else
            Int32(Base.UV_EIO)
        end
        @test E.uv_code(e) == expected
        native = st_errno(e)
        @test native[1] == expected
        @test wasm_run(c, "st_errno", e; rettype=Tuple{Int32,UInt64}) == native
        if e != 0
            @test E.uv_message(expected) == Base.struverror(expected)
            @test E.uv_name(expected) == Base.uverrorname(expected)
        end
    end
    @test E.uv_message(Base.UV_EOF) == "end of file"
    @test E.uv_name(Base.UV_EOF) == "EOF"
    # Guest errno and strerror always use the same fixed Linux ABI, even when
    # the build libc or libuv uses different numbering. EBADMSG and EOWNERDEAD
    # also demonstrate why a direct WASI conversion must precede any UV fallback.
    c = wcomp(st_guest_error, (Int32,))
    for (wasi, guest, message) in ((2, 13, "Permission denied"), (9, 74, "Bad message"),
        (37, 36, "File name too long"), (55, 39, "Directory not empty"),
        (58, 95, "Operation not supported"), (61, 75, "Value too large for defined data type"),
        (62, 130, "Owner died"), (76, 13, "Permission denied"),
        (-1, 5, "Input/output error"), (77, 5, "Input/output error"))
        @test E.guest_errno(wasi) == guest
        @test E.strerror(guest) == message
        expected = (Int32(guest), foldl((h, b) -> h * 31 + b, codeunits(message); init=UInt64(0)))
        @test st_guest_error(Int32(wasi)) == expected
        @test wasm_run(c, "st_guest_error", Int32(wasi); rettype=Tuple{Int32,UInt64}) == expected
    end
    @test E.guest_errno(0) == 0
    @test E.uv_to_guest_errno(0) == 0
    @test E.uv_to_guest_errno(E.uv_code(9)) == 5
    @test E.uv_to_guest_errno(E.uv_code(62)) == 5
    @test E.strerror(108) == "Cannot send after transport endpoint shutdown"
    @test E.strerror(-1) == "Unknown error -1"
    @test E.strerror(134) == "Unknown error 134"
    if Sys.islinux()
        # Independent native libc oracle on the validated Linux build profile.
        for e in 0:133
            @test E.strerror(e) == R.Twins.original(Base.Libc.strerror, Int32(e))
        end
        c = wcomp(st_guest_errno, (Int32,))
        for (i, name) in enumerate(E.WASI_NAMES)
            native_name = name === :ENOTCAPABLE ? :EACCES : name
            isdefined(Base.Libc, native_name) || continue
            expected = Int32(getglobal(Base.Libc, native_name))
            @test st_guest_errno(Int32(i-1)) == expected
            @test wasm_run(c, "st_guest_errno", Int32(i-1); rettype=Int32) == expected
        end
    end
    c = wcomp(st_uv_guest, (Int32,))
    for (code, expected) in ((Base.UV_EACCES, 13), (Base.UV_ENAMETOOLONG, 36),
        (Base.UV_ENOTEMPTY, 39), (Base.UV_EOVERFLOW, 75), (Base.UV_ESPIPE, 29),
        (Base.UV_ESHUTDOWN, 108), (Base.UV_ENODATA, 61), (Base.UV_EOF, 5),
        (Base.UV_UNKNOWN, 5), (0, 0), (-123456, 5))
        @test st_uv_guest(Int32(code)) == expected
        @test wasm_run(c, "st_uv_guest", Int32(code); rettype=Int32) == expected
    end
    c = wcomp(st_synthetic_uv, (Int32,))
    for (code, expected) in ((-7001, 13), (-7002, 36), (0, 0), (-7003, 5))
        @test st_synthetic_uv(Int32(code)) == expected
        @test wasm_run(c, "st_synthetic_uv", Int32(code); rettype=Int32) == expected
    end

end

end
