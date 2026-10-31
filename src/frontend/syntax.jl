# Errors, and helpers on the Julia expressions that make up a directive.
#
# Julia parses the arguments of `@pragma omp ...` as Julia code, which constrains how
# OpenMP is spelled (see conventions.jl): this file deals with the resulting expressions.

"""
    OpenMPSyntaxError(msg, source)

Error in an OpenMP directive, thrown at macro expansion time.
"""
struct OpenMPSyntaxError <: Exception
    msg::String
    source::Union{Nothing,LineNumberNode}
end

OpenMPSyntaxError(msg::AbstractString) = OpenMPSyntaxError(msg, nothing)

function Base.showerror(io::IO, e::OpenMPSyntaxError)
    print(io, "OpenMP syntax error")
    e.source === nothing || print(io, " at ", e.source.file, ":", e.source.line)
    print(io, ": ", e.msg)
end

"Print `ex` as Julia code, for error messages."
code(ex) = ex isa Symbol ? string(ex) : sprint(Base.show_unquoted, ex)

"Like [`code`](@ref), abbreviating multi-line code: `begin ... end`, `for i = 1:n ... end`."
function brief(ex)
    s = code(ex)
    occursin('\n', s) || return s
    return string(strip(first(split(s, '\n'))), " ... end")
end

"""
    name_token(ex) -> Union{Symbol,Nothing}

The name `ex` stands for, if it is a name: a symbol (`parallel`) or a quoted symbol
(`:parallel`). Julia keywords (`:for`, `var"for"`) are reported by `check_bare` in the bare
form: they are written in directive strings.
"""
name_token(ex::Symbol) = ex
name_token(ex::QuoteNode) = ex.value isa Symbol ? ex.value : nothing
name_token(ex::Expr) = Meta.isexpr(ex, :quote, 1) && ex.args[1] isa Symbol ? ex.args[1] : nothing
name_token(_) = nothing

"""
    call_parts(ex) -> Union{Tuple{Symbol,Vector{Any}},Nothing}

`(name, arguments)` if `ex` is a name, possibly applied to arguments: `nowait`,
`num_threads(4)`, `:if(c)`. Keyword arguments (`a = b`) are returned as `=` expressions;
`;`-separated arguments are an error.
"""
function call_parts(ex)
    name = name_token(ex)
    name === nothing || return (name, Any[])
    Meta.isexpr(ex, :call) || return nothing
    name = name_token(ex.args[1])
    name === nothing && return nothing
    args = Any[kw_to_assign(a) for a in ex.args[2:end]]
    if any(a -> Meta.isexpr(a, :parameters), args)
        throw(OpenMPSyntaxError("`;` is not supported in `$(code(ex))`: use separate clauses"))
    end
    return (name, args)
end

kw_to_assign(ex) = Meta.isexpr(ex, :kw, 2) ? Expr(:(=), ex.args...) : ex

const COLON_PRECEDENCE = Base.operator_precedence(:(:))

is_colon(ex) = Meta.isexpr(ex, :call) && ex.args[1] === :(:) && length(ex.args) in (3, 4)

# binary operations that bind less tightly than `:` (so `a : b > c` parses as `(a:b) > c`)
function loose_binary(ex)
    ex isa Expr || return false
    ex.head in (:&&, :||, :(=), :kw, :comparison) && return true
    return ex.head === :call && length(ex.args) == 3 && ex.args[1] isa Symbol &&
           Base.isoperator(ex.args[1]) && Base.operator_precedence(ex.args[1]) < COLON_PRECEDENCE
end

# operand positions of a loose binary operation: (left, right)
operands(ex::Expr) =
    ex.head === :call ? (2, 3) : ex.head === :comparison ? (1, length(ex.args)) : (1, 2)

"""
    split_colon(ex) -> Union{Tuple{Any,Any},Nothing}

Split `ex` at its first top-level `:`, as written in the source: `in : x` gives
`(:in, :x)`. Julia's precedence makes `parallel : n > 10` parse as `(parallel : n) > 10`:
this returns `(:parallel, :(n > 10))`. A three-part `a : b : c` gives `(a, :(b : c))`.
"""
function split_colon(ex)
    if is_colon(ex)
        rest = length(ex.args) == 3 ? ex.args[3] : Expr(:call, :(:), ex.args[3], ex.args[4])
        return (ex.args[2], rest)
    end
    loose_binary(ex) || return nothing
    l, r = operands(ex)
    s = split_colon(ex.args[l])
    if s !== nothing
        e = copy(ex)
        e.args[l] = s[2]
        return (s[1], e)
    end
    s = split_colon(ex.args[r])
    if s !== nothing
        e = copy(ex)
        e.args[r] = s[1]
        return (e, s[2])
    end
    return nothing
end

"""
    split_colons(ex) -> Vector{Any}

All `:`-separated parts of `ex` (see [`split_colon`](@ref)).
"""
function split_colons(ex)
    parts = Any[]
    while (s = split_colon(ex)) !== nothing
        push!(parts, s[1])
        ex = s[2]
    end
    push!(parts, ex)
    return parts
end

"Whether `ex` is a literal (number, string, character, boolean)."
is_literal(ex) = ex isa Union{Number,AbstractString,AbstractChar} ||
                 (Meta.isexpr(ex, :call, 2) && ex.args[1] in (:-, :+) && ex.args[2] isa Number)

"Value of a literal (see [`is_literal`](@ref))."
literal_value(ex) = Meta.isexpr(ex, :call) ? (ex.args[1] === :- ? -ex.args[2] : ex.args[2]) : ex
