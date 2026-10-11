# One configuration for the gate on the exhibit package, and the gate on this package.
# The test and the coordinator both include this file.

fixture_root = joinpath(@__DIR__, "fixtures")
push!(LOAD_PATH, fixture_root)
try
    using Exhibits
finally
    pop!(LOAD_PATH)
end

# A check with nothing in this package to point at, or one whose run throws on a file this configuration leaves unchanged.
const NOT_APPLICABLE = (
    (Independent, "the package is one module, so no pair of modules is independent"),
    (DeclaredExtensions, "the package is one module, so no module extends another's function"),
)

function exhibit_workload()
    Exhibits.exercise()
    narrow = Int32(1)
    wide = Tuple{Any}
    exact = 1
    seam = Exhibits.Contracts.Seam(exact)
    invoke(Exhibits.Contracts.Seam, wide, narrow)
    Exhibits.run_logic(seam)
    wider = 1 + 1
    Exhibits.Shape.fresh_shelf(wider)
    Exhibits.Shape.touch_key(1)
    invoke(Exhibits.Low.Brick, wide, narrow)
    invoke(Exhibits.Shape.Tag, wide, narrow)
    invoke(Exhibits.Shape.PlainItem, wide, narrow)
    invoke(Exhibits.Shape.Loose, wide, narrow)
    pair = Tuple{Any, Any}
    invoke(Exhibits.Shape.Piece, pair, narrow, narrow)
    span = invoke(Exhibits.Shape.Span, pair, narrow, narrow)
    invoke(Exhibits.Shape.Shelf, wide, span)
    nothing
end

function exhibit_entries()
    ((Exhibits.exercise, Tuple{}),)
end

# `exercise` is the call within which the probed calls' repeats are judged.
function exhibit_probes()
    watched = (
        Exhibits.Shape.exercise,
        Exhibits.Shape.make_span,
        Exhibits.Shape.left_name,
        Exhibits.Shape.right_name,
        Exhibits.Shape.produced,
        Exhibits.Shape.looked,
        Exhibits.Shape.drops,
        Exhibits.Shape.hold_inputs,
    )
    Probes(functions = watched, slow_s = 0.0)
end

function exhibit_derived()
    declared = Derived(
        Exhibits.Shape.make_span;
        key = Exhibits.Shape.span_key,
        cache = :held,
        readers = (Exhibits.Shape.read_span,),
    )
    plain = Derived(Exhibits.Shape.plain_label)
    (declared, plain)
end

# The exhibits keep their modules apart, so the module rules run strict there.
const STRICT_RULES = (ModuleBackEdges, ModuleCycles, OwnerUniqueness, ModulePiracy)

function exhibit_checks()
    active = Check[]
    for check in ArchCheck.CHECKS
        is_strict_rule = any(rule -> check isa rule, STRICT_RULES)
        is_strict_rule || push!(active, check)
    end
    for rule in STRICT_RULES
        push!(active, rule(strict = true))
    end
    allowed = (("src/shape/plants.jl", :allowed_call),)
    whitelist = CallerWhitelist((:guarded,), allowed)
    push!(active, whitelist)
    push!(active, UnreadWaits(allowed = (:hold_inputs,)))
    push!(active, Independent(:Low, :Shape))
    push!(active, DeclaredExtensions())
    readers = ((Exhibits.Shape.read_item, Tuple{}),)
    push!(active, ReaderSet(Exhibits.Shape.Item, readers))
    runtime = OptEntry(Exhibits.Shape.runtime_plant, Tuple{Function,Int})
    boxed = OptEntry(Exhibits.Shape.boxed_total, Tuple{Int})
    corpus = OptEntry[runtime, boxed]
    push!(active, OptAnalysis(corpus))
    push!(active, UnreachedMethods())
    push!(active, Rebuilds())
    push!(active, TwoNames())
    push!(active, Waits())
    Tuple(active)
end

function run_exhibit_gate(report_path, io, probes)
    checks = exhibit_checks()
    entries = exhibit_entries()
    derived = exhibit_derived()
    scripts = joinpath(pkgdir(Exhibits), "scripts")
    caught = try
        ArchCheck.gate(Exhibits;
            report_path = report_path,
            io = io,
            checks = checks,
            entries = entries,
            probes = probes,
            derived = derived,
            workload = exhibit_workload,
            entry_dirs = [scripts],
        )
        nothing
    catch err
        err
    end
    isnothing(caught) && return nothing
    caught isa ErrorException || throw(caught)
    occursin("architecture gate RED", caught.msg) || throw(caught)
    nothing
end

function exhibit_gate(; report_path, io)
    probes = exhibit_probes()
    run_exhibit_gate(report_path, io, probes)
end

# The public calls a caller makes, with any keywords.
function self_entries()
    gate_call = (Core.kwcall, Tuple{NamedTuple, typeof(ArchCheck.gate), Module})
    context_call = (Core.kwcall, Tuple{NamedTuple, Type{Context}, Module})
    (gate_call, context_call)
end

# The index build and one check run, entered through the public calls a caller makes.
function self_opt()
    index_entry = OptEntry(Context, Tuple{Module})
    check_types = Tuple{Corpus, Context{Tuple{}}}
    check_entry = OptEntry(ArchCheck.run, check_types)
    entries = OptEntry[index_entry, check_entry]
    OptAnalysis(entries)
end

# Each file parses once, through the one cache.
function parse_sites()
    callees = (:parseall, :parse_file)
    allowed = (("src/syntax.jl", :parse_file), ("src/syntax.jl", :parsed_tree))
    CallerWhitelist(callees, allowed)
end

# The sites that run inference, each asking a question the others do not answer.
function inference_sites()
    callees = (:typeinf, :typeinf_frame, :inference_frame, :code_typed, :code_typed_by_type, :return_types, :report_opt)
    allowed = (
        ("src/methodgraph.jl", :inference_frame),
        ("src/methodgraph.jl", :expand_instance!),
        ("src/methodgraph.jl", :merge_declared_calls!),
        ("src/julia_internals.jl", :inferred_return_types),
        ("src/checks_opt.jl", :analyze_entries),
    )
    CallerWhitelist(callees, allowed)
end

# Julia internals with no public form in 1.13.1, each read only in the boundary file, whose every operation states
# its contract.
function internal_sites()
    callees = (:visit, :kwarg_decl, :bodyfunction, :delete_method, :method_argnames, :fixup_stdlib_path, :moduleloc,
               :meta, :Binding, :datatype_haspadding, :loaded_modules, :env_project_file, :parsed_toml, :PkgId,
               :sync_varname, :ccall, :_methods_by_ftype, :getdebugidx, :buildLineInfoNode, :maybe_root_module,
               :unwrap_unionall, :rewrap_unionall, :has_free_typevars, :uniontypes, :isType, :NativeInterpreter,
               :InferenceParams, :infer_return_type, :return_types, :generating_output, :specializations,
               :method_instance, :hasgenerator, :isvarargtype, :get_world_counter, :decode_effects,
               :ForwardToBackedgeIterator, :argextype, :widenconst, :pkgorigins, :parse_cache_header, :_crc32c)
    boundary = ("src/julia_internals.jl",)
    CallerWhitelist(callees, (), boundary)
end

# The internals ArchCheck reads on purpose: Base's reflection, loading and parser, Core's method types, inference and
# its inlining record, recorded docstrings, and the exhibit modules whose planted internals the gate names.
const READ_INTERNALS = (Base, Core, Base.Compiler, Base.IRShow, Base.Docs, Exhibits, Exhibits.Low, Exhibits.Shape,
                        Exhibits.Contracts)

function static_checks()
    active = Check[]
    for check in ArchCheck.CHECKS
        check isa ReachesInternal || push!(active, check)
    end
    push!(active, ReachesInternal(allowed = READ_INTERNALS))
    push!(active, parse_sites())
    push!(active, inference_sites())
    push!(active, internal_sites())
    waits = UnreadWaits(allowed = (:probe_wait, :wait_synced))
    push!(active, waits)
    push!(active, InferredCalls())
    readers = ((ArchCheck.run, Tuple{Any}), (ArchCheck.kinds, Tuple{}))
    push!(active, ReaderSet(Check, readers))
    push!(active, self_opt())
    Tuple(active)
end

function workload_checks()
    (UnreachedMethods(), Rebuilds(), TwoNames(), Waits())
end

# The derivations several readers share, each evaluated once per piece of code within one gate run, the call that
# judges their repeats. Named by path: the tests reach only public names.
function self_probes()
    producers = (:gate, :parse_file, :scan_tree, :method_bodies, :load_events)
    Probes(functions = producers, slow_s = 0.0)
end

function self_checks()
    static = static_checks()
    workload = workload_checks()
    (static..., workload...)
end

# The tests are an entry dir, so they too may reach only exported and public names.
function self_gate(; report_path, io)
    checks = self_checks()
    entries = self_entries()
    probes = self_probes()
    tests = joinpath(pkgdir(ArchCheck), "test")
    ArchCheck.gate(ArchCheck;
        report_path = report_path,
        io = io,
        checks = checks,
        entries = entries,
        probes = probes,
        workload = exhibit_gate_quiet,
        entry_dirs = [tests],
    )
end

function exhibit_gate_quiet()
    report = joinpath(mktempdir(), "exhibits.jsonl")
    probes = exhibit_probes()
    run_exhibit_gate(report, devnull, probes)
    nothing
end
