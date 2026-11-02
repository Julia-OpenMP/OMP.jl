# `masked`: the associated code runs on the thread `filter` (default: the primary thread).

function lower(::Val{:masked}, d::Directive, mod::Module)
    f = clause(d, :filter)
    thread = f === nothing ? 0 : argument(f, :thread_num)
    return :($(GlobalRef(LibOMPABI, :omp_get_thread_num))() == $thread ? ($(d.body); nothing) : nothing)
end
