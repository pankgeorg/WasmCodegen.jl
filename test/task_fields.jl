# The module's task starts with `nothing` in its Any-typed fields, as a new task does natively,
# so `task_local_storage` creates and finds its table.
function tls_counter(n::Int)
    key = :wasmcodegen_test_tls_key
    task_local_storage(key, Ref(0))
    for i in 1:n
        (task_local_storage(key)::Base.RefValue{Int})[] += i
    end
    return (task_local_storage(key)::Base.RefValue{Int})[]
end

@testset "task-local storage" begin
    @wtest tls_counter(10)
end
