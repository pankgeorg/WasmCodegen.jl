# OpenLibm for Wasm, as data for a linker: an `AnyPlatform` JLL, the same bytes on every host.
baremodule OpenLibm_wasm_jll
using Base
using Base: UUID
import JLLWrappers

JLLWrappers.@generate_main_file_header("OpenLibm_wasm")
JLLWrappers.@generate_main_file("OpenLibm_wasm", UUID("2f0c4e6e-1d1a-4b7e-9c55-7a3e6d2b9f10"))
end  # module OpenLibm_wasm_jll
