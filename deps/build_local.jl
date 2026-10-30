# Build a local version of omp-abi, and tell OMP.jl to use it.
#
#   julia --project=deps deps/build_local.jl [build_dir]
#
# Environment variables:
#   OMP_ABI_SOURCE_DIR : local omp-abi checkout to build (default: clone OMP_ABI_URL)
#   OMP_ABI_BRANCH     : branch to clone (default: main)
#   OMP_ABI_BACKEND    : dynamic (default), llvm, gcc, xkomp or mpc
#   CMAKE_BUILD_TYPE   : Release (default), Debug, ...

using Pkg
Pkg.activate(@__DIR__)
Pkg.instantiate()

using Scratch, Preferences, CMake_jll, LibGit2

const OMP_ABI_URL = "https://github.com/Julia-OpenMP/omp-abi.git"
const BACKENDS = ("dynamic", "llvm", "gcc", "xkomp", "mpc")

branch     = get(ENV, "OMP_ABI_BRANCH", "main")
backend    = get(ENV, "OMP_ABI_BACKEND", "dynamic")
build_type = get(ENV, "CMAKE_BUILD_TYPE", "Release")
backend in BACKENDS || error("Unknown omp-abi backend '$backend' (expected one of $(join(BACKENDS, ", ")))")

OMP = Base.UUID("8bfe3126-a470-4c94-995c-71ef2e805e8a")

# get scratch directories
install_dir = get_scratch!(OMP, "omp-abi")
rm(install_dir; recursive=true, force=true)

# get source directory
source_dir = if haskey(ENV, "OMP_ABI_SOURCE_DIR")
    abspath(ENV["OMP_ABI_SOURCE_DIR"])
else
    dir = get_scratch!(OMP, "omp-abi_src")
    rm(dir; recursive=true, force=true)
    @info "Cloning omp-abi" OMP_ABI_URL branch
    LibGit2.clone(OMP_ABI_URL, dir; branch)
    dir
end
isfile(joinpath(source_dir, "CMakeLists.txt")) || error("$source_dir is not an omp-abi source tree")

# get build directory
build_dir = isempty(ARGS) ? mktempdir() : ARGS[1]
mkpath(build_dir)

# build and install
config_opts = String[
    "-DCMAKE_BUILD_TYPE=$build_type",
    "-DCMAKE_INSTALL_PREFIX=$install_dir",
    ["-DUSE_$(uppercase(b))=$(b == backend ? "ON" : "OFF")" for b in BACKENDS]...,
]
@info "Building" source_dir install_dir build_dir backend
cmake() do cmake_path
    run(`$cmake_path $config_opts -B$build_dir -S$source_dir`)
    # only the library: the omp-abi tests need an OpenMP compiler
    run(`$cmake_path --build $build_dir --target omp-abi -j`)
    run(`$cmake_path --install $build_dir`)
end

lib_path = joinpath(install_dir, "lib", "libomp-abi.so")
isfile(lib_path) || error("Could not find library $lib_path in install directory")

# tell OMP.jl to load our library
set_preferences!(
    joinpath(dirname(@__DIR__), "LocalPreferences.toml"),
    "OMP",
    "libompabi" => lib_path;
    force=true,
)
@info "OMP.jl will now use $lib_path (restart Julia to pick it up)"
