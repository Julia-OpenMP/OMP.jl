# Code generation entry point.
#
# Hand-written: the front-end hands each parsed and validated directive to `lower`. Support
# for a directive is added with a method for its spelling, e.g.
#
#     lower(::Val{:barrier}, d::Directive, mod::Module) = :(\$barrier())
#
# where `d.body` is the associated code (to be escaped in the returned expression).

"""
    UnsupportedDirectiveError(directive)

The directive is valid, but OMP.jl cannot generate code for it yet.
"""
struct UnsupportedDirectiveError <: Exception
    directive::Directive
end

function Base.showerror(io::IO, e::UnsupportedDirectiveError)
    d = e.directive
    print(io, "OpenMP directive `")
    print_directive(io, d)
    print(io, "` is not supported yet")
    d.source === nothing || print(io, " (at ", d.source.file, ":", d.source.line, ")")
    print(io, ": it is valid, but OMP.jl cannot generate code for it. Use `@pragma_ir` to inspect how it is parsed.")
end

"""
    lower(d::Directive, mod::Module) -> Expr

Generate the code of the directive `d`, expanded in module `mod`. Dispatches to
`lower(::Val{d.name}, d, mod)`.
"""
lower(d::Directive, mod::Module) = lower(Val(d.name), d, mod)
lower(::Val, d::Directive, ::Module) = throw(UnsupportedDirectiveError(d))
