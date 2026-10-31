# Lookup tables derived from the generated `Spec` (built at precompilation time).

"Whether directive `d` is available in Julia (see [`EXCLUDED_LANGUAGES`](@ref))."
available(d::DirectiveSpec) = !(d.language in EXCLUDED_LANGUAGES)

function group_by(f, xs)
    out = Dict{Symbol,Vector{eltype(xs)}}()
    for x in xs
        push!(get!(out, f(x), eltype(xs)[]), x)
    end
    return out
end

"Directives by name."
const DIRECTIVES = Dict{Symbol,DirectiveSpec}(d.name => d for d in Spec.DIRECTIVES)

"Directives by spelling (several directives may share one, e.g. `ordered`)."
const DIRECTIVES_BY_SPELLING = group_by(d -> d.spelling, collect(Spec.DIRECTIVES))

"Spellings of all leaf directives (including unavailable ones, for error messages)."
const LEAF_SPELLINGS = Set{Symbol}(keys(DIRECTIVES_BY_SPELLING))

"Compound directives made of available leaf directives, as tuples of leaf spellings."
const COMPOUND_DIRECTIVES = Set{Tuple{Vararg{Symbol}}}(
    c for c in Spec.COMPOUND_DIRECTIVES
    if all(leaf -> any(available, DIRECTIVES_BY_SPELLING[leaf]), c))

"Clause groups by name."
const CLAUSE_GROUPS = Dict{Symbol,ClauseGroupSpec}(g.name => g for g in Spec.CLAUSE_GROUPS)

# Clause-groups whose members are directive names (e.g. `cancel parallel`): one clause per
# member directive, spelled like the directive, with the arguments and modifiers of the group.
function directive_name_clauses()
    out = Pair{Symbol,ClauseSpec}[]
    for g in Spec.CLAUSE_GROUPS
        g.member_property === nothing && continue
        for d in Spec.DIRECTIVES
            (g.member_property in d.properties && available(d)) || continue
            c = ClauseSpec(; name = Symbol(g.name, :_, d.spelling), spelling = d.spelling,
                           arguments = g.arguments, modifiers = g.modifiers,
                           directives = g.directives)
            push!(out, g.name => c)
        end
    end
    return out
end

const DIRECTIVE_NAME_CLAUSES = directive_name_clauses()

"Clauses by name, including the clauses of directive-name clause groups."
const CLAUSES = Dict{Symbol,ClauseSpec}(
    [c.name => c for c in Spec.CLAUSES]..., [c.name => c for (_, c) in DIRECTIVE_NAME_CLAUSES]...)

"Clauses by spelling (several clauses may share one, e.g. `update`)."
const CLAUSES_BY_SPELLING = group_by(c -> c.spelling, collect(values(CLAUSES)))

"Names of the member clauses of each clause group."
const CLAUSE_GROUP_MEMBERS = Dict{Symbol,Syms}(
    g.name => (g.member_property === nothing ? g.clauses :
               Tuple(c.name for (n, c) in DIRECTIVE_NAME_CLAUSES if n === g.name))
    for g in Spec.CLAUSE_GROUPS)

"Names of the clauses each directive accepts (directly or through clause groups)."
const ALLOWED_CLAUSES = Dict{Symbol,Set{Symbol}}(
    d.name => Set{Symbol}([d.clauses...; [m for g in d.clause_groups for m in CLAUSE_GROUP_MEMBERS[g]]])
    for d in Spec.DIRECTIVES)

"Modifiers by name."
const MODIFIERS = Dict{Symbol,ModifierSpec}(m.name => m for m in Spec.MODIFIERS)

"""
    clause_sets(d::DirectiveSpec) -> Vector{Tuple{MemberSet,Bool}}

The clause-sets of `d`: its own and those formed by its clause groups, each paired with
whether it is a clause group (whose default properties differ).
"""
clause_sets(d::DirectiveSpec) =
    Tuple{MemberSet,Bool}[[(s, false) for s in d.clause_sets];
                          [(MemberSet(g, CLAUSE_GROUP_MEMBERS[g], CLAUSE_GROUPS[g].properties), true)
                           for g in d.clause_groups]]
