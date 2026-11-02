# Code generation entry point. A backend adds a method of `lower` per leaf directive:
#
#     lower(::Val{:barrier}, d::Directive, mod::Module) = :($barrier())
#
# The returned code is escaped as a whole, in the caller's scope: it refers to its own
# temporaries with `gensym`s, and to functions by value or `GlobalRef`. `d.body` is the
# associated code, or the code of the inner leafs of a compound directive.

"""
    UnsupportedDirectiveError(directive, reason = "")

The directive is valid, but OMP.jl cannot generate code for it yet.
"""
struct UnsupportedDirectiveError <: Exception
    directive::Directive
    reason::String
end
UnsupportedDirectiveError(d::Directive) = UnsupportedDirectiveError(d, "")

unsupported(d::Directive, reason::AbstractString = "") = throw(UnsupportedDirectiveError(d, reason))

function Base.showerror(io::IO, e::UnsupportedDirectiveError)
    d = e.directive
    print(io, "OpenMP directive `")
    print_directive(io, d)
    print(io, "` is not supported yet")
    isempty(e.reason) || print(io, ": ", e.reason)
    d.source === nothing || print(io, " (at ", d.source.file, ":", d.source.line, ")")
    isempty(e.reason) &&
        print(io, ": it is valid, but OMP.jl cannot generate code for it. Use `@pragma_ir` to inspect how it is parsed.")
end

"""
    lower(d::Directive, mod::Module) -> Expr

Generate the code of the directive `d`, expanded in module `mod`. Dispatches to
`lower(::Val{d.name}, d, mod)`; a compound directive without its own method is lowered as
its outermost leaf, associated with the code of the others.
"""
lower(d::Directive, mod::Module) = lower(Val(d.name), d, mod)

function lower(::Val, d::Directive, mod::Module)
    is_compound(d) || unsupported(d)
    outer, inner = split_compound(d)
    body = lower(inner, mod)
    outer = Directive(outer.name, outer.leafs, outer.arguments, outer.clauses, body, outer.source)
    return lower(Val(outer.name), outer, mod)
end
