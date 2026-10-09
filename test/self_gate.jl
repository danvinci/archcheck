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
    (ArchCheck.ToleranceSearch, "no quantity is compared with a named tolerance"),
    (ArchCheck.KeptBuilders, "no constructor result is kept for its caller with get!"),
    (ArchCheck.CallerWhitelist, "no function has a closed list of callers"),
    (ArchCheck.Independent, "the package is one module, so no pair of modules is independent"),
    (ArchCheck.OptAnalysis, "with JET loaded the report is runtime dispatch in files this configuration leaves unchanged"),
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
    )
    ArchCheck.Probes(functions = watched, slow_s = 0.0)
end

function exhibit_derived()
    declared = ArchCheck.Derived(
        Exhibits.Shape.make_span;
        key = Exhibits.Shape.span_key,
        cache = :held,
        readers = (Exhibits.Shape.read_span,),
    )
    (declared,)
end

function exhibit_checks()
    active = ArchCheck.Check[]
    for check in ArchCheck.CHECKS
        if check isa ArchCheck.DeadCode
            configured = ArchCheck.DeadCode(public_is_entry = true)
            push!(active, configured)
        else
            push!(active, check)
        end
    end
    allowed = (("src/shape/plants.jl", :allowed_call),)
    whitelist = ArchCheck.CallerWhitelist((:guarded,), allowed)
    push!(active, whitelist)
    push!(active, ArchCheck.SentinelReturns(("src/shape/sentinels.jl",)))
    push!(active, ArchCheck.StringPayloads(("src/shape/payloads.jl",)))
    push!(active, ArchCheck.UnreadWaits())
    push!(active, ArchCheck.ToleranceSearch((:GAP,)))
    push!(active, ArchCheck.KeptBuilders(:(Shape.build_shape)))
    push!(active, ArchCheck.Independent(:Low, :Shape))
    readers = ((Exhibits.Shape.read_item, Tuple{}),)
    push!(active, ArchCheck.ReaderSet(Exhibits.Shape.Item, readers))
    push!(active, ArchCheck.ScanSeeds(("src/shape/seeds.jl",)))
    push!(active, ArchCheck.OverlappingCalls())
    jet = ArchCheck.jet_loaded()
    if !isnothing(jet)
        runtime = ArchCheck.OptEntry(Exhibits.Shape.runtime_plant, Tuple{Function,Int})
        boxed = ArchCheck.OptEntry(Exhibits.Shape.boxed_total, Tuple{Int})
        corpus = ArchCheck.OptEntry[runtime, boxed]
        push!(active, ArchCheck.OptAnalysis(corpus))
    end
    push!(active, ArchCheck.UnreachedMethods())
    push!(active, ArchCheck.Rebuilds())
    push!(active, ArchCheck.TwoNames())
    push!(active, ArchCheck.Waits())
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

function self_entries()
    (
        (ArchCheck.gate, Tuple{Module}),
        (ArchCheck.build_source_index, Tuple{AbstractString, Any, Any}),
        (ArchCheck.method_graph, Tuple{Any, Any}),
        (ArchCheck.arm!, Tuple{ArchCheck.Probes, Any}),
        (ArchCheck.disarm!, Tuple{ArchCheck.ProbeHandle}),
        (ArchCheck.observe, Tuple{Any, Any, Any}),
    )
end

function static_checks()
    active = ArchCheck.Check[]
    for check in ArchCheck.CHECKS
        if check isa ArchCheck.DeadCode
            configured = ArchCheck.DeadCode(public_is_entry = true)
            push!(active, configured)
        else
            push!(active, check)
        end
    end
    waits = ArchCheck.UnreadWaits(allowed = (:probe_wait, :wait_synced))
    push!(active, waits)
    push!(active, ArchCheck.OverlappingCalls())
    readers = ((ArchCheck.run, Tuple{Any}), (ArchCheck.kinds, Tuple{}))
    push!(active, ArchCheck.ReaderSet(ArchCheck.Check, readers))
    sentinels = (:Inf, :NaN, :missing)
    push!(active, ArchCheck.SentinelReturns(("src",), sentinels))
    push!(active, ArchCheck.StringPayloads(("src",)))
    push!(active, ArchCheck.ScanSeeds(("src",)))
    Tuple(active)
end

function workload_checks()
    (
        ArchCheck.UnreachedMethods(),
        ArchCheck.Rebuilds(),
        ArchCheck.TwoNames(),
        ArchCheck.Waits(),
    )
end

function self_checks()
    static = static_checks()
    workload = workload_checks()
    (static..., workload...)
end

function self_probes()
    watched = (
        ArchCheck.package_layout,
        ArchCheck.build_module_graph,
        ArchCheck.build_call_graph,
    )
    ArchCheck.Probes(functions = watched)
end

function self_gate(; report_path, io)
    checks = self_checks()
    entries = self_entries()
    probes = self_probes()
    ArchCheck.gate(ArchCheck;
        report_path = report_path,
        io = io,
        checks = checks,
        entries = entries,
        probes = probes,
        workload = exhibit_gate_quiet,
    )
end

function exhibit_gate_quiet()
    report = joinpath(mktempdir(), "exhibits.jsonl")
    run_exhibit_gate(report, devnull, nothing)
    nothing
end
