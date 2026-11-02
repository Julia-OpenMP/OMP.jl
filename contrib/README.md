# Releasing

OMP.jl and `OMPABI_jll`, the prebuilt omp-abi, are distributed through the
[Julia-OpenMP registry](https://github.com/Julia-OpenMP/Registry).

Release the `main` branch of omp-abi as a new `OMPABI_jll` (Linux; `GITHUB_TOKEN` set, ssh access to
omp-abi):
```bash
julia --project=contrib contrib/release.jl            # next patch version; or pass a version
julia --project=contrib contrib/release.jl --dry-run  # only build x86_64-linux-gnu locally
```
Then commit the recipe and `Project.toml`, and register OMP.jl if needed (after bumping its
`version`): `julia --project=contrib -e 'using LocalRegistry; register(pwd(); registry="JuliaOpenMP", repo="https://github.com/Julia-OpenMP/OMP.jl.git", push=true)'`.

`yggdrasil/O/OMPABI/` is laid out for [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil):
submitting it there (omp-abi must be public) would publish `OMPABI_jll` in General.
