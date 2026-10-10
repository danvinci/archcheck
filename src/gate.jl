const PHASES = (:static, :graph, :workload)

# The checks of one phase, in registry order. An unknown phase is a typo, so it throws.
function checks_in(checks, wanted::Symbol)
    for check in checks
        stage = phase(check)
        stage in PHASES || throw(ArgumentError("$(typeof(check)) runs in phase $stage"))
    end
    Tuple(check for check in checks if phase(check) === wanted)
end

"""Parses `pkg`'s `src/` once and runs the static `checks` (`CHECKS` by default), then `workload()` with `probes` armed, then walks the method graph from `entries` and runs the checks that read the graph or the workload. Prints what is new since the last report, writes each finding as a JSON line to `report_path` (`test/out/architecture.jsonl` by default), throws on a finding of an error kind, and returns the findings. `error_kinds` promotes kinds to errors; `entries` are `(function, argument types)` pairs that seed the method graph; `derived` holds the package's `Derived` declarations; `entry_dirs` are script and test directories that `ReachesInternal` holds to the public names."""
function gate(pkg::Module;
              src = joinpath(pkgdir(pkg), "src"),
              entry_dirs = String[],
              report_path = joinpath(pkgdir(pkg), "test", "out", "architecture.jsonl"),
              io::IO = stdout,
              checks = CHECKS,
              error_kinds = (),
              workload = nothing,
              probes::Union{Nothing,Probes} = nothing,
              entries = (),
              derived::Tuple{Vararg{Derived}} = ())
    severity = severities(checks; error_kinds)   # before the parse, so a bad error_kinds fails fast
    static = checks_in(checks, :static)
    walking = checks_in(checks, :graph)
    observing = checks_in(checks, :workload)
    if isnothing(workload)
        waiting = typeof.(observing)
        isempty(observing) || throw(ArgumentError("workload checks $waiting need a workload"))
        isnothing(probes) || throw(ArgumentError("probes observe a workload, and none is declared"))
    end
    parsed = Context(pkg; src, entry_dirs, derived)   # the one parse, src/ and entry dirs
    findings = run_checks(parsed, static)
    # The walk makes a specialization of each method it walks, so it waits until the workload's reach is read.
    # Restored probes define methods after this call's world began.
    unwalked = parsed
    if !isnothing(workload)
        observed = observe(workload, probes, parsed)
        unwalked = Context(parsed; observed)
    end
    ctx = Base.invokelatest(with_method_graph, unwalked, entries)
    walked_findings = Base.invokelatest(run_checks, ctx, walking)
    append!(findings, walked_findings)
    observed_findings = Base.invokelatest(run_checks, ctx, observing)
    append!(findings, observed_findings)

    mkpath(dirname(report_path))
    previous = previous_fingerprints(report_path)
    current = Set(fingerprint(f) for f in findings)
    new = new_findings(findings, previous)
    fixed = isnothing(previous) ? 0 : length(setdiff(previous, current))
    print_architecture(io, findings, new, fixed, ctx.index.rank, severity)
    open(handle -> emit_jsonl(handle, findings, severity), report_path, "w")

    errors = filter(f -> severity[f.kind] === :error, findings)
    if !isempty(errors)
        println(io, "\n  ERRORS")   # in full whether new or standing; the delta cannot hide these
        print_findings(io, errors, severity)
        error("architecture gate RED: $(length(errors)) error finding(s)")
    end
    println(io, "== architecture clean ==")
    findings
end
