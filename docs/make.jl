using Documenter
using OMP

makedocs(
    sitename = "OMP.jl",
    modules = [OMP],
    pages = [
        "Home" => "index.md",
    ],
    # the omp-abi library is not needed to render the docs
    warnonly = [:missing_docs],
)

deploydocs(
    repo = "github.com/Julia-OpenMP/OMP.jl.git",
    push_preview = true,
)
