# Data environment: the variables that the associated code refers to.

const NOT_VARIABLES = (:end, :begin, :nothing, :missing, :true, :false)

"""
    free_variables(ex, mod) -> Vector{Symbol}

The variables that `ex` (macro-expanded in `mod`) may refer to in its enclosing local scope,
in order of appearance: not those it binds itself, nor the constants of `mod` (functions,
types, ...), nor called functions.
"""
function free_variables(ex, mod::Module)
    found = Symbol[]
    walk_free!(found, macroexpand(mod, ex), Set{Symbol}())
    return filter(s -> !(isdefined(mod, s) && isconst(mod, s)), unique!(found))
end

isvar(s::Symbol) = !(s in NOT_VARIABLES) && !startswith(string(s), '#')

walk_free!(found, s::Symbol, bound) = (isvar(s) && !(s in bound) && push!(found, s); nothing)
walk_free!(found, x, bound) = nothing

# the variables bound by a definition: `x`, `x::T`, `x = default`, `(a, b)`, `f(args)`, ...
bindings(s::Symbol) = [s]
bindings(x) = Symbol[]
function bindings(ex::Expr)
    h, a = ex.head, ex.args
    h in (:(::), :kw, :(=), :..., :where) && return bindings(a[1])
    h === :call && return mapreduce(bindings, vcat, a[2:end]; init = Symbol[])
    h in (:tuple, :parameters, :block) && return mapreduce(bindings, vcat, a; init = Symbol[])
    return Symbol[]
end

defines_function(ex) =
    Meta.isexpr(ex, (:function, :->)) || (Meta.isexpr(ex, :(=), 2) && Meta.isexpr(ex.args[1], (:call, :where)))

function walk_free!(found, ex::Expr, bound)
    h, a = ex.head, ex.args
    if h in (:quote, :inert, :meta, :line, :global, :using, :import, :export, :public, :module)
        return
    elseif h === :.
        walk_free!(found, a[1], bound)
        length(a) > 1 && !(a[2] isa QuoteNode) && walk_free!(found, a[2], bound)
    elseif h === :call
        a[1] isa Symbol || walk_free!(found, a[1], bound)  # called functions are not variables
        for x in a[2:end]
            walk_free!(found, Meta.isexpr(x, :kw) ? x.args[2] : x, bound)
        end
    elseif h === :parameters
        for x in a
            walk_free!(found, Meta.isexpr(x, :kw) ? x.args[2] : x, bound)
        end
    elseif h === :local
        for x in a
            union!(bound, bindings(x))
            Meta.isexpr(x, :(=)) && walk_free!(found, x.args[2], bound)
        end
    elseif defines_function(ex)
        length(a) == 2 && walk_free!(found, a[2], union(bound, bindings(a[1])))
    elseif h === :let
        inner = copy(bound)
        for x in (Meta.isexpr(a[1], :block) ? a[1].args : [a[1]])
            Meta.isexpr(x, :(=)) && walk_free!(found, x.args[2], inner)
            union!(inner, bindings(x))
        end
        walk_free!(found, a[2], inner)
    elseif h === :for || h === :generator || h === :filter
        specs, body = h === :for ? (a[1], a[2]) : (a[2:end], a[1])
        specs = specs isa Expr && specs.head === :block ? specs.args : specs isa Vector ? specs : [specs]
        inner = copy(bound)
        for s in specs
            Meta.isexpr(s, :(=)) || (walk_free!(found, s, inner); continue)
            walk_free!(found, s.args[2], bound)
            union!(inner, bindings(s.args[1]))
        end
        walk_free!(found, body, inner)
    elseif h === :try
        walk_free!(found, a[1], bound)
        length(a) >= 3 && walk_free!(found, a[3], a[2] isa Symbol ? union(bound, [a[2]]) : bound)
        for x in a[4:end]
            walk_free!(found, x, bound)
        end
    elseif h === :macrocall
        for x in a[2:end]
            walk_free!(found, x, bound)
        end
    else
        for x in a
            walk_free!(found, x, bound)
        end
    end
    return
end

"""
    Privatization(prologue, body, epilogue)

The data environment of the threads of a team: `prologue` and `epilogue` run on the
encountering thread, before and after the threads run `body`.
"""
struct Privatization
    prologue::Vector{Any}
    body::Any
    epilogue::Vector{Any}
end

function variables(d::Directive, c::Clause)
    items = list_items(c)
    for x in items
        x isa Symbol || unsupported(d, "list item `$x` of clause `$(c.spec.spelling)`: only variables are supported")
    end
    return Vector{Symbol}(items)
end

"""
    privatize(d::Directive, body, mod; team) -> Privatization

Apply the data-sharing clauses of `d` (`private`, `firstprivate`, `reduction`, `default`) to
`body`, run by the threads of a team of at most `team` threads (an expression).
"""
function privatize(d::Directive, body, mod::Module; team)
    private, firstprivate, explicit = Symbol[], Symbol[], Symbol[]
    reductions = Tuple{Any,Symbol}[]
    for c in d.clauses
        name = c.spec.name
        name in (:private, :firstprivate, :shared, :reduction) || continue
        vars = variables(d, c)
        append!(explicit, vars)
        if name === :private
            append!(private, vars)
        elseif name === :firstprivate
            append!(firstprivate, vars)
        elseif name === :reduction
            for m in (:task_modifier, :inscan_modifier, :per_thread_modifier)
                modifier(c, m) === nothing || unsupported(d, "reduction modifier `$(modifier(c, m))`")
            end
            op = combiner(modifier(c, :reduction_identifier))
            append!(reductions, ((op, v) for v in vars))
        end
    end
    prologue, epilogue = Any[], Any[]
    lets = Any[]
    candidates = default_variables(d, body, mod, explicit)
    append!(private, candidates.private)
    for v in private
        push!(lets, v)
    end
    for v in firstprivate
        value = gensym(v)
        push!(prologue, :($value = $v))
        push!(lets, :($v = $value))
    end
    for v in candidates.firstprivate  # may be undefined: then private
        value = gensym(v)
        push!(prologue, :($value = $(Expr(:isdefined, v)) ? Some($v) : nothing))
        push!(lets, v)
        body = quote
            $value === nothing || ($v = something($value))
            $body
        end
    end
    stores = Any[]
    for (op, v) in reductions
        original, partials, f = gensym(v), gensym(:partials), gensym(:op)
        append!(prologue, [:($f = $op), :($original = $v), :($partials = $(ref(:new_partials))($team))])
        push!(lets, :($v = $(ref(:reduction_identity))($f, $original)))
        push!(stores, :($partials[$(ref(:thread_index))()] = $v))
        push!(epilogue, :($v = $(ref(:reduce_partials))($f, $v, $partials)))
    end
    isempty(lets) && return Privatization(prologue, body, epilogue)
    return Privatization(prologue, Expr(:let, Expr(:block, lets...), Expr(:block, body, stores...)), epilogue)
end

"The variables that `default(private)` or `default(firstprivate)` privatize."
function default_variables(d::Directive, body, mod::Module, explicit)
    none = (private = Symbol[], firstprivate = Symbol[])
    c = clause(d, :default)
    c === nothing && return none
    behavior = argument(c, :default_behavior)
    category = modifier(c, :variable_category)
    category in (nothing, :all) || unsupported(d, "default variable category `$category`")
    modifier(c, :optional_modifier) === nothing || unsupported(d, "default modifier `optional`")
    behavior in (:private, :firstprivate) || return none
    vars = setdiff(free_variables(body, mod), explicit)
    return behavior === :private ? (private = vars, firstprivate = Symbol[]) : (private = Symbol[], firstprivate = vars)
end
