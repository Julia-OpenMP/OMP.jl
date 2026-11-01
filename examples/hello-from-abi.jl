# Run with: julia --project=examples examples/hello-from-abi.jl
using OMP

println("omp-abi backend: $(OMP.backend()) (dialect: $(OMP.dialect()))")

function hello(::Ptr{Cvoid})
    println("hello from an OpenMP thread (Julia thread id $(Threads.threadid()))")
    return nothing
end

OMP.LibOMPABI.omp_abi_parallel(@cfunction(hello, Cvoid, (Ptr{Cvoid},)), C_NULL, 4, 0)
