# User-facing macros.

"""
    parse_macro(args, source; prefix) -> Directive

Parse the arguments of `@pragma` (`prefix = true`: `"omp ..."` / `omp ...`) or `@omp`
(`prefix = false`).
"""
function parse_macro(args::Tuple, source::LineNumberNode; prefix::Bool)
    ctx = Context(source, DirectiveSpec[])
    macroname = prefix ? "@pragma" : "@omp"
    isempty(args) && fail(ctx, "missing directive: write `$macroname \"$(prefix ? "omp " : "")parallel\"`")
    first = args[1]
    if Meta.isexpr(first, :string)
        fail(ctx, "interpolation (`\$`) is not supported in directive strings: refer to variables by name, e.g. `if(n > 10)`")
    elseif first isa AbstractString
        rest = args[2:end]
        length(rest) > 1 &&
            fail(ctx, "expected the associated code only after the directive string, got `$(join(map(brief, rest), " "))`: clauses go inside the string")
        return parse_pragma_text(first, isempty(rest) ? nothing : Some(rest[1]); source, prefix)
    elseif prefix
        first === :omp ||
            fail(ctx, "expected `@pragma \"omp ...\"`, got `@pragma $(join(map(code, args), " "))`")
        return parse_pragma(collect(Any, args[2:end]); source)
    else
        return parse_pragma(collect(Any, args); source)
    end
end

"""
    @pragma "omp directive [clauses...]" [associated code]

An OpenMP directive, written as in C/C++/Fortran, followed by its associated code if any:

```julia
@pragma "omp parallel num_threads(4)" begin
    ...
end

@pragma "omp parallel for reduction(+: s) schedule(dynamic, 4)" for i in eachindex(x)
    s += x[i]
end

@pragma "omp task depend(in: a) depend(out: b) if(n > 10)" begin
    ...
end

@pragma "omp barrier"
```

Expressions in clauses are Julia code referring to the variables of the caller.

Directives that are valid Julia syntax, i.e. without Julia keywords (`for`, `if`, `do`,
`begin`, `local`, ...), may also be written without a string:
`@pragma omp task depend(in: a) begin ... end`.

Syntax errors are reported at macro expansion time as [`OpenMPSyntaxError`](@ref)s.
"""
macro pragma(args...)
    return lower(parse_macro(args, __source__; prefix = true), __module__)
end

"""
    @omp "directive [clauses...]" [associated code]

Same as [`@pragma "omp ..."`](@ref @pragma), e.g. `@omp "parallel for" for i in 1:n ... end`.
"""
macro omp(args...)
    return lower(parse_macro(args, __source__; prefix = false), __module__)
end

"""
    @pragma_ir "omp directive [clauses...]" [associated code]

The [`Directive`](@ref) that `@pragma` parses, without generating any code: for debugging
and testing.
"""
macro pragma_ir(args...)
    return parse_macro(args, __source__; prefix = true)
end
