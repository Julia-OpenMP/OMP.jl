# Generate lib/LibOMPABI.jl from the omp-abi headers (default: those installed by
# `deps/build_local.jl`, which should be a USE_DYNAMIC build, as shipped to users).
#
#   julia --project=res res/wrap.jl [omp-abi include dir]

using Clang.Generators
using Scratch

OMP = Base.UUID("8bfe3126-a470-4c94-995c-71ef2e805e8a")

function main()
    include_dir = isempty(ARGS) ? joinpath(get_scratch!(OMP, "omp-abi"), "include") : abspath(ARGS[1])
    isfile(joinpath(include_dir, "omp-abi", "omp-abi.h")) ||
        error("omp-abi headers not found in $include_dir: run `deps/build_local.jl` first")
    @info "Using omp-abi headers in $include_dir"

    # Clang.jl cannot emit bitfields wider than 32 bits: on a copy of the headers,
    # flatten the `flags` bitfield of omp_abi_kernel_args_t into a uint64_t
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

    headers = [joinpath(bindgen_dir, "omp-abi", "omp-abi.h")]
    ctx = create_context(headers, args, options)
    build!(ctx, BUILDSTAGE_NO_PRINTING)
    for node in ctx.dag.nodes
        map!(api_names, node.exprs, node.exprs)
    end
    build!(ctx, BUILDSTAGE_PRINTING_ONLY)
    return
end

# omp_abi_omp_x -> omp_x; the C symbols of `@ccall`s are QuoteNodes, and keep the prefix
const API_PREFIX = "omp_abi_omp_"
api_names(s::Symbol) = startswith(string(s), API_PREFIX) ? Symbol(chopprefix(string(s), "omp_abi_")) : s
api_names(e::Expr) = Expr(e.head, map(api_names, e.args)...)
api_names(x) = x

isinteractive() || main()
