# Syntactic restrictions of the specification (section "Clause Format"), checked on a parsed
# directive. Default properties, when not specified (table of syntactic properties):
#
#                 required/optional  unique/repeatable  exclusive/compatible  ultimate/free
#   clause        optional           repeatable         compatible            free
#   argument      required           unique             compatible            free
#   modifier      optional           unique             compatible            free
#   clause group  optional           unique             compatible            free
#   modifier grp  optional           unique             compatible            free
#
# Argument restrictions are enforced while matching arguments (parse/argument.jl).

"""
    validate(ctx, d::Directive)

Check the syntactic restrictions on the clauses and modifiers of `d`; throw an
[`OpenMPSyntaxError`](@ref) otherwise.
"""
function validate(ctx::Context, d::Directive)
    check_allowed_clauses(ctx, d)
    check_clause_properties(ctx, d)
    check_clause_sets(ctx, d)
    for c in d.clauses
        check_modifiers(ctx, d, c)
    end
    check_body(ctx, d)
    return nothing
end

spelling_of(name::Symbol) = haskey(CLAUSES, name) ? CLAUSES[name].spelling : name

accepts(leaf::DirectiveSpec, c::Clause) = c.spec.name in ALLOWED_CLAUSES[leaf.name]

function check_allowed_clauses(ctx::Context, d::Directive)
    for c in d.clauses
        any(l -> accepts(l, c), d.leafs) ||
            fail(ctx, "clause `$(c.spec.spelling)` is not allowed on directive `$(directive_spelling(ctx))`")
        for m in c.modifiers
            m.spec.value.kind === :directive_name || continue
            i = findfirst(l -> l.spelling === m.value, d.leafs)
            (i !== nothing && accepts(d.leafs[i], c)) ||
                fail(ctx, "directive-name modifier `$(m.value)` of clause `$(c.spec.spelling)` must name a constituent of `$(directive_spelling(ctx))` that accepts the clause")
        end
    end
end

function check_clause_properties(ctx::Context, d::Directive)
    count = Dict{Symbol,Int}()
    for c in d.clauses
        count[c.spec.name] = get(count, c.spec.name, 0) + 1
    end
    for (name, n) in count
        n > 1 && is_unique(d, name) &&
            fail(ctx, "clause `$(spelling_of(name))` may appear at most once on directive `$(directive_spelling(ctx))`")
    end
    for c in d.clauses
        has_property(c.spec, :exclusive) && length(count) > 1 &&
            fail(ctx, "clause `$(c.spec.spelling)` must be the only clause on directive `$(directive_spelling(ctx))`")
    end
    for (i, c) in enumerate(d.clauses)
        has_property(c.spec, :ultimate) && i != length(d.clauses) &&
            fail(ctx, "clause `$(c.spec.spelling)` must be the last clause of directive `$(directive_spelling(ctx))`")
    end
    for l in d.leafs, name in l.clauses
        has_property(CLAUSES[name], :required) && !haskey(count, name) &&
            fail(ctx, "directive `$(directive_spelling(ctx))` requires clause `$(spelling_of(name))`")
    end
end

"A clause is unique if it has the unique property, or belongs to a unique clause-set."
function is_unique(d::Directive, name::Symbol)
    has_property(CLAUSES[name], :unique) && return true
    for l in d.leafs, (s, group) in clause_sets(l)
        name in s.members && (group || has_property(s, :unique)) && return true
    end
    return false
end

function check_clause_sets(ctx::Context, d::Directive)
    for l in d.leafs, (s, _) in clause_sets(l)
        present = unique!([c.spec.name for c in d.clauses if c.spec.name in s.members])
        names = describe(unique(spelling_of.(s.members)))
        if has_property(:clause_set, s, :exclusive) && length(present) > 1
            fail(ctx, "clauses $(join(("`$(spelling_of(p))`" for p in present), " and ")) are mutually exclusive on directive `$(directive_spelling(ctx))`")
        end
        if has_property(:clause_set, s, :required) && isempty(present)
            fail(ctx, "directive `$(directive_spelling(ctx))` requires one of the clauses $names")
        end
    end
end

function check_modifiers(ctx::Context, d::Directive, c::Clause)
    what = "clause `$(c.spec.spelling)`"
    names = [m.spec.name for m in c.modifiers]
    for name in unique(names)
        spec = c.modifiers[findfirst(==(name), names)].spec
        count(==(name), names) > 1 && !has_property(spec, :repeatable) &&
            fail(ctx, "modifier `$(spec.spelling)` may appear at most once in $what")
        has_property(spec, :exclusive) && length(unique(names)) > 1 &&
            fail(ctx, "modifier `$(spec.spelling)` must be the only modifier of $what")
    end
    for m in c.spec.modifiers
        has_property(m, :required) && !(m.name in names) &&
            fail(ctx, "$what requires the modifier `$(m.spelling)`")
    end
    for (i, m) in enumerate(c.modifiers)
        has_property(m.spec, :ultimate) && i != length(c.modifiers) &&
            fail(ctx, "modifier `$(m.spec.spelling)` must be the last modifier of $what")
    end
    for s in c.spec.modifier_sets
        present = unique!(filter(in(s.members), names))
        has_property(:modifier_set, s, :exclusive) && length(present) > 1 &&
            fail(ctx, "modifiers $(join(("`$p`" for p in present), " and ")) are mutually exclusive in $what")
        has_property(:modifier_set, s, :required) && isempty(present) &&
            fail(ctx, "$what requires one of the modifiers $(describe(s.members))")
    end
end

# the loop of a loop-associated directive: `for ...` or `begin for ... end end`
function loop_of(body)
    Meta.isexpr(body, :for) && return body
    if Meta.isexpr(body, :block)
        stmts = filter(x -> !(x isa LineNumberNode), body.args)
        length(stmts) == 1 && return loop_of(stmts[1])
    end
    return nothing
end

is_function_definition(ex) =
    Meta.isexpr(ex, :function) || (Meta.isexpr(ex, :(=), 2) && Meta.isexpr(ex.args[1], (:call, :where)))

function check_body(ctx::Context, d::Directive)
    d.body === nothing && return
    a = d.leafs[end].association
    if a === :loop_nest && loop_of(d.body) === nothing
        fail(ctx, "directive `$(directive_spelling(ctx))` must be followed by a `for` loop, got `$(brief(d.body))`")
    elseif a === :declaration && !is_function_definition(d.body)
        fail(ctx, "directive `$(directive_spelling(ctx))` must be followed by a function definition, got `$(brief(d.body))`")
    end
end
