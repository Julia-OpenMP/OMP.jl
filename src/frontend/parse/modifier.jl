# Modifiers of a clause: which modifier an expression is, then its value.

"""
    parse_modifier(ctx, clause::ClauseSpec, ex) -> Modifier
"""
function parse_modifier(ctx::Context, clause::ClauseSpec, ex)
    m = classify_modifier(ctx, clause, ex)
    m === nothing &&
        fail(ctx, "invalid modifier `$(code(ex))` of clause `$(clause.spelling)`$(modifier_help(clause))")
    return Modifier(m, parse_value(ctx, m.value, ex, "modifier `$(m.spelling)` of clause `$(clause.spelling)`"))
end

keyword_matches(v::ArgumentSpec, s::Symbol) = s in v.values || haskey(KEYWORD_ALIASES, (v.name, s))

"""
    classify_modifier(ctx, clause::ClauseSpec, ex) -> Union{ModifierSpec,Nothing}

The modifier of `clause` that `ex` is, by decreasing priority:
1. a complex modifier named by its keyword: `iterator(...)`, `step(2)`;
2. a keyword modifier: `in`, `monotonic`;
3. a complex modifier without arguments (all optional);
4. the directive-name modifier: `if(parallel : c)`;
5. the only modifier that accepts any expression or identifier (e.g. the
   reduction-identifier of `reduction`, the step of `linear`).
"""
function classify_modifier(ctx::Context, clause::ClauseSpec, ex)
    mods = clause.modifiers
    name = name_token(ex)
    is_call = name === nothing && Meta.isexpr(ex, :call) && name_token(ex.args[1]) !== nothing
    if is_call
        kw = name_token(ex.args[1])
        for m in mods
            v = m.value
            v.kind === :complex && (kw === v.keyword || kw in v.values) && return m
        end
    end
    if name !== nothing
        for m in mods
            m.value.kind === :keyword && keyword_matches(m.value, name) && return m
        end
        for m in mods
            v = m.value
            v.kind === :complex && (name === v.keyword || name in v.values) &&
                all(is_optional, v.arguments) && return m
        end
        if name in LEAF_SPELLINGS
            for m in mods
                m.value.kind === :directive_name && return m
            end
        end
    end
    open = filter(mods) do m
        k = m.value.kind
        k in (:expression, :identifier, :variable, :list_item, :type_name, :stylized) ||
            (k === :complex && is_call && m.value.keyword === nothing && isempty(m.value.values))
    end
    isempty(open) && return nothing
    length(open) == 1 ||
        fail(ctx, "ambiguous modifier `$(code(ex))` of clause `$(clause.spelling)`: could be $(describe(m.spelling for m in open))")
    return only(open)
end

function modifier_help(clause::ClauseSpec)
    isempty(clause.modifiers) && return ": the clause takes no modifiers"
    parts = map(clause.modifiers) do m
        v = m.value
        v.kind === :keyword ? join(v.values, "|") :
        v.kind === :complex ? "$(complex_keywords(v))(...)" :
        v.kind === :directive_name ? "directive-name" : m.spelling
    end
    return "; expected $(join(parts, ", "))"
end
