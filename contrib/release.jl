# Release the `main` branch of omp-abi as a new version of OMPABI_jll:
#
#   julia --project=contrib contrib/release.jl [version] [--dry-run]
#
# Builds every platform, publishes the JLL on github.com/Julia-OpenMP/OMPABI_jll.jl,
# registers it in the JuliaOpenMP registry, and updates the recipe and the compat of OMP.jl
# (to be committed). `version` defaults to the next patch version; `--dry-run` only builds
# x86_64-linux-gnu locally. Needs ssh access to omp-abi, and GITHUB_TOKEN to publish.

using LocalRegistry

ENV["JULIA_PKG_USE_CLI_GIT"] = "true"  # the registry is fetched over ssh

const ROOT = dirname(@__DIR__)
const RECIPE = joinpath(@__DIR__, "yggdrasil", "O", "OMPABI", "build_tarballs.jl")
const JLL_DEV = joinpath(first(DEPOT_PATH), "dev", "OMPABI_jll")
const JLL_URL = "https://github.com/Julia-OpenMP/OMPABI_jll.jl.git"
const SOURCE_URL = "git@github.com:Julia-OpenMP/omp-abi.git"

dry = "--dry-run" in ARGS
args = filter(!=("--dry-run"), ARGS)
dry || haskey(ENV, "GITHUB_TOKEN") || error("set GITHUB_TOKEN: BinaryBuilder publishes the tarballs as a GitHub release")

tags = readlines(`git ls-remote --tags --refs $JLL_URL`)
published = maximum(tags; init = v"0") do t
    v = VersionNumber(chopprefix(split(t, "refs/tags/")[2], "OMPABI-v"))
    VersionNumber(v.major, v.minor, v.patch)
end
version = isempty(args) ? VersionNumber(published.major, published.minor, published.patch + 1) : VersionNumber(args[1])

src = joinpath(mktempdir(), "omp-abi")
run(`git clone --quiet --depth 1 --branch main $SOURCE_URL $src`)
commit = readchomp(`git -C $src rev-parse HEAD`)
rm(joinpath(src, ".git"); recursive = true)
src = mv(src, "$src-$commit")  # the JLL README shows this path
recipe = read(RECIPE, String)
if isempty(args) && commit == match(r"commit = \"(\w+)\"", recipe)[1]
    println("omp-abi main ($commit) is already published as OMPABI_jll $published")
    exit(0)
end
println("omp-abi $commit -> OMPABI_jll $version", dry ? " (dry run)" : "")

recipe = replace(recipe, r"version = v\".+?\"" => "version = v\"$version\"",
                 r"commit = \"\w+\"" => "commit = \"$commit\"")
script = dry ? tempname() * ".jl" : RECIPE
write(script, recipe)
rm(JLL_DEV; recursive = true, force = true)  # BinaryBuilder would reuse it
deploy = dry ? ["--deploy=local", "x86_64-linux-gnu"] : ["--deploy=Julia-OpenMP/OMPABI_jll.jl"]
run(addenv(`$(Base.julia_cmd()) --project=$(@__DIR__) $script --verbose $deploy`, "OMP_ABI_SOURCE_DIR" => src))
dry && exit(0)

register(JLL_DEV; registry = "JuliaOpenMP", push = true)

project = joinpath(ROOT, "Project.toml")
compat = "$(version.major).$(version.minor)"
write(project, replace(read(project, String), r"OMPABI_jll = \"[\d.]+\"" => "OMPABI_jll = \"$compat\""))
println("released OMPABI_jll $version: commit $(relpath(RECIPE, ROOT)) and Project.toml")
