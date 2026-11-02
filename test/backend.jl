using OMP
using OMP.Frontend: split_compound, UnsupportedDirectiveError

lowering_error(ex) = try
    macroexpand(@__MODULE__, ex)
    nothing
catch e
    e isa LoadError ? e.error : e
end

@testset "split compound" begin
    d = OMP.Frontend.@pragma_ir "omp parallel for reduction(+: s) private(i) firstprivate(j) if(parallel: c) num_threads(2) lastprivate(k)" for i in 1:2 end
    outer, inner = split_compound(d)
    names(d) = Set(c.spec.name for c in d.clauses)
    @test outer.name === :parallel && inner.name === :for && inner.body === d.body
    @test names(outer) == Set([:if, :num_threads, :shared])
    @test Set(OMP.Frontend.list_items(OMP.Frontend.clause(outer, :shared))) == Set([:s, :j, :k])
    @test names(inner) == Set([:reduction, :private, :firstprivate, :lastprivate])

    d = OMP.Frontend.@pragma_ir "omp parallel masked firstprivate(x) reduction(+: s) filter(1)" begin end
    outer, inner = split_compound(d)
    @test names(outer) == Set([:firstprivate, :reduction]) && names(inner) == Set([:filter])
end

@testset "team" begin
    for n in (1, 2, 4)
        seen = zeros(Int, n)
        @pragma "omp parallel num_threads(n)" begin
            seen[omp_get_thread_num()+1] = omp_get_num_threads()
        end
        @test seen == fill(n, n)
    end
    active = omp_get_max_active_levels()
    omp_set_max_active_levels(2)
    levels = zeros(Int, 4)
    @pragma "omp parallel num_threads(2)" begin
        outer = omp_get_thread_num()
        @pragma "omp parallel num_threads(2)" begin
            levels[2outer+omp_get_thread_num()+1] = omp_get_active_level()
        end
    end
    omp_set_max_active_levels(active)
    @test levels == fill(2, 4)
end

@testset "if" begin
    for c in (true, false)
        k = Threads.Atomic{Int}(0)
        @pragma "omp parallel num_threads(3) if(c)" begin
            Threads.atomic_add!(k, 1)
        end
        @test k[] == (c ? 3 : 1)
    end
end

@testset "data sharing" begin
    x, y, z = 1, 2, 3
    shared = zeros(Int, 3)
    @pragma "omp parallel num_threads(3) private(x) firstprivate(y) shared(shared)" begin
        x = omp_get_thread_num()
        y += x
        shared[x+1] = y
    end
    @test (x, y) == (1, 2) && shared == [2, 3, 4]

    @pragma "omp parallel num_threads(2) default(firstprivate)" begin
        z += 1
        shared[omp_get_thread_num()+1] = z
    end
    @test z == 3 && shared[1:2] == [4, 4]

    @pragma "omp parallel num_threads(2) default(private)" begin
        z = omp_get_thread_num()
    end
    @test z == 3
end

struct Concat end
(::Concat)(a, b) = a * b
OMP.reduction_identity(::Concat, x::String) = ""

@testset "reduction" begin
    s, p, m, lo, b, o, xr, a = 0, 1, -1, 100, true, false, 0, zeros(2)
    seq, cat = "", ""
    concat = Concat()
    @pragma "omp parallel num_threads(4) reduction(+: s) reduction(*: p) reduction(max: m) reduction(min: lo) reduction(&&: b) reduction(||: o) reduction(^: xr) reduction(.+: a) reduction(*: seq) reduction(concat: cat)" begin
        t = omp_get_thread_num()
        s += t
        p *= 2
        m = max(m, t)
        lo = min(lo, t)
        b = b && t < 3
        o = o || t == 3
        xr ⊻= 1 << t
        a .+= 1
        seq *= string(t)
        cat = concat(cat, string(t))
    end
    @test (s, p, m, lo, b, o, xr, a) == (6, 16, 3, 0, false, true, 15, [4.0, 4.0])
    @test seq == "0123" && cat == "0123"  # combined in the order of the threads
end

@testset "proc_bind" begin
    k = Threads.Atomic{Int}(0)
    @pragma "omp parallel num_threads(2) proc_bind(spread)" begin
        Threads.atomic_add!(k, 1)
    end
    @test k[] == 2
end

@testset "strict num_threads" begin
    levels = omp_get_max_active_levels()
    omp_set_max_active_levels(0)  # every region is inactive: a team of 1 thread
    try
        @test_throws CapturedException @pragma "omp parallel num_threads(strict: 2)" begin end
        @test_logs (:warn, r"too few threads") @pragma "omp parallel num_threads(strict: 2) severity(warning) message(\"too few threads\")" begin end
    finally
        omp_set_max_active_levels(levels)
    end
end

@testset "exceptions" begin
    e = try
        @pragma "omp parallel num_threads(4)" begin
            omp_get_thread_num() == 2 && throw(DomainError(2))
        end
    catch e
        e
    end
    @test e isa CapturedException && e.ex == DomainError(2)
end

@testset "I/O and GC in regions" begin
    pipe = Pipe()
    Base.link_pipe!(pipe)
    @pragma "omp parallel num_threads(4)" begin
        v = [rand() for _ in 1:10_000]
        GC.gc(false)
        print(pipe, length(v) ÷ 10_000)
    end
    close(pipe.in)
    @test read(pipe, String) == "1111"

    # a thread blocked in the runtime (omp_set_lock) must not stall a GC
    lk = Ref{omp_lock_t}()
    omp_init_lock(lk)
    @pragma "omp parallel num_threads(2)" begin
        if omp_get_thread_num() == 0
            omp_set_lock(lk); Libc.systemsleep(0.01); GC.gc(); omp_unset_lock(lk)
        else
            Libc.systemsleep(0.001); omp_set_lock(lk); omp_unset_lock(lk)
        end
    end
    omp_destroy_lock(lk)
    @test true
end

@testset "masked" begin
    who = Int[]
    @pragma "omp parallel masked num_threads(3) filter(2)" begin
        push!(who, omp_get_thread_num())
    end
    @test who == [2]
    @pragma "omp parallel num_threads(3)" begin
        @pragma "omp masked" push!(who, omp_get_thread_num())
    end
    @test who == [2, 0]
end

@testset "unsupported" begin
    @test lowering_error(quote @pragma "omp parallel for" for i in 1:2 end end) isa UnsupportedDirectiveError
    e = lowering_error(:(@pragma "omp parallel copyin(x)" begin end))
    @test e isa UnsupportedDirectiveError && occursin("copyin", sprint(showerror, e))
    @test lowering_error(:(@pragma "omp parallel num_threads(2, 2)" begin end)) isa UnsupportedDirectiveError
    @test lowering_error(:(@pragma "omp parallel reduction(task, +: s)" begin end)) isa UnsupportedDirectiveError
end
