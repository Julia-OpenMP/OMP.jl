# The intermediate representation produced by the parser, top-down:
#
#   Directive  name, leaf directives, arguments, clauses, associated code
#   └ Clause   arguments and modifiers
#     └ Modifier
#   Argument   value of an argument of a directive, clause or complex modifier
#
# Values (of arguments and modifiers) depend on the kind of their spec:
#
#   :keyword, :identifier, :variable, :directive_name   Symbol
#   :list                                               Vector{Any} of item values
#   :complex                                            ComplexValue
#   :directive_specification                            Directive
#   :expression, :list_item, :type_name, :stylized      the Julia expression, unevaluated

"""
    Argument(spec::ArgumentSpec, value)

A parsed argument of a directive, clause or complex modifier.
"""
struct Argument
    spec::ArgumentSpec
    value::Any
end

"""
    ComplexValue(keyword, arguments)

Value of a complex modifier, e.g. `iterator(i = 1:n)` or `step(2)`.
"""
struct ComplexValue
    keyword::Symbol
    arguments::Vector{Argument}
end

"""
    Modifier(spec::ModifierSpec, value)

A parsed modifier of a clause.
"""
struct Modifier
    spec::ModifierSpec
    value::Any
end

"""
    Clause(spec::ClauseSpec, modifiers, arguments, source)

A parsed clause; `source` is the Julia expression it was parsed from.
"""
struct Clause
    spec::ClauseSpec
    modifiers::Vector{Modifier}
    arguments::Vector{Argument}
    source::Any
end

"""
    Directive(name, leafs, arguments, clauses, body, source)

A parsed directive. `name` is its spelling (`:parallel`, `:target_teams`); `leafs` are its
leaf directives, outermost first (several for a compound directive); `body` is the
associated code, or `nothing`.
"""
struct Directive
    name::Symbol
    leafs::Vector{DirectiveSpec}
    arguments::Vector{Argument}
    clauses::Vector{Clause}
    body::Any
    source::Union{Nothing,LineNumberNode}
end

# -- queries --------------------------------------------------------------------------------

"Whether `d` is a compound directive."
is_compound(d::Directive) = length(d.leafs) > 1

matches(spec, name::Symbol) = spec.name === name || spec.spelling == name ||
                              (spec.spelling isa String && Symbol(spec.spelling) === name)

"""
    clauses(d::Directive, name::Symbol) -> Vector{Clause}

The clauses of `d` with the given name or spelling.
"""
clauses(d::Directive, name::Symbol) = filter(c -> matches(c.spec, name), d.clauses)

"""
    clause(d::Directive, name::Symbol) -> Union{Clause,Nothing}

The first clause of `d` with the given name or spelling.
"""
clause(d::Directive, name::Symbol) = (i = findfirst(c -> matches(c.spec, name), d.clauses);
                                      i === nothing ? nothing : d.clauses[i])

"""
    modifier(c::Clause, name::Symbol)

The value of the modifier of `c` with the given name, or `nothing`.
"""
modifier(c::Clause, name::Symbol) = (i = findfirst(m -> matches(m.spec, name), c.modifiers);
                                     i === nothing ? nothing : c.modifiers[i].value)

"""
    argument(x::Union{Directive,Clause,ComplexValue}, name::Symbol)

The value of the argument of `x` with the given name, or `nothing`.
"""
argument(x::Union{Directive,Clause,ComplexValue}, name::Symbol) =
    (i = findfirst(a -> matches(a.spec, name), x.arguments); i === nothing ? nothing : x.arguments[i].value)

# -- printing, in OpenMP syntax ----------------------------------------------------------------

print_value(io::IO, v::Symbol) = print(io, v)
print_value(io::IO, v::AbstractVector) = join(io, (sprint(print_value, x) for x in v), ", ")
print_value(io::IO, v::ComplexValue) = (print(io, v.keyword); print_arguments(io, v.arguments))
print_value(io::IO, v::Directive) = print_directive(io, v)
print_value(io::IO, v) = print(io, code(v))

print_list(io::IO, xs) = join(io, (sprint(print_value, x.value) for x in xs), ", ")

function print_arguments(io::IO, args::Vector{Argument})
    isempty(args) && return
    print(io, "(")
    print_list(io, args)
    print(io, ")")
end

function Base.print(io::IO, c::Clause)
    print(io, c.spec.spelling)
    isempty(c.modifiers) && return print_arguments(io, c.arguments)
    print(io, "(")
    mods = sprint(print_list, c.modifiers)
    args = sprint(print_list, c.arguments)
    has_property(c.spec, :post_modified) ? print(io, args, " : ", mods) : print(io, mods, " : ", args)
    print(io, ")")
end

function print_directive(io::IO, d::Directive)
    join(io, (l.spelling for l in d.leafs), " ")
    print_arguments(io, d.arguments)
    for c in d.clauses
        print(io, " ", c)
    end
end

Base.show(io::IO, c::Clause) = print(io, "Clause(", c, ")")

function Base.show(io::IO, d::Directive)
    print(io, "Directive(omp ")
    print_directive(io, d)
    d.body === nothing || print(io, " <body>")
    print(io, ")")
end

# -- parsing context ---------------------------------------------------------------------------

mutable struct Context
    source::Union{Nothing,LineNumberNode}
    "the directive being parsed (its leaf directives)"
    leafs::Vector{DirectiveSpec}
    "the directive string, for directives written as strings"
    text::Union{Nothing,String}
    "the part of `text` being parsed, pointed at in errors"
    span::Union{Nothing,UnitRange{Int}}
end

Context(source, leafs) = Context(source, leafs, nothing, nothing)

function fail(ctx::Context, msg::AbstractString)
    if ctx.text !== nothing && ctx.span !== nothing && !isempty(ctx.span)
        msg = string(msg, "\n", pointer_to(ctx.text, ctx.span))
    end
    throw(OpenMPSyntaxError(msg, ctx.source))
end

"""
    pointer_to(text, span)

The line of `text` containing `span`, with `^` under `span`.
"""
function pointer_to(text::String, span::UnitRange{Int})
    a = first(span)
    i = a > 1 ? findprev(==('\n'), text, prevind(text, a)) : nothing
    start = i === nothing ? 1 : i + 1
    j = findnext(==('\n'), text, a)
    stop = j === nothing ? lastindex(text) : prevind(text, j)
    col = textwidth(SubString(text, start, prevind(text, a)))
    width = max(1, textwidth(SubString(text, a, min(last(span), stop))))
    q = start == 1 ? "\"" : " "
    e = stop == lastindex(text) ? "\"" : ""
    return string("    ", q, SubString(text, start, stop), e, "\n    ", " "^(col + 1), "^"^width)
end

"Run `f()` with `ctx.span` set to `span` (when known)."
function with_span(f, ctx::Context, span)
    span === nothing && return f()
    old = ctx.span
    ctx.span = span
    r = f()
    ctx.span = old
    return r
end
