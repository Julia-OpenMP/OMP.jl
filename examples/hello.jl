# Run with: julia --project=examples examples/hello.jl
# Remark: you can change the OpenMP implementation through `OMP_ABI=[gomp|kmp|xkomp|mpc]` environment variable
using OMP

@pragma "omp parallel num_threads(3)" begin
    println("hello from an OpenMP thread $(omp_get_thread_num()) (Julia thread id $(Threads.threadid()))")
end
