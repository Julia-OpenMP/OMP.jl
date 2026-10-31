# How OpenMP directives are spelled in Julia.
#
# Hand-written: these are design decisions of OMP.jl, on top of the syntax of the
# specification (generated/).
#
# Directive strings (the default) are written as in C/C++/Fortran, the associated code
# (structured block, loop nest, function definition) following the string:
#
#     @pragma "omp parallel for reduction(+: s) if(n > 10)" for i in 1:n ... end
#     @pragma "omp task depend(in: a) depend(out: b)" begin ... end
#     @pragma "omp barrier"
#
# * leaf directive names are those of the specification; those with `_` may also be
#   written with spaces (`target data`, `declare reduction`); compound directives separate
#   their leaf directives with spaces (`target teams distribute parallel for`);
# * clauses may be separated by commas; inside a clause, the first top-level `:` separates
#   modifiers from arguments, and each comma-separated piece is a Julia expression
#   referring to the variables of the caller (no `$` interpolation);
# * use a triple-quoted string for directives containing string literals:
#   `@pragma """omp error message("...")"""`.
#
# The bare form `@pragma omp ...` is accepted when the directive is valid Julia syntax,
# i.e. it contains no Julia keyword (`for`, `do`, `if`, `begin`, `local`, ...) and no
# operator before a `:` (write `(+) : s`): `@pragma omp task depend(in: a) begin ... end`.
# Keywords that Julia parses are reported with the equivalent directive string; the others
# are parse errors raised by Julia itself before `@pragma` runs. The associated code is the
# last argument; inside parentheses, Julia parses `@pragma omp ... for i in 1:n ... end` as
# a generator: write such directives as statements.

"""
Base languages whose language-specific directives (e.g. Fortran's `do`, `workshare`) are not
available in Julia.
"""
const EXCLUDED_LANGUAGES = (:fortran, :longfortran)

"""
Directive associations that require associated code: the last argument of the macro.
"""
const BODY_REQUIRED = (:block, :loop_nest, :loop_sequence, :declaration, :delimited)

"""
Directive associations whose associated code is optional (`section`, `scan`).
"""
const BODY_OPTIONAL = (:separating,)

"""
Alternative spellings of directive name words: `alias => spelling`.
"""
const DIRECTIVE_ALIASES = Dict{Symbol,Symbol}()

"""
Alternative spellings of clause names: `alias => spelling`.
"""
const CLAUSE_ALIASES = Dict{Symbol,Symbol}()

"""
Keywords accepted in addition to those of the specification, per keyword argument or
modifier: `(name, alias) => keyword`.
"""
const KEYWORD_ALIASES = Dict{Tuple{Symbol,Symbol},Symbol}(
    # map-type: `alloc` (map-entering constructs) and `release` (map-exiting constructs) are
    # accepted with the meaning of `storage`
    (:map_type, :alloc) => :storage,
    (:map_type, :release) => :storage,
)

"""
Properties of the specification data that the front-end ignores because they contradict
the text of the specification, as `(kind, name) => properties` where kind is `:clause`,
`:modifier`, `:clause_set` or `:modifier_set`. Report them upstream and remove them once
fixed in the specification.
"""
const IGNORED_PROPERTIES = Dict{Tuple{Symbol,Symbol},Syms}(
    # "If no variable-category is specified in the clause ...": the modifiers of the
    # variable-selector group are optional (e.g. `default(shared)`)
    (:modifier_set, :variable_selector) => (:required,),
)

"""
    has_property(kind::Symbol, spec, property::Symbol)

Whether `spec` has `property`, unless the front-end ignores it (see
[`IGNORED_PROPERTIES`](@ref)).
"""
Schema.has_property(kind::Symbol, spec, property::Symbol) =
    has_property(spec, property) && !(property in get(IGNORED_PROPERTIES, (kind, spec.name), ()))

"""
    desugar_clause(spec::ClauseSpec, args::Vector{Any}) -> Vector{Any}

Rewrite the arguments of a clause before they are parsed, to accept Julia-friendly
spellings. Extend with methods of `desugar_clause(::Val{name}, spec, args)`.
"""
desugar_clause(spec::ClauseSpec, args::Vector{Any}) = desugar_clause(Val(spec.name), spec, args)
desugar_clause(::Val, ::ClauseSpec, args::Vector{Any}) = args

# Reduction clauses: besides `reduction((+) : x, y)`, accept
#   reduction(+, x, y)     the reduction identifier is a leading operator
#   reduction(+:x)         parsed by Julia as `+(:x)`
for name in (:reduction, :in_reduction, :task_reduction)
    @eval desugar_clause(::Val{$(QuoteNode(name))}, ::ClauseSpec, args::Vector{Any}) =
        desugar_reduction(args)
end

is_operator(x) = x isa Symbol && Base.isoperator(x)

function desugar_reduction(args::Vector{Any})
    (isempty(args) || any(a -> split_colon(a) !== nothing, args)) && return args
    a = args[1]
    if Meta.isexpr(a, :call, 2) && is_operator(a.args[1]) && a.args[2] isa QuoteNode
        return Any[Expr(:call, :(:), a.args[1], a.args[2].value); args[2:end]]
    elseif length(args) >= 2 && is_operator(a)
        return Any[Expr(:call, :(:), a, args[2]); args[3:end]]
    end
    return args
end
