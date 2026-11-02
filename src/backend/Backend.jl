"""
    Backend

Code generation of the directives, on omp-abi: a method of [`lower`](@ref Frontend.lower)
per leaf directive (`parallel.jl`, ...), and the run-time support of the generated code.
"""
module Backend

using ..OMP: libompabi, LibOMPABI
using ..Frontend: Frontend, Directive, Clause, clause, modifier, argument, list_items, unsupported
import ..Frontend: lower

ref(name::Symbol) = GlobalRef(@__MODULE__, name)

include("runtime.jl")
include("reduction.jl")
include("data.jl")

include("parallel.jl")
include("masked.jl")

end # module Backend
