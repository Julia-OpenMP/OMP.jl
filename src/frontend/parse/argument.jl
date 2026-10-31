# Arguments (of directives, clauses and complex modifiers) and values (of arguments and
# modifiers), driven by their `ArgumentSpec`.

"Arguments are required unless they have the optional property."
is_optional(a::ArgumentSpec) = has_property(a, :optional)

describe(names) = join(("`$n`" for n in names), ", ", " or ")

"""
    parse_value(ctx, spec::ArgumentSpec, ex, what::String)

Parse the Julia expression `ex` as a value of syntax `spec`; `what` describes it in errors
(e.g. "argument `kind` of clause `schedule`"). See ir.jl for the representation of values.
"""
function parse_value(ctx::Context, spec::ArgumentSpec, ex, what::String)
    k = spec.kind
    if ex isa RawText && k !== :directive_specification
        with_span(ctx, ex.span) do
            fail(ctx, "invalid $what: `$(ex.text)` is not a valid Julia expression ($(ex.msg))")
        end
    end
    if k === :keyword
        s = name_token(ex)
        s === nothing || (s = get(KEYWORD_ALIASES, (spec.name, s), s))
        s in spec.values ||
            fail(ctx, "invalid $what: got `$(code(ex))`, expected $(describe(spec.values))")
        return s
    elseif k === :complex
        parts = call_parts(ex)
        (parts !== nothing && matches_complex(spec, parts[1])) ||
            fail(ctx, "invalid $what: got `$(code(ex))`, expected `$(complex_keywords(spec))(...)`")
        return ComplexValue(parts[1], match_arguments(ctx, spec.arguments, parts[2], "$what `$(parts[1])`"))
    elseif k === :list
        return Any[parse_value(ctx, item_spec(spec), ex, what)]
    elseif k === :variable || k === :identifier
        ex isa Symbol || fail(ctx, "$what must be $(k === :variable ? "a variable" : "an identifier"), got `$(code(ex))`")
        return ex
    elseif k === :directive_name
        s = name_token(ex)
        (s !== nothing && s in LEAF_SPELLINGS) ||
            fail(ctx, "$what must be a directive name, got `$(code(ex))`")
        return s
    elseif k === :list_item
        return parse_list_item(ctx, spec, ex, what)
    elseif k === :expression
        check_expression(ctx, spec, ex, what)
        return ex
    elseif k === :directive_specification
        return parse_directive_specification(ctx, ex, what)
    else # :type_name, :stylized: interpreted by later stages
        return ex
    end
end

# value properties of a list apply to its items (e.g. `num_threads` takes a positive list)
const VALUE_PROPERTIES = (:constant, :positive, :non_negative, :region_invariant)

function item_spec(list::ArgumentSpec)
    items = list.items
    props = (items.properties..., filter(p -> p in VALUE_PROPERTIES && !(p in items.properties), list.properties)...)
    props == items.properties && return items
    return ArgumentSpec(items.name, items.spelling, items.kind, items.type, items.keyword,
                        items.values, items.items, items.arguments, props)
end

matches_complex(spec::ArgumentSpec, kw::Symbol) =
    kw === spec.keyword || kw in spec.values || (spec.keyword === nothing && isempty(spec.values))

complex_keywords(spec::ArgumentSpec) =
    spec.keyword !== nothing ? spec.keyword : isempty(spec.values) ? "keyword" : join(spec.values, "|")

function parse_list_item(ctx::Context, spec::ArgumentSpec, ex, what::String)
    if spec.type == "variable list item"
        ex isa Symbol || fail(ctx, "$what must be a variable, got `$(code(ex))`")
    elseif is_literal(ex)
        fail(ctx, "$what must be a $(spec.type), got the literal `$(code(ex))`")
    end
    return ex
end

"Check what can be checked of an expression at macro expansion time: its literals."
function check_expression(ctx::Context, spec::ArgumentSpec, ex, what::String)
    is_literal(ex) || return
    v = literal_value(ex)
    ok = spec.type == "integer" ? (v isa Integer && !(v isa Bool)) :
         spec.type == "OpenMP logical" ? v isa Integer :
         spec.type == "string" ? v isa AbstractString : true
    ok || fail(ctx, "$what must be of type $(spec.type), got `$(code(ex))`")
    if v isa Real
        has_property(spec, :positive) && v <= 0 && fail(ctx, "$what must be positive, got `$(code(ex))`")
        has_property(spec, :non_negative) && v < 0 && fail(ctx, "$what must be non-negative, got `$(code(ex))`")
    end
end

"""
    match_arguments(ctx, specs, exs, what) -> Vector{Argument}

Match the comma-separated expressions `exs` to the arguments `specs`, in order: a list
argument takes as many expressions as available, optional arguments may be omitted, and a
trailing stylized argument (e.g. an iteration specifier `i - 1, j`) takes the remaining
expressions as a tuple.
"""
function match_arguments(ctx::Context, specs, exs::Vector{Any}, what::String)
    n = length(exs)
    out = Argument[]
    if isempty(specs)
        n == 0 || fail(ctx, "$what takes no arguments, got `$(join(map(code, exs), ", "))`")
        return out
    end
    li = findfirst(s -> s.kind === :list, specs)
    if li !== nothing
        before, after = specs[1:li-1], specs[li+1:end]
        nlist = n - length(before) - length(after)
        if nlist <= 0
            (nlist == 0 && is_optional(specs[li])) ||
                fail(ctx, "missing argument `$(specs[li].spelling)` in $what")
        end
        for (i, s) in enumerate(before)
            push!(out, argument_of(ctx, s, exs[i], what))
        end
        if nlist > 0
            items = exs[length(before)+1:length(before)+nlist]
            ispec = item_spec(specs[li])
            push!(out, Argument(specs[li], Any[parse_value(ctx, ispec, e, "item of argument `$(specs[li].spelling)` of $what") for e in items]))
        end
        for (i, s) in enumerate(after)
            push!(out, argument_of(ctx, s, exs[n-length(after)+i], what))
        end
        return out
    end
    keep = collect(specs)
    while length(keep) > n
        i = findlast(is_optional, keep)
        i === nothing && fail(ctx, "missing argument `$(keep[n+1].spelling)` in $what")
        deleteat!(keep, i)
    end
    if n > length(keep)
        last = isempty(keep) ? nothing : keep[end]
        if last !== nothing && last.kind === :stylized
            k = length(keep)
            exs = Any[exs[1:k-1]; Expr(:tuple, exs[k:end]...)]
        else
            fail(ctx, "too many arguments in $what: `$(join(map(code, exs), ", "))`")
        end
    end
    for (s, e) in zip(keep, exs)
        push!(out, argument_of(ctx, s, e, what))
    end
    return out
end

argument_of(ctx::Context, s::ArgumentSpec, ex, what::String) =
    Argument(s, parse_value(ctx, s, ex, "argument `$(s.spelling)` of $what"))
