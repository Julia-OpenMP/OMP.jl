- Add support for target regions
    - Julia needs to know what target triplet is associated with an OpenMP device number
    - Julia should use GPUCompiler.jl to generate ptx/spirv/etc.
    - OpenMP runtime must expose an ABI to associate it with target regions
        - Likely, only prototype in XKOMP first.

- Add support for more backend (i.e., wiring front-end parser, to a 'lower' method in the backend, that targets omp-abi)

- Make a set of benchmarks, to compare performance with
    - (CPU threading) Default Julia's Threads and Polyester.jl.
    - (GPU kernels) KernelAbstractions.jl, and others (JACC?)
    - (tasking) Default Julia's Task, and Dagger.jl
