# `parallel`: fork a team of threads running the associated code.

const PROC_BIND = Dict(:primary => LibOMPABI.omp_proc_bind_primary,
                       :master => LibOMPABI.omp_proc_bind_primary,
                       :close => LibOMPABI.omp_proc_bind_close,
                       :spread => LibOMPABI.omp_proc_bind_spread)

# The front-end accepts the clauses of the specification only. Of those, `allocate`
# (allocators of private copies, which are bindings) and `safesync` (devices) have no effect.
function lower(::Val{:parallel}, d::Directive, mod::Module)
    clause(d, :copyin) === nothing || unsupported(d, "`copyin` needs threadprivate variables")
    n, active = gensym(:num_threads), gensym(:if)
    c = clause(d, :if)
    code = Any[:($active = $(c === nothing ? true : argument(c, :if_expression)))]

    c = clause(d, :num_threads)
    strict = c !== nothing && modifier(c, :prescriptiveness_modifier) === :strict
    if c === nothing
        push!(code, :($n = $active ? 0 : 1))
    else
        modifier(c, :dims_modifier) === nothing || unsupported(d, "`num_threads` with `dims`")
        list = argument(c, :nthreads_list)
        length(list) == 1 || unsupported(d, "`num_threads` with several values")
        push!(code, :($n = $active ? $(list[1]) : 1))
    end

    p = privatize(d, d.body, mod; team = :($(ref(:team_bound))($n)))
    append!(code, p.prologue)
    body = p.body
    if strict
        msg, m, s = gensym(:message), clause(d, :message), clause(d, :severity)
        push!(code, :($msg = $(m === nothing ? nothing : argument(m, :msg_string))))
        fatal = s === nothing || argument(s, :sev_level) === :fatal
        body = quote
            $active && !$(ref(:check_strict))($n, $msg, $fatal) && return nothing
            $body
        end
    end

    c = clause(d, :proc_bind)
    bind = c === nothing ? 0 : Integer(PROC_BIND[argument(c, :affinity_policy)])
    push!(code, :($(ref(:fork))(() -> ($body; nothing), $n, $bind)))
    append!(code, p.epilogue)
    return Expr(:block, code..., nothing)
end
