# Directives: `name[(arguments)] clause... [associated code]`, the entry point of parsing.
#
# Two forms reach `parse_tokens`:
# * directive strings (parse/text.jl): tokens are `TextCall`s, the associated code is given
#   separately;
# * the bare form `@pragma omp parallel num_threads(4) begin ... end`: tokens are Julia
#   expressions, the associated code is the last one. Julia keywords (`for`, `if`, `do`,
#   `begin`, `local`, ...) cannot be written in that form: see `check_bare`.

"""
    parse_pragma(args; source = nothing, nested = false) -> Directive

Parse the arguments of a bare-form `@omp` (that is, what follows `@pragma omp`) and
validate the result. `source` locates errors. A `nested` directive (in a metadirective) has
no associated code.
"""
function parse_pragma(args::AbstractVector; source::Union{Nothing,LineNumberNode} = nothing,
                      nested::Bool = false)
    ctx = Context(source, DirectiveSpec[])
    args = collect(Any, args)
    check_bare(ctx, args)
    return parse_tokens(ctx, args, nothing, nested, true)
end

"""
    parse_tokens(ctx, tokens, body, nested, bare) -> Directive

Parse a directive from its tokens. For the bare form, the associated code is the last
token; otherwise it is `body` (`nothing`, or `Some(ex)`).
"""
function parse_tokens(ctx::Context, tokens::Vector{Any}, body::Union{Nothing,Some},
                      nested::Bool, bare::Bool)
    isempty(tokens) && fail(ctx, "missing directive name")
    k, name, spellings, dargs = resolve_directive_name(ctx, tokens)
    rest = tokens[k+1:end]
    infer = bare && !nested
    has_body = infer ? (!isempty(rest) && !is_clause_shaped(rest[end])) : body !== nothing
    ctx.leafs = select_leafs(ctx, spellings, has_body)
    required = any(l -> l.association in BODY_REQUIRED, ctx.leafs)
    optional = any(l -> l.association in BODY_OPTIONAL, ctx.leafs)
    code_ = nothing
    if nested
    elseif infer
        if required
            (isempty(rest) || is_accepted_clause(ctx, rest[end])) &&
                fail(ctx, "directive `$(directive_spelling(ctx))` must be followed by its associated code$(body_hint(ctx))")
            code_ = pop!(rest)
            check_ambiguous_loop(ctx, code_)
        elseif optional && has_body
            code_ = pop!(rest)
        end
    else
        code_ = body === nothing ? nothing : something(body)
        required && code_ === nothing &&
            fail(ctx, "directive `$(directive_spelling(ctx))` must be followed by its associated code$(body_hint(ctx)), after the directive string")
        !required && !optional && code_ !== nothing &&
            fail(ctx, "directive `$(directive_spelling(ctx))` takes no associated code, got `$(brief(code_))`")
    end
    arguments = parse_directive_arguments(ctx, dargs)
    clauses = Clause[parse_clause(ctx, t) for t in rest]
    d = Directive(name, ctx.leafs, arguments, clauses, code_, ctx.source)
    validate(ctx, d)
    return d
end

function body_hint(ctx::Context)
    a = ctx.leafs[end].association
    a === :loop_nest ? " (a `for` loop)" :
    a === :declaration ? " (a function definition)" : " (e.g. `begin ... end`)"
end

# the directive-name word of a token, or nothing
name_word(t::TextCall) = t.args === nothing ? t.name : nothing
name_word(ex) = name_token(ex)

# `(name, arguments)` of a token that is a name with arguments (`critical(lock)`), or nothing
name_call(t::TextCall) = t.args === nothing ? nothing : (t.name, t)
function name_call(ex)
    Meta.isexpr(ex, :call) || return nothing
    name = name_token(ex.args[1])
    return name === nothing ? nothing : (name, call_parts(ex)[2])
end

token_span(t::TextCall) = t.span
token_span(_) = nothing

"""
    resolve_directive_name(ctx, tokens) -> (k, name, leaf spellings, arguments)

The directive named by the longest prefix `tokens[1:k]` of name words (`target`, `data`,
`target_data`); the last word may carry arguments (`critical(name)`), returned as
`arguments` (`nothing` if none).
"""
function resolve_directive_name(ctx::Context, tokens::Vector{Any})
    words = Symbol[]
    callargs = nothing
    for t in tokens
        w = name_word(t)
        if w === nothing
            c = name_call(t)
            if c !== nothing
                push!(words, get(DIRECTIVE_ALIASES, c[1], c[1]))
                callargs = c[2]
            end
            break
        end
        push!(words, get(DIRECTIVE_ALIASES, w, w))
    end
    if isempty(words)
        with_span(ctx, token_span(tokens[1])) do
            fail(ctx, "expected a directive name, got `$(code(tokens[1]))`")
        end
    end
    for k in length(words):-1:1
        r = lookup_directive(ctx, words[1:k])
        r === nothing && continue
        return (k, r[1], r[2], k == length(words) ? callargs : nothing)
    end
    with_span(ctx, token_span(tokens[1])) do
        fail(ctx, "unknown directive `$(words[1])`$(underscore_hint(words[1]))")
    end
end

# `parallel_for` is not a directive name: compound directives are written with spaces
function underscore_hint(word::Symbol)
    parts = split(String(word), "_")
    found = filter(s -> Tuple(s) in COMPOUND_DIRECTIVES, segmentations(parts))
    isempty(found) && return ""
    return "; compound directives are written with spaces: `@pragma \"omp $(join(found[1], " "))\"`"
end

"""
    lookup_directive(ctx, words) -> Union{Tuple{Symbol,Vector{Symbol}},Nothing}

`(spelling, leaf spellings)` of the leaf or compound directive named by `words`: a leaf
directive whose name has `_` may be written with spaces (`target data` is `target_data`),
and the leaf directives of a compound directive are separated by spaces (`parallel for`).
"""
function lookup_directive(ctx::Context, words::Vector{Symbol})
    full = Symbol(join(words, "_"))
    full in LEAF_SPELLINGS && return (full, [full])
    found = filter(s -> Tuple(s) in COMPOUND_DIRECTIVES, segmentations(String.(words)))
    isempty(found) && return nothing
    length(found) == 1 || fail(ctx, "ambiguous directive name `$(join(words, " "))`: $(join((join(s, " ") for s in found), ", ", " or "))")
    return (Symbol(join(only(found), "_")), only(found))
end

# all ways of grouping consecutive `words` into leaf directive spellings
function segmentations(words::AbstractVector{<:AbstractString})
    isempty(words) && return [Symbol[]]
    out = Vector{Symbol}[]
    for j in 1:length(words)
        leaf = Symbol(join(words[1:j], "_"))
        leaf in LEAF_SPELLINGS || continue
        for rest in segmentations(words[j+1:end])
            push!(out, [leaf; rest])
        end
    end
    return out
end

"""
    select_leafs(ctx, spellings, has_body) -> Vector{DirectiveSpec}

The leaf directives for their spellings. When several directives share a spelling (e.g.
`ordered`), the presence of associated code tells them apart.
"""
function select_leafs(ctx::Context, spellings::Vector{Symbol}, has_body::Bool)
    map(spellings) do s
        all_cands = DIRECTIVES_BY_SPELLING[s]
        cands = filter(available, all_cands)
        isempty(cands) &&
            fail(ctx, "directive `$s` is specific to the $(all_cands[1].language) base language: it is not available in Julia")
        length(cands) == 1 && return only(cands)
        i = findfirst(d -> (d.association in BODY_REQUIRED) == has_body, cands)
        return cands[something(i, 1)]
    end
end

"""
    parse_directive_arguments(ctx, args) -> Vector{Argument}

Arguments of the (last leaf) directive, e.g. the name of `critical(name)`. When a directive
has several arguments, they may be separated with `:` (`declare_variant(base : variant)`).
"""
function parse_directive_arguments(ctx::Context, exs)
    leaf = ctx.leafs[end]
    what = "directive `$(directive_spelling(ctx))`"
    if exs === nothing
        any(!is_optional, leaf.arguments) &&
            fail(ctx, "$what requires arguments: `$(leaf.spelling)($(join((a.spelling for a in leaf.arguments), ", ")))`")
        return Argument[]
    end
    if exs isa TextCall
        t = exs
        specs = leaf.arguments
        mode = length(specs) > 1 ? :all : (length(specs) == 1 && specs[1].kind === :stylized) ? :whole : :comma
        return with_span(ctx, t.span) do
            match_arguments(ctx, specs, split_text(ctx, ctx.text, t.args, mode), what)
        end
    end
    if length(leaf.arguments) > 1 && length(exs) == 1 && split_colon(exs[1]) !== nothing
        exs = split_colons(exs[1])
    end
    return match_arguments(ctx, leaf.arguments, exs, what)
end

"""
    parse_directive_specification(ctx, ex, what) -> Directive

A directive nested in a clause (`when`, `otherwise` of metadirectives): in a directive
string, its text (`when(user={condition(c)}: teams loop)`); in the bare form, a directive
name or a tuple of a name and clauses (`(parallel, num_threads(4))`).
"""
function parse_directive_specification(ctx::Context, ex, what::String)
    try
        if ex isa RawText || (ex isa Symbol && ctx.text !== nothing)
            span = ex isa RawText ? ex.span : something(ctx.span, 1:0)
            sub = Context(ctx.source, DirectiveSpec[], ctx.text, nothing)
            if ex isa Symbol
                return parse_tokens(sub, Any[TextCall(ex, nothing, span)], nothing, true, false)
            end
            return parse_text(sub, ctx.text, ex.span; body = nothing, nested = true)
        end
        tokens = Meta.isexpr(ex, :tuple) ? ex.args : Any[ex]
        return parse_pragma(tokens; source = ctx.source, nested = true)
    catch e
        e isa OpenMPSyntaxError || rethrow()
        throw(OpenMPSyntaxError("in $what: $(e.msg)", ctx.source))
    end
end

# -- Julia keywords in the bare form ------------------------------------------------------

"Julia keywords: they cannot be written where Julia expects an expression."
const JULIA_KEYWORDS = Set([:baremodule, :begin, :break, :catch, :const, :continue, :do, :else,
                            :elseif, :end, :export, :finally, :for, :function, :global, :if,
                            :import, :let, :local, :macro, :module, :quote, :return, :struct,
                            :try, :using, :while])

julia_keyword(x::Symbol) = x in JULIA_KEYWORDS ? x : nothing
julia_keyword(x::QuoteNode) = x.value isa Symbol ? julia_keyword(x.value) : nothing
function julia_keyword(x::Expr)
    x.head in (:local, :global, :const) && return x.head
    x.head === :call && return julia_keyword(x.args[1])
    Meta.isexpr(x, :quote, 1) && return julia_keyword(x.args[1])
    return nothing
end
julia_keyword(_) = nothing

# statements that Julia parsed from a keyword where a directive name was expected
const STATEMENT_KEYWORDS = Dict(:block => :begin, :for => :for, :if => :if, :while => :while,
                                :let => :let, :do => :do, :try => :try, :function => :function)

"""
    check_bare(ctx, args)

In the bare form, report Julia keywords (`for`, `if`, `begin`, `local`, ...) that Julia
managed to parse (`:for`, `var"if"(c)`, `local(x)`, `@pragma omp for i in ...`), and
suggest the equivalent directive string. Keywords that Julia cannot parse at all (`@pragma
omp parallel for begin ... end`) are reported by Julia itself, before `@pragma` runs.
"""
function check_bare(ctx::Context, args::Vector{Any})
    isempty(args) && return
    if args[1] isa Expr && haskey(STATEMENT_KEYWORDS, args[1].head)
        kw = STATEMENT_KEYWORDS[args[1].head]
        fail(ctx, "`$kw` is a Julia keyword: in `@pragma omp $kw ...`, Julia parses `$kw` as the start of " *
                  "Julia code, so the directive name is missing. Write the directive as a string, e.g. " *
                  "`@pragma \"omp $kw\"` followed by the associated code.")
    end
    for (i, a) in enumerate(args)
        kw = julia_keyword(a)
        kw === nothing && continue
        fail(ctx, "`$kw` is a Julia keyword: it cannot be written in `@pragma omp ...` (Julia parses " *
                  "`$(code(a))`). Write the directive as a string: $(suggest_string(args))")
    end
end

"""
    check_ambiguous_loop(ctx, body)

`@pragma omp parallel for i in 1:n ... end` reads like the C directive `parallel for`, but
Julia parses it as the directive `parallel` followed by a `for` loop: report it.
"""
function check_ambiguous_loop(ctx::Context, body)
    Meta.isexpr(body, :for) || return
    ctx.leafs[end].association === :loop_nest && return
    spellings = [l.spelling for l in ctx.leafs]
    Tuple([spellings; :for]) in COMPOUND_DIRECTIVES || return
    name = join(spellings, " ")
    fail(ctx, "ambiguous directive: `@pragma omp $name for ...` is parsed by Julia as the directive " *
              "`$name` followed by a `for` loop, not as the directive `$name for`. For `$name for`, " *
              "write `@pragma \"omp $name for ...\" for ...`; for a `$name` region containing the loop, " *
              "write `@pragma \"omp $name ...\" begin for ... end end`.")
end

"""
    suggest_string(args) -> String

The directive string equivalent to the bare-form arguments `args` (without the associated
code), e.g. `@pragma "omp parallel for if(c)"`.
"""
function suggest_string(args::Vector{Any})
    toks = args
    if !isempty(toks) && !is_clause_shaped(toks[end]) && julia_keyword(toks[end]) === nothing
        toks = toks[1:end-1] # associated code
    end
    return "`@pragma \"omp $(join(map(token_text, toks), " "))\"`"
end

token_text(x::QuoteNode) = string(x.value)
token_text(x::Symbol) = string(x)
function token_text(x::Expr)
    if x.head in (:local, :global, :const)
        return "$(x.head)($(join(map(argument_text, x.args), ", ")))"
    elseif x.head === :call
        name = something(name_token(x.args[1]), Some(code(x.args[1])))
        return "$name($(join(map(argument_text, x.args[2:end]), ", ")))"
    end
    return code(x)
end
token_text(x) = code(x)

function argument_text(x)
    s = split_colon(x)
    s !== nothing && return "$(argument_text(s[1])): $(argument_text(s[2]))"
    Meta.isexpr(x, :kw, 2) && return "$(code(x.args[1])) = $(code(x.args[2]))"
    return code(x)
end
