# BinaryBuilder recipe of OMPABI_jll, laid out as in https://github.com/JuliaPackaging/Yggdrasil
# so that it can be submitted there unchanged. Released by contrib/release.jl.

using BinaryBuilder

name = "OMPABI"
version = v"0.2.0"

commit = "fbc52581e9eddd28f414d36c07b79dc416908932"
# contrib/release.jl passes a clone of `commit` (omp-abi is private)
sources = haskey(ENV, "OMP_ABI_SOURCE_DIR") ?
    [DirectorySource(ENV["OMP_ABI_SOURCE_DIR"]; target = "omp-abi")] :
    [GitSource("https://github.com/Julia-OpenMP/omp-abi.git", commit)]

# USE_DYNAMIC: every backend is built in, and the OpenMP runtime is selected at
# run time, so a single artifact serves libgomp, libomp, XKOMP and MPC.
script = raw"""
cd ${WORKSPACE}/srcdir/omp-abi
cmake -B build \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_DYNAMIC=ON
# only the library: the omp-abi tests need an OpenMP compiler and runtime
cmake --build build --target omp-abi --parallel ${nproc}
cmake --install build
install_license LICENSE
"""

# omp-abi relies on dlopen/dlsym and a GNU ld version script
platforms = supported_platforms(; exclude=p -> !Sys.islinux(p))

products = [
    LibraryProduct("libomp-abi", :libompabi),
]

# the OpenMP runtime is dlopen'ed at run time, not linked
dependencies = [
    # libgcc_s and libstdc++
    Dependency("CompilerSupportLibraries_jll"),
]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.13", preferred_gcc_version=v"10")
