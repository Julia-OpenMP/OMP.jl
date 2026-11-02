# Compound directives: splitting into the outermost leaf and the rest, distributing the
# clauses as the specification does (section "Compound Directive Clauses").

const PRIVATIZING_CLAUSES = (:private, :firstprivate, :lastprivate, :linear, :reduction)
# reduction does not apply to `parallel` combined with these, nor to `teams` with `loop`
const REDUCTION_OVER_PARALLEL = (:for, :do, :sections, :loop, :taskloop)

function shared_clause(items)
    spec = CLAUSES[:shared]
    return Clause(spec, Modifier[], [Argument(spec.arguments[1], collect(Any, items))], nothing)
end

list_items(c::Clause) = something(argument(c, :list), Any[])

function directive_name_modifier(c::Clause)
    i = findfirst(m -> m.spec.value.kind === :directive_name, c.modifiers)
    return i === nothing ? nothing : c.modifiers[i].value
end

"""
    distribute_clauses(d::Directive) -> Vector{Vector{Clause}}

The clauses of each leaf of the compound directive `d`.
"""
function distribute_clauses(d::Directive)
    leafs = d.leafs
    out = [Clause[] for _ in leafs]
    shared = [Any[] for _ in leafs]  # list items implicitly shared on parallel / teams
    has(names) = any(l -> l.name in names, leafs)
    allocates = Clause[]
    for c in d.clauses
        accepting = [i for (i, l) in enumerate(leafs) if accepts(l, c)]
        named = directive_name_modifier(c)
        name = c.spec.name
        targets = if named !== nothing
            [findfirst(l -> l.spelling === named, leafs)]
        elseif name === :private
            [last(accepting)]
        elseif name === :firstprivate
            inner = filter(i -> !(leafs[i].name in (:parallel, :teams)), accepting)
            isempty(inner) ? accepting : inner
        elseif name === :reduction
            filter(accepting) do i
                !(leafs[i].name === :parallel && has(REDUCTION_OVER_PARALLEL)) &&
                    !(leafs[i].name === :teams && has((:loop,)))
            end
        elseif name === :allocate
            push!(allocates, c)
            continue
        else
            accepting
        end
        for i in targets
            push!(out[i], c)
        end
        if name in (:firstprivate, :lastprivate, :reduction)
            for (i, l) in enumerate(leafs)
                l.name in (:parallel, :teams) && !(i in targets) && append!(shared[i], list_items(c))
            end
        end
    end
    for (i, items) in enumerate(shared)
        isempty(items) || push!(out[i], shared_clause(unique(items)))
    end
    # allocate: to the leafs that privatize one of its list items
    for c in allocates
        items = list_items(c)
        accepting = [i for (i, l) in enumerate(leafs) if accepts(l, c)]
        targets = filter(accepting) do i
            any(x -> x.spec.name in PRIVATIZING_CLAUSES && any(in(items), list_items(x)), out[i])
        end
        for i in (isempty(targets) ? [last(accepting)] : targets)
            push!(out[i], c)
        end
    end
    return out
end

"""
    split_compound(d::Directive) -> (outer, inner)

The outermost leaf directive of the compound directive `d`, and the directive made of its
other leafs, which is associated with the code of `d`. The body of `outer` is `nothing`.
"""
function split_compound(d::Directive)
    clauses = distribute_clauses(d)
    owner = something(findfirst(l -> !isempty(l.arguments), d.leafs), 1)
    args(i) = i == owner ? d.arguments : Argument[]
    outer = Directive(d.leafs[1].spelling, d.leafs[1:1], args(1), clauses[1], nothing, d.source)
    rest = d.leafs[2:end]
    inner = Directive(Symbol(join((l.spelling for l in rest), "_")), rest,
                      owner == 1 ? Argument[] : d.arguments, unique(vcat(clauses[2:end]...)),
                      d.body, d.source)
    return outer, inner
end
