# OMP.jl - OpenMP APIs in Julia

The OMP.jl package provides OpenMP APIs in Julia.
It builds upon [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl) and [omp-abi](https://github.com/Julia-OpenMP/omp-abi).

[![omp.jl software stack](docs/figures/omp-jl.png)](docs/figures/omp-jl.pdf)

# Installation
OMP.jl and its binary dependency, `OMPABI_jll`, are distributed through the
[Julia-OpenMP registry](https://github.com/Julia-OpenMP/Registry):
```julia
pkg> registry add https://github.com/Julia-OpenMP/Registry
pkg> add OMP
```
No compiler or system OpenMP runtime is needed: omp-abi comes prebuilt as an
artifact (Linux only for now), and the OpenMP runtime is the `libgomp` shipped with Julia.

## Selecting the OpenMP runtime
omp-abi is built with all its backends (`-DUSE_DYNAMIC=ON`), and forwards to the
OpenMP runtime selected at run time: by default the `libgomp` shipped with Julia.
See [omp-abi](https://github.com/Julia-OpenMP/omp-abi) for how to select another runtime.

# Development

## Layout
| path        | content                                                                    |
|-------------|----------------------------------------------------------------------------|
| `src/`      | the `OMP` module                                                           |
| `lib/`      | C bindings of omp-abi (`OMP.LibOMPABI`), generated: do not edit            |
| `res/`      | binding generator (`res/wrap.jl`, Clang.jl)                                |
| `deps/`     | `build_local.jl`: build omp-abi from source and select it as a preference  |
| `test/`, `docs/`, `examples/` | each its own project, in the package [workspace](https://pkgdocs.julialang.org/v1/toml-files/#Workspaces) |
| `contrib/`   | release tooling: BinaryBuilder recipe of `OMPABI_jll`, registry ([how to release](contrib/README.md)) |

## Working on omp-abi
By default OMP.jl uses the omp-abi of `OMPABI_jll`.
```bash
# build a local omp-abi checkout instead, and use it from OMP.jl (`libompabi` in LocalPreferences.toml)
OMP_ABI_SOURCE_DIR=../omp-abi julia --project=deps deps/build_local.jl

# regenerate lib/LibOMPABI.jl after changing the omp-abi headers
julia --project=res res/wrap.jl
```

## Testing
```bash
julia --project -e 'using Pkg; Pkg.test()'
julia --project=examples examples/hello.jl
```

# Support
If you are look for any support, feel free to contact us directly.    
Romain Pereira (rpereira@anl.gov)
