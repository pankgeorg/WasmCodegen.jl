# The consumer: OpenLibm's functions through OpenLibm_jll's own binding, nothing Wasm in it.
using OpenLibm_jll

const XS = Float64[-1e300, -1e5, -123.456, -3.5, -1.0, -0.75, -0.1, -1e-300, 0.0, 1e-300, 1e-10, 0.1, 0.5, 0.75, 1.0,
                   1.5, 2.0, 3.5, 10.0, 123.456, 1e5, 1e15, 1e300, Inf, -Inf, NaN]
mix(h::UInt64, x::UInt64) = (h ⊻ x) * 0x100000001b3

for f in (:sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh, :tanh, :exp, :log, :log2, :log10, :log1p, :expm1,
          :cbrt, :erf, :erfc, :lgamma, :tgamma, :j0, :y0, :floor, :rint)
    @eval function $(Symbol(:d_, f))()
        h = 0xcbf29ce484222325
        for x in XS
            h = mix(h, reinterpret(UInt64, ccall(($(QuoteNode(f)), OpenLibm_jll.libopenlibm), Cdouble, (Cdouble,), x)))
        end
        return h
    end
end
for f in (:pow, :atan2, :fmod, :hypot, :copysign)
    @eval function $(Symbol(:d_, f))()
        h = 0xcbf29ce484222325
        for x in XS, y in XS
            h = mix(h, reinterpret(UInt64, ccall(($(QuoteNode(f)), OpenLibm_jll.libopenlibm), Cdouble, (Cdouble, Cdouble), x, y)))
        end
        return h
    end
end
for f in (:sinf, :expf, :logf)
    @eval function $(Symbol(:f_, f))()
        h = 0xcbf29ce484222325
        for x in XS
            h = mix(h, UInt64(reinterpret(UInt32, ccall(($(QuoteNode(f)), OpenLibm_jll.libopenlibm), Cfloat, (Cfloat,), Float32(x)))))
        end
        return h
    end
end
function i_ilogb()
    h = 0xcbf29ce484222325
    for x in XS
        isfinite(x) && x != 0 && (h = mix(h, reinterpret(UInt64, Int64(ccall((:ilogb, OpenLibm_jll.libopenlibm), Cint, (Cdouble,), x)))))
    end
    return h
end
function i_ldexp()
    h = 0xcbf29ce484222325
    for x in XS, e in (Cint(-1000), Cint(-3), Cint(0), Cint(5), Cint(1000))
        h = mix(h, reinterpret(UInt64, ccall((:ldexp, OpenLibm_jll.libopenlibm), Cdouble, (Cdouble, Cint), x, e)))
    end
    return h
end
function i_scalbln()
    h = 0xcbf29ce484222325
    for x in XS, e in (-1000, -3, 0, 5, 1000)
        h = mix(h, reinterpret(UInt64, ccall((:scalbln, OpenLibm_jll.libopenlibm), Cdouble, (Cdouble, Clong), x, e)))
    end
    return h
end
# (by a string, as some bindings name them)
s_name() = reinterpret(UInt64, ccall(("sin", OpenLibm_jll.libopenlibm), Cdouble, (Cdouble,), 0.5))

const CONSUMERS = Function[d_sin, d_cos, d_tan, d_asin, d_acos, d_atan, d_sinh, d_cosh, d_tanh, d_exp, d_log, d_log2, d_log10,
                           d_log1p, d_expm1, d_cbrt, d_erf, d_erfc, d_lgamma, d_tgamma, d_j0, d_y0, d_floor, d_rint,
                           d_pow, d_atan2, d_fmod, d_hypot, d_copysign, f_sinf, f_expf, f_logf,
                           i_ilogb, i_ldexp, i_scalbln, s_name]
