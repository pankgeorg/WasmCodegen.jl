# A WASI program for the Worker: its environment, the time of day, and a filesystem without
# preopened directories (a file is not found).

const ENV_PREFIX = "WCG_"

env_clock_text(now::Float64) =
    string("env ", join(sort([string(k, "=", v) for (k, v) in ENV if startswith(k, ENV_PREFIX)]), ","),
           "\nunset ", haskey(ENV, "WCG_UNSET"),
           "\nclock within a minute of the host's ", abs(time() - now) < 60,
           "\nmonotonic ", (t = time_ns(); time_ns() >= t),
           "\nfile ", isfile("/wcg/no/such/file"),
           "\nopen ", try
               close(open("/wcg/no/such/file")); "opened"
           catch e
               e isa SystemError ? "SystemError" : e isa Base.IOError ? "IOError" : "another exception"
           end, "\n")

env_clock(now::Float64) = (print(Core.stdout, env_clock_text(now)); Int32(0))
