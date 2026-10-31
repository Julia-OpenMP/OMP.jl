"""
    Schema

Types describing the syntax of OpenMP directives, clauses and modifiers.

This file is hand-written: it is the contract between the generated [`Spec`](@ref
OMP.Frontend.Spec) module, which only *constructs* values of these types through their
keyword constructors, and the hand-written parser that interprets them. Adding a field
here requires a default value (or a change of `omp-generator`).

Names follow the specification, converted to Julia identifiers (`task-dependence-type`
becomes `:task_dependence_type`); `spelling` is what users write.
"""
module Schema

export Syms, ARGUMENT_KINDS, ArgumentSpec, ModifierSpec, MemberSet, ModifierSet, ClauseSet,
       ClauseSpec, ClauseGroupSpec, ModifierGroupSpec, DirectiveSpec, has_property

"A tuple of symbols (names, properties, ...)."
const Syms = Tuple{Vararg{Symbol}}

"""
Kinds of syntactic elements:

| kind                       | syntax                                                          |
|:---------------------------|:----------------------------------------------------------------|
| `:keyword`                 | one keyword out of `values`                                     |
| `:complex`                 | `keyword(arguments...)` (or one of `values` as keyword)         |
| `:list`                    | comma-separated list of `items`                                 |
| `:list_item`               | a list item of OpenMP type `type` (variable, locator, ...)      |
| `:expression`              | an expression of OpenMP type `type`                             |
| `:variable`                | a variable                                                      |
| `:identifier`              | an identifier                                                   |
| `:directive_name`          | the name of a directive                                         |
| `:directive_specification` | a directive (in metadirectives)                                 |
| `:type_name`               | a type                                                          |
| `:stylized`                | an OpenMP stylized expression or specifier of OpenMP type `type`|
"""
const ARGUMENT_KINDS = (:keyword, :complex, :list, :list_item, :expression, :variable,
                        :identifier, :directive_name, :directive_specification, :type_name,
                        :stylized)

"""
    ArgumentSpec

Syntax of an argument of a directive, clause or complex modifier; also used for the value
of a modifier and for the items of a list.
"""
struct ArgumentSpec
    name::Symbol
    spelling::String
    kind::Symbol
    "OpenMP type, e.g. `\"OpenMP logical\"`, `\"locator list item\"` (`\"\"` if none)"
    type::String
    "keyword of a `:complex`, keyword category of a `:keyword`"
    keyword::Union{Nothing,Symbol}
    "accepted keywords of a `:keyword`; alternative keywords of a `:complex`"
    values::Syms
    "syntax of the items of a `:list`"
    items::Union{Nothing,ArgumentSpec}
    "arguments of a `:complex`"
    arguments::Tuple{Vararg{ArgumentSpec}}
    properties::Syms

    function ArgumentSpec(name, spelling, kind, type, keyword, values, items, arguments, properties)
        kind in ARGUMENT_KINDS || throw(ArgumentError("unknown argument kind `$kind`"))
        return new(name, spelling, kind, type, keyword, values, items, arguments, properties)
    end
end

ArgumentSpec(; name::Symbol, spelling::AbstractString = String(name), kind::Symbol,
             type::AbstractString = "", keyword::Union{Nothing,Symbol} = nothing,
             values = (), items::Union{Nothing,ArgumentSpec} = nothing, arguments = (),
             properties = ()) =
    ArgumentSpec(name, spelling, kind, type, keyword, values, items, arguments, properties)

"""
    ModifierSpec

A modifier of a clause: its syntax (`value`), the arguments it modifies (`modifying`, empty
for all) and its properties.
"""
struct ModifierSpec
    name::Symbol
    spelling::String
    value::ArgumentSpec
    modifying::Syms
    properties::Syms
end

ModifierSpec(; name::Symbol, spelling::AbstractString = String(name), value::ArgumentSpec,
             modifying = (), properties = ()) =
    ModifierSpec(name, spelling, value, modifying, properties)

"Reference to the global modifier `base`, as used by a clause (overriding what differs)."
ModifierSpec(base::ModifierSpec; modifying = base.modifying, properties = base.properties) =
    ModifierSpec(base.name, base.spelling, base.value, modifying, properties)

"""
    MemberSet

A set of clauses of a directive (clause-set) or of modifiers of a clause (modifier-set),
with properties (e.g. `:exclusive`, `:required`) that apply to the set.
"""
struct MemberSet
    name::Symbol
    members::Syms
    properties::Syms
end

MemberSet(; name::Symbol, members, properties = ()) = MemberSet(name, members, properties)

const ClauseSet = MemberSet
const ModifierSet = MemberSet

"""
    ClauseSpec

A clause. `name` is unique; `spelling` is what users write (two clauses may share it, e.g.
`update`, in which case the directive tells them apart).
"""
struct ClauseSpec
    name::Symbol
    spelling::Symbol
    arguments::Tuple{Vararg{ArgumentSpec}}
    modifiers::Tuple{Vararg{ModifierSpec}}
    modifier_sets::Tuple{Vararg{MemberSet}}
    "names of the directives that accept the clause"
    directives::Syms
    properties::Syms
end

ClauseSpec(; name::Symbol, spelling::Symbol = name, arguments = (), modifiers = (),
           modifier_sets = (), directives = (), properties = ()) =
    ClauseSpec(name, spelling, arguments, modifiers, modifier_sets, directives, properties)

"""
    ClauseGroupSpec

A clause-group: its members form a clause-set on the directives that accept the group.
When `member_property` is set, the members are not clauses but the names of the directives
that have this property (e.g. `cancel parallel`), with the group's arguments and modifiers.
"""
struct ClauseGroupSpec
    name::Symbol
    clauses::Syms
    member_property::Union{Nothing,Symbol}
    directives::Syms
    arguments::Tuple{Vararg{ArgumentSpec}}
    modifiers::Tuple{Vararg{ModifierSpec}}
    properties::Syms
end

ClauseGroupSpec(; name::Symbol, clauses = (), member_property::Union{Nothing,Symbol} = nothing,
                directives = (), arguments = (), modifiers = (), properties = ()) =
    ClauseGroupSpec(name, clauses, member_property, directives, arguments, modifiers, properties)

"""
    ModifierGroupSpec

A modifier-group (already expanded into the modifiers of the clauses that accept it).
"""
struct ModifierGroupSpec
    name::Symbol
    modifiers::Syms
    clauses::Syms
    properties::Syms
end

ModifierGroupSpec(; name::Symbol, modifiers = (), clauses = (), properties = ()) =
    ModifierGroupSpec(name, modifiers, clauses, properties)

"""
    DirectiveSpec

A leaf directive. `name` is unique; `spelling` is what users write (e.g. both
`ordered_blockassoc` and `ordered_standalone` are spelled `ordered`). `language` is `:any`
or the base language the directive is restricted to by the specification.
"""
struct DirectiveSpec
    name::Symbol
    spelling::Symbol
    category::Symbol
    association::Symbol
    association_properties::Syms
    language::Symbol
    arguments::Tuple{Vararg{ArgumentSpec}}
    clauses::Syms
    clause_groups::Syms
    clause_sets::Tuple{Vararg{MemberSet}}
    properties::Syms
    separating::Syms
    separated::Syms
    subsidiary::Syms
    enclosing::Syms
end

DirectiveSpec(; name::Symbol, spelling::Symbol = name, category::Symbol, association::Symbol,
              association_properties = (), language::Symbol = :any, arguments = (),
              clauses = (), clause_groups = (), clause_sets = (), properties = (),
              separating = (), separated = (), subsidiary = (), enclosing = ()) =
    DirectiveSpec(name, spelling, category, association, association_properties, language,
                  arguments, clauses, clause_groups, clause_sets, properties, separating,
                  separated, subsidiary, enclosing)

"""
    has_property(spec, property::Symbol)

Whether `spec` (any `*Spec` or `MemberSet`) explicitly has `property`.
"""
has_property(spec, property::Symbol) = property in spec.properties

end # module Schema
