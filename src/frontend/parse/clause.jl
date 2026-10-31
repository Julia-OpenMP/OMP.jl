# Clauses: `name`, `name(arguments)`, `name(modifiers : arguments)`, or for post-modified
# clauses `name(arguments : modifiers)`. A clause is a `TextCall` in a directive string,
# or a Julia expression in the bare form (`@pragma omp ...`).

"""
    parse_clause(ctx, token) -> Clause
"""
function parse_clause(ctx::Context, t::TextCall)
    with_span(ctx, t.span) do
        spec = resolve_clause(ctx, get(CLAUSE_ALIASES, t.name, t.name))
        before, after = t.args === nothing ? (Any[], nothing) : split_text(ctx, ctx.text, t.args, :clause)
        clause_from_parts(ctx, spec, before, after, ctx.text[t.span])
    end
end

function parse_clause(ctx::Context, ex)
    parts = call_parts(ex)
    if parts === nothing
        fail(ctx, "expected a clause, got `$(code(ex))`")
    end
    name, args = parts
    spec = resolve_clause(ctx, get(CLAUSE_ALIASES, name, name))
    before, after = split_at_colon(desugar_clause(spec, args))
    return clause_from_parts(ctx, spec, before, after, ex)
end

"""
    clause_from_parts(ctx, spec, before, after, source) -> Clause

The clause from the expressions `before` and `after` its `:` (`after` is `nothing` without
`:`): modifiers come before the `:`, except for post-modified clauses.
"""
function clause_from_parts(ctx::Context, spec::ClauseSpec, before::Vector{Any},
                           after::Union{Nothing,Vector{Any}}, source)
    if after === nothing
        modexs, argexs = Any[], before
    elseif has_property(spec, :post_modified)
        modexs, argexs = after, before
    else
        modexs, argexs = before, after
    end
    modifiers = Modifier[parse_modifier(ctx, spec, m) for m in modexs]
    arguments = match_arguments(ctx, spec.arguments, argexs, "clause `$(spec.spelling)`")
    return Clause(spec, modifiers, arguments, source)
end

"""
    resolve_clause(ctx, spelling) -> ClauseSpec

The clause spelled `spelling`; when several clauses share it, the one accepted by the
directive being parsed.
"""
function resolve_clause(ctx::Context, spelling::Symbol)
    cands = get(CLAUSES_BY_SPELLING, spelling, nothing)
    if cands === nothing
        names = isempty(ctx.leafs) ? Symbol[] :
                sort!([CLAUSES[c].spelling for l in ctx.leafs for c in ALLOWED_CLAUSES[l.name]])
        if spelling in LEAF_SPELLINGS
            ds = DIRECTIVES_BY_SPELLING[spelling]
            why = any(available, ds) ? "" :
                  ", specific to the $(ds[1].language) base language and not available in Julia"
            fail(ctx, "`$spelling` is a directive$why, not a clause of `$(directive_spelling(ctx))`")
        end
        fail(ctx, "unknown clause `$spelling`" *
                  (isempty(names) ? "" : "; `$(directive_spelling(ctx))` accepts $(describe(unique(names)))"))
    end
    length(cands) == 1 && return cands[1]
    i = findfirst(c -> any(l -> c.name in ALLOWED_CLAUSES[l.name], ctx.leafs), cands)
    return cands[something(i, 1)]
end

directive_spelling(ctx::Context) = join((l.spelling for l in ctx.leafs), " ")

"""
    split_at_colon(args) -> (before, after)

Split the arguments of a bare-form clause at the first top-level `:` (see
[`split_colon`](@ref)); `after` is `nothing` without `:`.
"""
function split_at_colon(args::Vector{Any})
    for (i, a) in enumerate(args)
        s = split_colon(a)
        s === nothing && continue
        return (Any[args[1:i-1]; s[1]], Any[s[2]; args[i+1:end]])
    end
    return (args, nothing)
end

"Whether `x` looks like a clause rather than associated code."
is_clause_shaped(::TextCall) = true
is_clause_shaped(ex) = name_token(ex) !== nothing || clause_spelling(ex) !== nothing

# spelling of the known clause `ex` calls, or nothing
clause_spelling(t::TextCall) = t.name
function clause_spelling(ex)
    Meta.isexpr(ex, :call) || return nothing
    name = name_token(ex.args[1])
    name === nothing && return nothing
    name = get(CLAUSE_ALIASES, name, name)
    return haskey(CLAUSES_BY_SPELLING, name) ? name : nothing
end

"""
    is_accepted_clause(ctx, x)

Whether `x` is a clause accepted by the directive being parsed (rather than its
associated code, which must then be missing).
"""
function is_accepted_clause(ctx::Context, x)
    name = something(name_token(x), clause_spelling(x), Some(nothing))
    name === nothing && return false
    name = get(CLAUSE_ALIASES, name, name)
    return any(c -> any(l -> c.name in ALLOWED_CLAUSES[l.name], ctx.leafs),
               get(CLAUSES_BY_SPELLING, name, ClauseSpec[]))
end
