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
```

## API routines

The OpenMP API of `omp.h` (`omp_get_num_threads()`, `omp_lock_t`, ...) is exported by `OMP`,
from omp-abi (see the README).

```@docs
OMP.has_routine
```
