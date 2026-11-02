# Reductions. A reduction identifier is a combiner function; a user-defined one gets its
# identity from a method of `reduction_identity`, or else `Base.reduce_empty`.

and(a, b) = a && b
or(a, b) = a || b

"""
    Broadcasted(op)

The combiner of a dotted reduction identifier (`.+`): `op`, element-wise.
"""
struct Broadcasted{F}
    op::F
end
(b::Broadcasted)(x, y) = b.op.(x, y)

"""
    combiner(identifier::Symbol) -> expression of the combiner function

The reduction identifiers of OpenMP have their C meaning: `-` is `+`, `^` is `xor`.
"""
function combiner(id::Symbol)
    s = string(id)
    startswith(s, ".") && length(s) > 1 && return :($Broadcasted($(combiner(Symbol(s[2:end])))))
    id === :&& && return and
    id === :|| && return or
    id === :- && return +
    id === :^ && return xor
    return id  # a function of the caller's scope
end

"""
    reduction_identity(op, x)

The identity of the combiner `op`, for the value `x` of the original list item. Add a method
for a user-defined reduction identifier.
"""
reduction_identity(op, x) = Base.reduce_empty(op, typeof(x))
reduction_identity(::typeof(+), x) = zero(x)
reduction_identity(::typeof(*), x) = one(x)
reduction_identity(::typeof(&), x) = ~zero(x)
reduction_identity(::typeof(|), x) = zero(x)
reduction_identity(::typeof(xor), x) = zero(x)
reduction_identity(::typeof(and), x) = true
reduction_identity(::typeof(or), x) = false
reduction_identity(::typeof(max), x) = typemin(x)
reduction_identity(::typeof(min), x) = typemax(x)
reduction_identity(b::Broadcasted, x::AbstractArray) = map(v -> reduction_identity(b.op, v), x)

"No partial result: the thread was not part of the team."
struct Unset end

"Combine the original value `x` with the partial results, in the order of the threads."
function reduce_partials(op, x, partials::Vector{Any})
    for p in partials
        p isa Unset || (x = op(x, p))
    end
    return x
end

new_partials(n::Integer) = Any[Unset() for _ in 1:n]
