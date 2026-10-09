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
    (ArchCheck.Rebuilds, "one probe session runs at a time, and this gate arms none"),
    (ArchCheck.TwoNames, "one probe session runs at a time, and this gate arms none"),
    (ArchCheck.Waits, "one probe session runs at a time, and this gate arms none"),
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
    push!(active, ArchCheck.UnreadWaits(allowed = (:hold_inputs,)))
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
        (ArchCheck.check_opt_entries, Tuple{Any}),
    )
end

function self_opt()
    ArchCheck.OptAnalysis()
    index_types = Tuple{String, Dict{Symbol,Vector{Int}}, Dict{String,Symbol}}
    index_entry = ArchCheck.OptEntry(ArchCheck.build_source_index, index_types)
    scan_types = Tuple{Base.JuliaSyntax.SyntaxNode}
    scan_entry = ArchCheck.OptEntry(ArchCheck.scan_tree, scan_types)
    check_types = Tuple{ArchCheck.Context{Tuple{}}, Tuple{ArchCheck.Corpus}}
    check_entry = ArchCheck.OptEntry(ArchCheck.run_checks, check_types)
    entries = ArchCheck.OptEntry[index_entry, scan_entry, check_entry]
    ArchCheck.OptAnalysis(entries)
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
    push!(active, self_opt())
    Tuple(active)
end

function workload_checks()
    (ArchCheck.UnreachedMethods(public_is_entry = true),)
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

ignore_owner(_) = false

function vararg_parameter()
    signature = Tuple{Vararg{Int}}
    unwrapped = Base.unwrap_unionall(signature)
    unwrapped.parameters[1]
end

function exercise_types()
    ArchCheck.is_foreign(1, ignore_owner)
    ArchCheck.is_foreign(:name, ignore_owner)
    parameter = vararg_parameter()
    ArchCheck.is_foreign(parameter, ignore_owner)
    members = (Int, String)
    ArchCheck.any_member_foreign(members, ignore_owner)
    ArchCheck.is_foreign(Union{Int,String}, ignore_owner)
    vars = TypeVar[]
    ArchCheck.is_open_position(Union{Int,String}, vars)
    opened = Vector{T} where T
    ArchCheck.is_open_position(opened, vars)
    problems = Set{String}()
    omitted = Symbol[]
    ArchCheck.extend_key!(problems, omitted, nothing, nothing, nothing, nothing)
    found = ArchCheck.Finding[]
    ArchCheck.append_uncached!(found, nothing, nothing, nothing)
    var = TypeVar(:T)
    bound = TypeVar[]
    free = TypeVar[]
    ArchCheck.contains_typevar(free, var)
    ArchCheck.collect_free_typevars!(free, bound, var)
    mixed = Union{Int,var}
    ArchCheck.collect_free_typevars!(free, bound, mixed)
    wrapped = UnionAll(var, Vector{var})
    ArchCheck.collect_free_typevars!(free, bound, wrapped)
    ArchCheck.collect_free_typevars!(free, bound, parameter)
    held = Vector{var}
    ArchCheck.collect_free_typevars!(free, bound, held)
    ArchCheck.collect_free_typevars!(free, bound, 1)
    type_error = TypeError(:typeassert, "", Int, "x")
    ArchCheck.type_application_failed(type_error)
    method_error = MethodError(sin, (1,))
    ArchCheck.type_application_failed(method_error)
    argument_error = ArgumentError("bad")
    ArchCheck.type_application_failed(argument_error)
    ArchCheck.type_application_failed(1)
    ArchCheck.skipped_callee(1)
    ArchCheck.skipped_callee(Core.tuple)
    ArchCheck.skipped_callee(Core.Intrinsics.add_int)
    ArchCheck.skipped_callee(sin)
    ArchCheck.skipped_callee(NamedTuple)
    code = (slottypes = Any[Int],)
    argument = Core.Argument(1)
    ArchCheck.value_type_of(code, argument)
    constant = Core.Const(1)
    ArchCheck.value_type_of(code, constant)
    resolved = Core.Const(sin)
    ArchCheck.resolve_callee(code, resolved)
    quoted = QuoteNode(:name)
    ArchCheck.resolve_callee(code, quoted)
    ArchCheck.resolve_callee(code, sin)
    ArchCheck.resolve_callee(code, Int)
    nothing
end

function exhibit_gate_quiet()
    report = joinpath(mktempdir(), "exhibits.jsonl")
    probes = exhibit_probes()
    run_exhibit_gate(report, devnull, probes)
    exercise_types()
    nothing
end
