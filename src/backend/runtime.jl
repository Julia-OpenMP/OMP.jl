# Run-time support of the generated code.

mutable struct Region{F}
    const f::F
    @atomic exception::Any  # the first exception of a thread, rethrown after the region
end

function run_region(r::Region)
    try
        r.f()
    catch e
        @atomicreplace r.exception nothing => CapturedException(e, catch_backtrace())
    end
    return nothing
end

"""
    fork(f, num_threads, proc_bind)

Run `f()` on each thread of a new team (`num_threads == 0`: the runtime's default), with the
`omp_proc_bind_t` policy `proc_bind` (0: none). Exceptions are rethrown, once all threads
are done.
"""
function fork(f::F, num_threads::Integer, proc_bind::Integer) where {F}
    r = Region{F}(f, nothing)
    fn = @cfunction(run_region, Cvoid, (Ref{Region{F}},))
    n, bind = Cuint(num_threads), Cuint(proc_bind)
    # other threads may need the event loop (I/O) while this one waits in the runtime
    ccall(:jl_enter_threaded_region, Cvoid, ())
    try
        GC.@preserve r LibOMPABI.omp_abi_parallel(fn, pointer_from_objref(r), n, bind)
    finally
        ccall(:jl_exit_threaded_region, Cvoid, ())
    end
    e = @atomic r.exception
    e === nothing || throw(e)
    return nothing
end

"Upper bound of the number of threads of a team created with `num_threads` (0: default)."
team_bound(num_threads::Integer) = num_threads > 0 ? Int(num_threads) : Int(LibOMPABI.omp_get_max_threads())

thread_index() = Int(LibOMPABI.omp_get_thread_num()) + 1

"""
    check_strict(num_threads, message, fatal) -> Bool

`num_threads(strict: n)`: whether the team has `n` threads; otherwise the primary thread
reports `message` as an error (`fatal`) or a warning, and the threads skip the region if
`fatal`.
"""
function check_strict(num_threads::Integer, message, fatal::Bool)
    n = LibOMPABI.omp_get_num_threads()
    n == num_threads && return true
    if LibOMPABI.omp_get_thread_num() == 0
        msg = "num_threads(strict: $num_threads): the team has $n threads" *
              (message === nothing ? "" : ": $message")
        fatal ? error(msg) : @warn msg
    end
    return !fatal
end
