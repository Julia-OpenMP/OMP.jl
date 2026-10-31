# Directive strings: `@pragma "omp parallel for reduction(+: s) if(n > 10)"`.
#
# The text is split like a C/C++ compiler splits a pragma: into directive-name words and
# clauses (`name` or `name(...)`, optionally separated by commas); the inside of the
# parentheses is split at top-level `,` and at the first top-level `:` (the modifier
# separator), and each piece is parsed as a Julia expression. So OpenMP is written as in
# C/C++/Fortran (`for`, `if`, `+:`, `local(x)`), while expressions remain Julia code
# referring to the variables of the caller.

"""
    TextCall(name, args, span)

A word (`parallel`, `nowait`) or call (`num_threads(4)`) of a directive string: `args` is
the range of the text inside the parentheses (`nothing` without parentheses), `span` the
range of the whole token.
"""
struct TextCall
    name::Symbol
    args::Union{Nothing,UnitRange{Int}}
    span::UnitRange{Int}
end

"""
    RawText(text, span, msg)

A piece of a directive string that is not a valid Julia expression (`msg` says why), e.g.
the nested directive `teams loop` of a metadirective.
"""
struct RawText
    text::String
    span::UnitRange{Int}
    msg::String
end

code(r::RawText) = r.text

is_name_start(c::AbstractChar) = isletter(c) || c == '_'
is_name_char(c::AbstractChar) = isletter(c) || isdigit(c) || c == '_'

function skip_spaces(text::String, i::Int, stop::Int)
    while i <= stop && isspace(text[i])
        i = nextind(text, i)
    end
    return i
end

# index after a string or character literal starting at `i`, or `nothing` if there is none
function skip_literal(text::String, i::Int, stop::Int)
    c = text[i]
    if c == '"'
        j = nextind(text, i)
        while j <= stop
            text[j] == '\\' && (j = nextind(text, j))
            j <= stop && text[j] == '"' && return nextind(text, j)
            j = nextind(text, j)
        end
        return stop + 1 # unterminated: caught by the caller's checks
    elseif c == '\''
        m = match(r"^'(\\.[^']*|[^\\'])'", SubString(text, i, stop))
        return m === nothing ? nothing : i + ncodeunits(m.match)
    end
    return nothing
end

const OPENERS = Dict('(' => ')', '[' => ']', '{' => '}')

# index of the parenthesis closing the one at `i`
function matching_paren(ctx::Context, text::String, i::Int, stop::Int)
    stack = Char[]
    j = i
    while j <= stop
        c = text[j]
        k = skip_literal(text, j, stop)
        if k !== nothing
            j = k
            continue
        end
        if haskey(OPENERS, c)
            push!(stack, OPENERS[c])
        elseif c in (')', ']', '}')
            if isempty(stack) || pop!(stack) != c
                ctx.span = j:j
                fail(ctx, "unbalanced `$c`")
            end
            isempty(stack) && return j
        end
        j = nextind(text, j)
    end
    ctx.span = i:i
    fail(ctx, "unclosed `$(text[i])`")
end

"""
    tokenize(ctx, text, range) -> Vector{TextCall}

Split `text[range]` into words and calls.
"""
function tokenize(ctx::Context, text::String, range::UnitRange{Int})
    toks = TextCall[]
    i, stop = first(range), last(range)
    while true
        i = skip_spaces(text, i, stop)
        i > stop && break
        c = text[i]
        if c == ',' && !isempty(toks)
            i = nextind(text, i)
            continue
        end
        if !is_name_start(c)
            ctx.span = i:i
            fail(ctx, "unexpected `$c`: expected a directive name or a clause")
        end
        j = i
        while j <= stop && is_name_char(text[j])
            j = nextind(text, j)
        end
        name = Symbol(text[i:prevind(text, j)])
        k = skip_spaces(text, j, stop)
        if k <= stop && text[k] == '('
            close = matching_paren(ctx, text, k, stop)
            push!(toks, TextCall(name, nextind(text, k):prevind(text, close), i:close))
            i = nextind(text, close)
        else
            push!(toks, TextCall(name, nothing, i:prevind(text, j)))
            i = j
        end
    end
    return toks
end

"""
    separators(text, range) -> Vector{Pair{Int,Char}}

Positions of the top-level `,` and `:` in `text[range]` (not in brackets or literals, not
`::`, and not the `:` of a ternary `a ? b : c`).
"""
function separators(text::String, range::UnitRange{Int})
    seps = Pair{Int,Char}[]
    depth = 0
    ternary = 0
    j, stop = first(range), last(range)
    while j <= stop
        c = text[j]
        k = skip_literal(text, j, stop)
        if k !== nothing
            j = k
            continue
        end
        if haskey(OPENERS, c)
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif depth == 0
            if c == ','
                push!(seps, j => ',')
                ternary = 0
            elseif c == '?'
                ternary += 1
            elseif c == ':'
                n = nextind(text, j)
                if n <= stop && text[n] == ':'
                    j = nextind(text, n) # `::`
                    continue
                elseif ternary > 0
                    ternary -= 1
                else
                    push!(seps, j => ':')
                end
            end
        end
        j = nextind(text, j)
    end
    return seps
end

"""
    piece(ctx, text, range)

The Julia expression of a piece of a directive string: a symbol for a plain word (even a
Julia keyword, e.g. `for`), the parsed expression, or a [`RawText`](@ref).
"""
function piece(ctx::Context, text::String, range::UnitRange{Int})
    a = skip_spaces(text, first(range), last(range))
    b = last(range)
    while b >= a && isspace(text[b])
        b = prevind(text, b)
    end
    if a > b
        ctx.span = first(range):max(first(range), last(range))
        fail(ctx, "empty argument")
    end
    s = text[a:b]
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", s) && return Symbol(s)
    # an operator on its own (e.g. the reduction identifiers `+`, `&&`, `||`)
    (s in ("&&", "||") || (!any(c -> isletter(c) || isdigit(c) || isspace(c), s) &&
                           Base.isoperator(Symbol(s)))) && return Symbol(s)
    ex = Meta.parse(s; raise = false)
    if Meta.isexpr(ex, (:error, :incomplete))
        msg = ex.args[1]
        msg = msg isa String ? msg : sprint(showerror, msg)
        m = match(r"── (.*)", msg)
        return RawText(s, a:b, m === nothing ? "invalid expression" : strip(m.captures[1]))
    end
    return ex
end

# pieces of `text` between the given separator positions
function pieces(ctx::Context, text::String, range::UnitRange{Int}, cuts::Vector{Int})
    out = Any[]
    a = first(range)
    for c in cuts
        push!(out, piece(ctx, text, a:prevind(text, c)))
        a = nextind(text, c)
    end
    push!(out, piece(ctx, text, a:last(range)))
    return out
end

"""
    split_text(ctx, text, range, mode)

Split the arguments `text[range]` of a clause or directive:
* `:clause`: at `,` and the first `:`, returning `(before, after)`, `after` being `nothing`
  without `:`;
* `:comma`: at `,`;  `:all`: at `,` and `:`;  `:whole`: one piece.
"""
function split_text(ctx::Context, text::String, range::UnitRange{Int}, mode::Symbol)
    if isempty(range) || all(isspace, SubString(text, first(range), last(range)))
        return mode === :clause ? (Any[], nothing) : Any[]
    end
    mode === :whole && return Any[piece(ctx, text, range)]
    seps = separators(text, range)
    if mode === :clause
        i = findfirst(s -> s[2] == ':', seps)
        i === nothing && return (pieces(ctx, text, range, [p for (p, _) in seps]), nothing)
        colon = seps[i][1]
        before = pieces(ctx, text, first(range):prevind(text, colon), [p for (p, _) in seps[1:i-1]])
        after = pieces(ctx, text, nextind(text, colon):last(range), [p for (p, _) in seps[i+1:end]])
        return (before, after)
    end
    cuts = [p for (p, c) in seps if mode === :all || c == ',']
    return pieces(ctx, text, range, cuts)
end

"""
    parse_text(ctx, text, range; body, nested) -> Directive

Parse the directive string `text[range]` (without the `omp` prefix). `body` is the
associated code (`nothing` if none, `Some(ex)` otherwise).
"""
function parse_text(ctx::Context, text::String, range::UnitRange{Int};
                    body::Union{Nothing,Some}, nested::Bool = false)
    ctx.text = text
    toks = tokenize(ctx, text, range)
    return parse_tokens(ctx, Any[toks...], body, nested, false)
end

"""
    parse_pragma_text(text, body; source = nothing, prefix = true) -> Directive

Parse a directive string, e.g. `"omp parallel for reduction(+: s)"` (with the `omp`
prefix when `prefix`), with associated code `body` (`nothing`, or `Some(ex)`).
"""
function parse_pragma_text(text::AbstractString, body::Union{Nothing,Some};
                           source::Union{Nothing,LineNumberNode} = nothing, prefix::Bool = true)
    text = String(text)
    ctx = Context(source, DirectiveSpec[], text, nothing)
    start = 1
    if prefix
        m = match(r"^\s*omp(?![A-Za-z0-9_])", text)
        if m === nothing
            ctx.span = 1:max(1, min(ncodeunits(text), 3))
            fail(ctx, "a directive string starts with `omp`, e.g. `@pragma \"omp parallel\"`")
        end
        start = ncodeunits(m.match) + 1
    end
    return parse_text(ctx, text, start:ncodeunits(text); body)
end
