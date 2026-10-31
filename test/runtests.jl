using Test
using OMP
using Aqua

const LibOMPABI = OMP.LibOMPABI

# Called by each OpenMP thread: atomically increment the counter `p` points to.
# (round-tripping a local object through pointer_from_objref crashes Julia 1.13)
increment(p::Ptr{Int}) = (unsafe_modify!(p, +, 1, :sequentially_consistent); nothing)

# number of threads that ran `omp_abi_parallel` with `num_threads`
function parallel_count(num_threads)
    counter = Int[0]
    GC.@preserve counter LibOMPABI.omp_abi_parallel(@cfunction(increment, Cvoid, (Ptr{Int},)),
                                                    pointer(counter), num_threads, 0)
    return counter[]
end

@testset "OMP.jl" begin
    @testset "frontend" begin
        include("frontend.jl")
    end

    @testset "Aqua" begin
        Aqua.test_all(OMP)
    end

    @testset "omp-abi backend" begin
        @test OMP.backend() in ("llvm", "gcc", "xkomp", "mpc")
        @test OMP.dialect() in ("kmp", "gomp")
    end

    @testset "omp-abi parallel" begin
        @test parallel_count(1) == 1
        @test parallel_count(4) == 4
        @test all(parallel_count(8) == 8 for _ in 1:100)
    end
end
