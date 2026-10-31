using Test
using OMP

const FE = OMP.Frontend
const Spec = FE.Spec

# parse the source of a `@pragma`/`@omp` call, e.g. ir(raw"""@pragma "omp barrier" """)
function ir(src::AbstractString)
    ex = Meta.parse(src)
    Meta.isexpr(ex, :macrocall) || error("not a macro call: $src")
    prefix = ex.args[1] === Symbol("@pragma")
    return FE.parse_macro(Tuple(ex.args[3:end]), LineNumberNode(1, :test); prefix)
end

# directive string `s`, with associated code `body` (source text) if any
str(s::AbstractString, body::AbstractString = "") = ir("@pragma \"\"\"omp $s\"\"\" $body")

# the error message of `f(args...)`
function error_of(f, args...)
    try
        f(args...)
    catch e
        e isa OpenMPSyntaxError && return e.msg
        rethrow()
    end
    return "no error"
end
str_error(args...) = error_of(str, args...)
ir_error(src) = error_of(ir, src)

const LOOP = "for i in 1:n end"
const BLOCK = "begin end"

@testset "Spec (generated)" begin
    @test !isempty(Spec.DIRECTIVES) && !isempty(Spec.CLAUSES) && !isempty(Spec.MODIFIERS)
    @test Spec.OPENMP_VERSION isa String
    for c in Spec.CLAUSES, d in c.directives
        @test haskey(FE.DIRECTIVES, d)
    end
    for d in Spec.DIRECTIVES
        @test all(c -> haskey(FE.CLAUSES, c), d.clauses)
        @test all(g -> haskey(FE.CLAUSE_GROUPS, g), d.clause_groups)
    end
    for c in Spec.COMPOUND_DIRECTIVES
        @test all(in(FE.LEAF_SPELLINGS), c)
    end
    # constants are named after the entities, quoted when they are Julia keywords
    @test Spec.Clauses.depend.name === :depend
    @test Spec.Clauses.var"if".spelling === :if
    @test Spec.Directives.var"for".spelling === :for
    @test Spec.Clauses.update_depend_objects.spelling === :update
end

@testset "directive strings: names" begin
    @test str("barrier").name === :barrier
    @test str("target data map(to: a)", BLOCK).name === :target_data
    @test str("target_data map(to: a)", BLOCK).name === :target_data
    @test str("target enter data map(to: a)").name === :target_enter_data
    @test str("cancellation point parallel").name === :cancellation_point
    @test [l.spelling for l in str("parallel for", LOOP).leafs] == [:parallel, :for]
    d = str("target teams distribute parallel for simd", LOOP)
    @test [l.spelling for l in d.leafs] == [:target, :teams, :distribute, :parallel, :for, :simd]
    @test FE.is_compound(d)
    @test only(str("for", LOOP).leafs).spelling === :for
    @test only(ir("@omp \"for\" $LOOP").leafs).spelling === :for
    # all compound directives, written with spaces; `_` does not join compound directives
    ctx = FE.Context(nothing, FE.DirectiveSpec[])
    for c in FE.COMPOUND_DIRECTIVES
        @test FE.lookup_directive(ctx, collect(c)) == (Symbol(join(c, "_")), collect(c))
        @test FE.lookup_directive(ctx, [Symbol(join(c, "_"))]) === nothing
    end
    # several directives spelled `ordered`
    @test only(str("ordered threads", BLOCK).leafs).name === :ordered_blockassoc
    @test only(str("ordered doacross(source: omp_cur_iteration)").leafs).name === :ordered_standalone
    # directive arguments
    @test FE.argument(str("critical(lock)", BLOCK), :name) === :lock
    @test FE.argument(str("critical (lock)", BLOCK), :name) === :lock
    @test FE.argument(str("critical", BLOCK), :name) === nothing
    @test FE.argument(str("flush(a, b)"), :list) == [:a, :b]
    d = str("declare_variant(f: g) match(construct={parallel})", "function g() end")
    @test FE.argument(d, :base_name) === :f && FE.argument(d, :variant_name) === :g
    @test FE.argument(str("declare reduction(merge : T, U : omp_out = omp_in) combiner(omp_out = omp_in)"),
                      :reduction_specifier) isa Expr

    @test occursin("unknown directive `paralel`", str_error("paralel", BLOCK))
    @test occursin("not available in Julia", str_error("workshare", BLOCK))
    @test occursin("written with spaces: `@pragma \"omp parallel for\"`", str_error("parallel_for", LOOP))
    @test occursin("`do` is a directive, specific to the fortran base language", str_error("parallel do", LOOP))
end

@testset "directive strings: associated code" begin
    @test Meta.isexpr(str("parallel", "begin x end").body, :block)
    @test Meta.isexpr(str("atomic update", "x += 1").body, :+=)
    @test str("barrier").body === nothing
    @test Meta.isexpr(str("section", BLOCK).body, :block)
    @test str("scan inclusive(x)").body === nothing
    @test Meta.isexpr(str("parallel for", "begin for i in 1:n end end").body, :block)
    @test Meta.isexpr(str("declare_simd uniform(a)", "f(a) = a").body, :(=))
    @test occursin("associated code", str_error("parallel"))
    @test occursin("takes no associated code, got `f()`", str_error("barrier", "f()"))
    @test occursin("`for` loop, got `begin ... end`", str_error("parallel for", "begin x end"))
    @test occursin("function definition", str_error("declare_simd uniform(a)", BLOCK))
    @test occursin("clauses go inside the string", ir_error("@pragma \"omp parallel\" num_threads(4) begin end"))
end

@testset "directive strings: clauses" begin
    d = str("task depend(in: x) depend(inout: y[1:n], z) firstprivate(a, b) priority(3)", BLOCK)
    @test [c.spec.name for c in d.clauses] == [:depend, :depend, :firstprivate, :priority]
    deps = FE.clauses(d, :depend)
    @test FE.modifier(deps[1], :task_dependence_type) === :in
    @test FE.argument(deps[1], :depend_list) == [:x]
    @test FE.modifier(deps[2], :task_dependence_type) === :inout
    @test FE.argument(deps[2], :depend_list) == [:(y[1:n]), :z]
    @test FE.argument(FE.clause(d, :firstprivate), :list) == [:a, :b]
    @test FE.argument(FE.clause(d, :priority), :priority_value) == 3
    # clauses may be separated by commas; variables may have `_`
    d = str("parallel private(my_var), shared(_x, y_1), num_threads(n_threads)", BLOCK)
    @test FE.argument(FE.clause(d, :private), :list) == [:my_var]
    @test FE.argument(FE.clause(d, :shared), :list) == [:_x, :y_1]

    d = str("parallel for schedule(monotonic: dynamic, 4) nowait", LOOP)
    s = FE.clause(d, :schedule)
    @test FE.modifier(s, :ordering_modifier) === :monotonic
    @test FE.argument(s, :kind) === :dynamic && FE.argument(s, :chunk_size) == 4
    @test FE.argument(FE.clause(str("for simd schedule(static)", LOOP), :schedule), :chunk_size) === nothing
    @test FE.clause(d, :nowait).arguments == []

    # Julia keywords as clause names, C-style
    @test FE.argument(FE.clause(str("parallel if(n > 10)", BLOCK), :if), :if_expression) == :(n > 10)
    @test FE.argument(FE.clause(str("declare_target local(x)"), :local), :list) == [:x]
    @test FE.clause(str("cancel parallel"), :parallel).spec.name === :cancel_directive_name_parallel
    @test FE.clause(str("cancel for if(c)"), :if) !== nothing
    @test FE.clause(str("atomic update", "x += 1"), :update).spec.name === :update
    # expressions: ternaries, ranges, calls, strings
    @test FE.argument(FE.clause(str("parallel if(c ? a : b)", BLOCK), :if), :if_expression) == :(c ? a : b)
    @test FE.argument(FE.clause(str("target map(to: x[1:n, :])", BLOCK), :map), :locator_list) == [:(x[1:n, :])]
    @test FE.argument(FE.clause(str("error message(\"a: b, c\")"), :message), :msg_string) == "a: b, c"
    @test FE.argument(FE.clause(str("parallel num_threads(f(a, b))", BLOCK), :num_threads), :nthreads_list) == [:(f(a, b))]

    @test occursin("unknown clause `nowaitt`", str_error("single nowaitt", BLOCK))
    @test occursin("not allowed on directive `parallel`", str_error("parallel nowait", BLOCK))
    @test occursin("at most once", str_error("parallel num_threads(4) num_threads(2)", BLOCK))
    @test occursin("invalid argument `default-behavior` of clause `default`: got `sharedd`", str_error("parallel default(sharedd)", BLOCK))
    @test occursin("must be positive", str_error("parallel num_threads(0)", BLOCK))
    @test occursin("must be positive", str_error("simd safelen(-1)", LOOP))
    @test occursin("of type integer", str_error("parallel num_threads(\"4\")", BLOCK))
    @test occursin("must be a variable", str_error("parallel private(a[1])", BLOCK))
    @test occursin("too many arguments", str_error("parallel proc_bind(close, spread)", BLOCK))
    @test occursin("takes no arguments", str_error("barrier(x)"))
end

@testset "directive strings: modifiers" begin
    m = FE.clause(str("target map(always, close, tofrom: a)", BLOCK), :map)
    @test [x.spec.name for x in m.modifiers] == [:always_modifier, :close_modifier, :map_type]
    m = FE.clause(str("target map(iterator(i = 1:n), to: a[i])", BLOCK), :map)
    it = FE.modifier(m, :iterator)
    @test it isa FE.ComplexValue && it.keyword === :iterator
    @test FE.argument(it, :iterator_specifier_list) == [:(i = 1:n)]
    @test FE.modifier(FE.clause(str("target_enter_data map(alloc: a)"), :map), :map_type) === :storage
    l = FE.clause(str("simd linear(x, y: step(2))", LOOP), :linear)
    @test FE.argument(l, :list) == [:x, :y] && FE.modifier(l, :step_complex_modifier).keyword === :step
    @test FE.modifier(FE.clause(str("simd linear(x: 2)", LOOP), :linear), :step_simple_modifier) == 2
    @test FE.modifier(FE.clause(str("simd aligned(a: 64)", LOOP), :aligned), :alignment) == 64
    @test FE.modifier(FE.clause(str("teams num_teams(4: 8)", BLOCK), :num_teams), :lower_bound) == 4
    @test FE.argument(FE.clause(str("ordered doacross(sink: i - 1, j)"), :doacross), :iteration_specifier) == :((i - 1, j))

    # reductions, C-style
    for op in (:+, :*, :-, :max, :&&, :||, :|, :&, :⊻)
        r = FE.clause(str("parallel reduction($op: s, t)", BLOCK), :reduction)
        @test FE.modifier(r, :reduction_identifier) === op && FE.argument(r, :list) == [:s, :t]
    end
    r = FE.clause(str("parallel reduction(task, max: s)", BLOCK), :reduction)
    @test FE.modifier(r, :reduction_identifier) === :max && FE.modifier(r, :task_modifier) === :task

    # directive-name modifiers name a constituent directive
    d = str("target parallel if(target: c) if(parallel: n > 10)", BLOCK)
    @test [FE.modifier(c, :directive_name_modifier) for c in d.clauses] == [:target, :parallel]
    @test FE.argument(d.clauses[2], :if_expression) == :(n > 10)
    @test occursin("must name a constituent", str_error("target parallel if(teams: c)", BLOCK))

    # post-modified clauses
    d = str("target defaultmap(tofrom: scalar)", BLOCK)
    @test FE.argument(d.clauses[1], :default_behavior) === :tofrom
    @test FE.modifier(d.clauses[1], :variable_category) === :scalar
    @test FE.clause(str("parallel default(shared)", BLOCK), :default) !== nothing

    @test occursin("invalid modifier `inn`", str_error("task depend(inn: x)", BLOCK))
    @test occursin("at most once", str_error("target map(always, always, to: a)", BLOCK))
    @test occursin("requires the modifier", str_error("ordered doacross(i - 1)"))
end

@testset "directive strings: clause sets and groups" begin
    @test occursin("mutually exclusive", str_error("atomic read write", "v = x"))
    @test occursin("mutually exclusive", str_error("single copyprivate(x) nowait", BLOCK))
    @test occursin("mutually exclusive", str_error("unroll partial(4) full", LOOP))
    @test occursin("requires one of the clauses", str_error("requires"))
    @test occursin("requires one of the clauses", str_error("target update"))
    @test occursin("requires clause `sizes`", str_error("tile", LOOP))
    @test FE.clause(str("requires unified_shared_memory"), :unified_shared_memory) !== nothing
    @test FE.clause(str("atomic update seq_cst", "x += 1"), :seq_cst) !== nothing
end

@testset "directive strings: metadirectives" begin
    d = str("metadirective when(device={kind(gpu)}: teams loop) otherwise(parallel for)")
    w = FE.clause(d, :when)
    @test FE.argument(w, :directive_variant).name === :teams_loop
    @test FE.modifier(w, :context_selector) == :(device = {kind(gpu)})
    @test [l.spelling for l in FE.argument(FE.clause(d, :otherwise), :directive_variant).leafs] == [:parallel, :for]
    v = FE.argument(FE.clause(str("metadirective otherwise(parallel num_threads(4))"), :otherwise), :directive_variant)
    @test v.name === :parallel && FE.clause(v, :num_threads) !== nothing
    @test FE.argument(FE.clause(str("metadirective otherwise(nothing)"), :otherwise), :directive_variant).name === :nothing
end

@testset "directive strings: errors point into the string" begin
    msg = str_error("parallel nowaitt", BLOCK)
    @test endswith(msg, "\"omp parallel nowaitt\"\n                  ^^^^^^^")
    @test occursin("unclosed `(`", str_error("parallel num_threads(4", BLOCK))
    @test occursin("unbalanced `]`", str_error("parallel num_threads(4])", BLOCK))
    @test occursin("`4 +` is not a valid Julia expression", str_error("parallel num_threads(4 +)", BLOCK))
    @test occursin("unexpected `#`", str_error("parallel #", BLOCK))
    @test occursin("empty argument", str_error("parallel private(a,)", BLOCK))
    @test occursin("starts with `omp`", ir_error("@pragma \"parallel\" begin end"))
    @test occursin("interpolation", ir_error("@pragma \"omp parallel if(\$c)\" begin end"))
end

@testset "bare form" begin
    # valid Julia syntax: accepted
    d = ir("@pragma omp task depend(in: x) firstprivate(a) begin end")
    @test d.name === :task && FE.modifier(FE.clause(d, :depend), :task_dependence_type) === :in
    @test ir("@pragma omp target data map(to: a) begin end").name === :target_data
    @test ir("@omp barrier").name === :barrier
    d = ir("@pragma omp target parallel num_threads(4) begin end")
    @test [l.spelling for l in d.leafs] == [:target, :parallel]
    r = FE.clause(ir("@pragma omp parallel reduction((+) : s) begin end"), :reduction)
    @test FE.modifier(r, :reduction_identifier) === :+
    r = FE.clause(ir("@pragma omp parallel reduction(+, s) begin end"), :reduction)
    @test FE.modifier(r, :reduction_identifier) === :+

    # Julia keywords that Julia parses: reported with the equivalent directive string
    @test occursin("`@pragma \"omp parallel for\"`", ir_error("@pragma omp parallel :for begin end"))
    @test occursin("`@pragma \"omp parallel for\"`", ir_error("@pragma omp parallel var\"for\" begin end"))
    @test occursin("`@pragma \"omp parallel if(c)\"`", ir_error("@pragma omp parallel :if(c) begin end"))
    @test occursin("`@pragma \"omp declare_target local(x)\"`", ir_error("@pragma omp declare_target local(x)"))
    @test occursin("`@pragma \"omp for\"`", ir_error("@pragma omp for i in 1:n end"))
    @test occursin("`@pragma \"omp begin\"`", ir_error("@pragma omp begin x end"))
    @test occursin("parsed by Julia as the directive `parallel` followed by a `for` loop",
                   ir_error("@pragma omp parallel for i in 1:n end"))
    @test occursin("written with spaces", ir_error("@pragma omp parallel_for for i in 1:n end"))
    # a loop in a block is not ambiguous; nor is a loop after a loop-associated directive
    @test ir("@pragma omp parallel begin for i in 1:n end end").name === :parallel
    @test ir("@pragma omp simd for i in 1:n end").name === :simd
end

@testset "printing" begin
    @test sprint(show, str("task depend(in: x) firstprivate(a)", BLOCK)) ==
          "Directive(omp task depend(in : x) firstprivate(a) <body>)"
    @test sprint(show, str("simd linear(x: 2)", LOOP)) == "Directive(omp simd linear(x : 2) <body>)"
end

@testset "macros" begin
    d = @macroexpand OMP.Frontend.@pragma_ir "omp task depend(in: x)" begin end
    @test d isa FE.Directive && d.name === :task && d.source isa LineNumberNode
    d = @macroexpand OMP.Frontend.@pragma_ir omp task depend(in: x) begin end
    @test d isa FE.Directive && d.name === :task
    # valid directives that OMP.jl cannot generate code for yet
    @test_throws FE.UnsupportedDirectiveError macroexpand(@__MODULE__, :(@pragma "omp barrier"))
    @test_throws FE.UnsupportedDirectiveError macroexpand(@__MODULE__, :(@omp "barrier"))
    @test_throws FE.UnsupportedDirectiveError macroexpand(@__MODULE__, :(@pragma omp barrier))
    @test_throws OpenMPSyntaxError macroexpand(@__MODULE__, :(@omp "barier"))
    @test_throws OpenMPSyntaxError macroexpand(@__MODULE__, :(@pragma "acc parallel" begin end))
    @test_throws OpenMPSyntaxError macroexpand(@__MODULE__, :(@pragma acc parallel begin end))
end
