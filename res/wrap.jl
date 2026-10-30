# Generate lib/LibOMPABI.jl, the bindings of the omp-abi C API.
#
#   julia --project=res res/wrap.jl [omp-abi include dir]
#
# The include dir defaults to the omp-abi installed by `deps/build_local.jl`.
# Bindings should be generated from a USE_DYNAMIC build, the configuration
# shipped to users.

using Clang.Generators
using Scratch

OMP = Base.UUID("8bfe3126-a470-4c94-995c-71ef2e805e8a")

function main()
    include_dir = isempty(ARGS) ? joinpath(get_scratch!(OMP, "omp-abi"), "include") : abspath(ARGS[1])
    isfile(joinpath(include_dir, "omp-abi", "omp-abi.h")) ||
        error("omp-abi headers not found in $include_dir: run `deps/build_local.jl` first")
    @info "Using omp-abi headers in $include_dir"

    # Clang.jl cannot emit bitfields wider than 32 bits: on a private copy of the
    # headers, flatten the `flags` bitfield of omp_abi_kernel_args_t into a plain
    # uint64_t (same layout; see the OMP_ABI_KERNEL_ARGS_FLAG_* masks in prologue.jl)
    bindgen_dir = mktempdir()
    cp(joinpath(include_dir, "omp-abi"), joinpath(bindgen_dir, "omp-abi"))
    target_h = joinpath(bindgen_dir, "omp-abi", "target.h")
    src = read(target_h, String)
    fixed = replace(src, r"struct\s*\{[^{}]*?uint64_t\s+unused\s*:\s*57\s*;\s*\}\s*flags\s*;" => "uint64_t flags;")
    fixed != src || error("Could not patch the omp_abi_kernel_args_t flags bitfield in $target_h -- has omp-abi changed?")
    write(target_h, fixed)

    options = load_options(joinpath(@__DIR__, "generator.toml"))
    options["general"]["output_file_path"] = joinpath(@__DIR__, "..", "lib", "LibOMPABI.jl")
    options["general"]["prologue_file_path"] = joinpath(@__DIR__, "prologue.jl")

    args = get_default_args()
    push!(args, "-I$bindgen_dir")
    # Generate the OpenMP spec types from omp-abi's own definitions rather than from
    # whichever vendor <omp.h> happens to be on the include path
    push!(args, "-DOMP_ABI_NO_SYSTEM_OMP_H")

    headers = [joinpath(bindgen_dir, "omp-abi", "omp-abi.h")]
    ctx = create_context(headers, args, options)
    build!(ctx)
    return
end

isinteractive() || main()
