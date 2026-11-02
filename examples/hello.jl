# Run with: julia --project=examples examples/hello.jl
using OMP

@pragma "omp parallel num_threads(3)" begin
    println("hello from an OpenMP thread $(omp_get_thread_num()) (Julia thread id $(Threads.threadid()))")
end
