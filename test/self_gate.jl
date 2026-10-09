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
    (ToleranceSearch, "no quantity is compared with a named tolerance"),
    (KeptBuilders, "no constructor result is kept for its caller with get!"),
    (CallerWhitelist, "no function has a closed list of callers"),
    (Independent, "the package is one module, so no pair of modules is independent"),
    (Rebuilds, "one probe session runs at a time, and this gate arms none"),
    (TwoNames, "one probe session runs at a time, and this gate arms none"),
    (Waits, "one probe session runs at a time, and this gate arms none"),
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

function exhibit_probes()
    watched = (
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

# The default catalog, with a library's public names counted as entry points.
function library_defaults()
    active = Check[]
    for check in ArchCheck.CHECKS
        if check isa DeadCode
            configured = DeadCode(public_is_entry = true)
            push!(active, configured)
        else
            push!(active, check)
        end
    end
    active
end

function exhibit_checks()
    active = library_defaults()
    allowed = (("src/shape/plants.jl", :allowed_call),)
    whitelist = CallerWhitelist((:guarded,), allowed)
    push!(active, whitelist)
    push!(active, SentinelReturns(("src/shape/sentinels.jl",)))
    push!(active, StringPayloads(("src/shape/payloads.jl",)))
    push!(active, UnreadWaits(allowed = (:hold_inputs,)))
    push!(active, ToleranceSearch((:GAP,)))
    push!(active, KeptBuilders(:(Shape.build_shape)))
    push!(active, Independent(:Low, :Shape))
    readers = ((Exhibits.Shape.read_item, Tuple{}),)
    push!(active, ReaderSet(Exhibits.Shape.Item, readers))
    push!(active, ScanSeeds(("src/shape/seeds.jl",)))
    push!(active, OverlappingCalls())
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

function static_checks()
    active = library_defaults()
    waits = UnreadWaits(allowed = (:probe_wait, :wait_synced))
    push!(active, waits)
    push!(active, OverlappingCalls())
    readers = ((ArchCheck.run, Tuple{Any}), (ArchCheck.kinds, Tuple{}))
    push!(active, ReaderSet(Check, readers))
    sentinels = (:Inf, :NaN, :missing)
    push!(active, SentinelReturns(("src",), sentinels))
    push!(active, StringPayloads(("src",)))
    push!(active, ScanSeeds(("src",)))
    push!(active, self_opt())
    Tuple(active)
end

function workload_checks()
    (UnreachedMethods(public_is_entry = true),)
end

function self_checks()
    static = static_checks()
    workload = workload_checks()
    (static..., workload...)
end

function self_gate(; report_path, io)
    checks = self_checks()
    entries = self_entries()
    ArchCheck.gate(ArchCheck;
        report_path = report_path,
        io = io,
        checks = checks,
        entries = entries,
        workload = exhibit_gate_quiet,
    )
end

function exhibit_gate_quiet()
    report = joinpath(mktempdir(), "exhibits.jsonl")
    probes = exhibit_probes()
    run_exhibit_gate(report, devnull, probes)
    nothing
end
