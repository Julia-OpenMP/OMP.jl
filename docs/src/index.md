# OMP.jl

OpenMP APIs in Julia, built upon [omp-abi](https://github.com/Julia-OpenMP/omp-abi).

## Introspection

```@docs
OMP.backend
OMP.dialect
```

## Directives

```@docs
@pragma
@omp
OpenMPSyntaxError
OMP.reduction_identity
```

## API routines

```@docs
OMP.has_routine
```
