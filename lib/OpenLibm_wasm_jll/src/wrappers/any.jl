export libopenlibm_a

JLLWrappers.@generate_wrapper_header("OpenLibm_wasm")
JLLWrappers.@declare_file_product(libopenlibm_a)
function __init__()
    JLLWrappers.@generate_init_header()
    JLLWrappers.@init_file_product(libopenlibm_a, "lib/wasm64/libopenlibm.a")
    JLLWrappers.@generate_init_footer()
end  # __init__()
