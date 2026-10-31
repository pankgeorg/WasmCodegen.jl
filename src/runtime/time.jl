# Time of day: `Libc.TimeVal()` from the host's real-time clock (WASI
# `clock_time_get`), and `Libc.TmStruct(t)` (C's `localtime_r`) as UTC: WASI has no time zone,
# so local time is UTC (`Dates.now()` is `Dates.now(UTC)`). Patched through twins
# (`trim/wasm-time.jl`); natively Base's own (the local time zone). `strftime`, `strptime` and
# `mktime` (C's) are not implemented (`Dates` formats and parses in Julia).

module Time

using ..Runtime: WASM_IMPLS, WASI, Staging, wasi_check
import ..Twins

@noinline timeval() = Twins.original(Base.Libc.TimeVal)::Base.Libc.TimeVal
function timeval_wasm()
    wasi_check(WASI.clock_time_get(WASI.CLOCK_REALTIME, UInt64(1000), Staging.SCRATCH_OUT), "clock_time_get")
    ns = Staging.load64(Staging.SCRATCH_OUT)
    return Base.Libc.TimeVal(Int64(div(ns, UInt64(1_000_000_000))), Int64(div(rem(ns, UInt64(1_000_000_000)), UInt64(1000))))
end

@noinline tmstruct(t::Real) = Twins.original(Base.Libc.TmStruct, t)::Base.Libc.TmStruct

"""
    utc_fields(t) -> (sec, min, hour, mday, month, year, wday, yday)

The broken-down UTC time of `t` seconds since the epoch, as `struct tm` has it (month from 0,
year since 1900, wday from Sunday, yday from 0): the proleptic Gregorian calendar
(H. Hinnant's `civil_from_days`).
"""
function utc_fields(t::Int64)
    days = fld(t, 86400)
    s = t - days * 86400
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y += m <= 2
    leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    cum = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334)
    yday = cum[m] + d - 1 + (leap && m > 2 ? 1 : 0)
    wday = mod(days + 4, 7)   # 1970-01-01 was a Thursday
    return (Int32(s % 60), Int32(div(s, 60) % 60), Int32(div(s, 3600)), Int32(d), Int32(m - 1),
            Int32(y - 1900), Int32(wday), Int32(yday))
end

# (the seconds as an integer, as C's time_t: exact for integers, floored for others)
function tmstruct_wasm(t::Real)
    f = utc_fields(t isa Integer ? Int64(t) : Int64(floor(t)))
    return Base.Libc.TmStruct(f..., Int32(0))
end

WASM_IMPLS[timeval] = timeval_wasm
WASM_IMPLS[tmstruct] = tmstruct_wasm

end # Time
