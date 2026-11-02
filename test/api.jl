using OMP

@testset "names" begin
    @test length(OMP.API) > 200
    for name in OMP.API
        @test name in names(OMP)
        @test getfield(OMP, name) === getfield(OMP.LibOMPABI, name)
    end
    @test :omp_get_num_threads in OMP.API && :omp_lock_t in OMP.API
    @test !any(startswith(string(n), "omp_abi_") for n in OMP.API)
    @test OMP.LibOMPABI.OMP_ABI_OPENMP_VERSION isa String

    @test OMP.has_routine(:omp_get_num_threads)
    @test OMP.has_routine("omp_get_wtime")
    @test !OMP.has_routine(:not_a_routine)
end

@testset "portable ABI" begin
    @test sizeof(omp_lock_t) == sizeof(omp_nest_lock_t) == 4 * sizeof(Ptr{Cvoid})
    @test sizeof(omp_depend_t) == 2 * sizeof(Ptr{Cvoid})
    @test sizeof(omp_allocator_handle_t) == sizeof(omp_memspace_handle_t) == sizeof(Ptr{Cvoid})
    @test Integer(omp_default_mem_space) == -1
    @test Integer(omp_atv_all) == 19
    @test Integer(omp_atv_device) == 7
    @test omp_initial_device == -1
    @test omp_interop_none == 0
    @test Integer(omp_sched_monotonic) == 0x80000000
end

@testset "sequential part" begin
    @test omp_get_num_threads() == 1
    @test omp_get_thread_num() == 0
    @test omp_in_parallel() == 0
    @test omp_get_level() == 0
    @test omp_get_max_threads() >= 1
    @test omp_get_num_procs() >= 1
    t = omp_get_wtime()
    @test omp_get_wtime() >= t
    @test omp_get_wtick() > 0
end

# Called by each OpenMP thread of a parallel region: records, at its thread number,
# (number of threads, in parallel, level).
function record(p::Ptr{NTuple{3,Cint}})
    t = omp_get_thread_num()
    unsafe_store!(p, (omp_get_num_threads(), omp_in_parallel(), omp_get_level()), t + 1)
    return nothing
end

@testset "parallel region" begin
    for n in (1, 3, 4)
        seen = fill((Cint(-1), Cint(-1), Cint(-1)), n)
        GC.@preserve seen OMP.LibOMPABI.omp_abi_parallel(
            @cfunction(record, Cvoid, (Ptr{NTuple{3,Cint}},)), pointer(seen), n, 0)
        # every thread ran, and saw the team; a team of 1 thread is not an active region
        @test all(==((n, n > 1, 1)), seen)
    end
end

@testset "ICVs" begin
    kind, chunk = Ref{omp_sched_t}(), Ref{Cint}()
    omp_get_schedule(kind, chunk)
    old = (kind[], chunk[])
    omp_set_schedule(omp_sched_dynamic, 7)
    omp_get_schedule(kind, chunk)
    @test (kind[], chunk[]) == (omp_sched_dynamic, 7)
    omp_set_schedule(old...)

    old = omp_get_max_threads()
    omp_set_num_threads(3)
    @test omp_get_max_threads() == 3
    omp_set_num_threads(old)

    @test omp_get_proc_bind() isa omp_proc_bind_t
end

@testset "locks" begin
    lk = Ref{omp_lock_t}()
    omp_init_lock(lk)
    @test omp_test_lock(lk) == 1
    @test omp_test_lock(lk) == 0
    omp_unset_lock(lk)
    omp_set_lock(lk)
    omp_unset_lock(lk)
    omp_destroy_lock(lk)

    nlk = Ref{omp_nest_lock_t}()
    omp_init_nest_lock_with_hint(nlk, omp_sync_hint_contended)
    @test omp_test_nest_lock(nlk) == 1
    @test omp_test_nest_lock(nlk) == 2  # nesting count
    omp_unset_nest_lock(nlk)
    omp_unset_nest_lock(nlk)
    omp_destroy_nest_lock(nlk)
end

@testset "memory" begin
    p = omp_alloc(64, omp_default_mem_alloc)
    @test p != C_NULL
    omp_free(p, omp_default_mem_alloc)

    traits = [omp_alloctrait_t(omp_atk_alignment, 256),
              omp_alloctrait_t(omp_atk_access, omp_atv_all),
              omp_alloctrait_t(omp_atk_fallback, omp_atv_null_fb)]
    a = omp_init_allocator(omp_default_mem_space, length(traits), traits)
    @test a != omp_null_allocator
    p = omp_aligned_alloc(16, 100, a)
    @test p != C_NULL && UInt(p) % 256 == 0
    omp_free(p, a)
    omp_destroy_allocator(a)

    old = omp_get_default_allocator()
    omp_set_default_allocator(omp_large_cap_mem_alloc)
    @test omp_get_default_allocator() == omp_large_cap_mem_alloc
    omp_set_default_allocator(old)
end

@testset "strings" begin
    buf = zeros(UInt8, 128)
    get_format() = GC.@preserve buf unsafe_string(pointer(buf), omp_get_affinity_format(pointer(buf), length(buf)))
    old = get_format()
    omp_set_affinity_format("thread %n")
    @test get_format() == "thread %n"
    omp_set_affinity_format(old)
end
