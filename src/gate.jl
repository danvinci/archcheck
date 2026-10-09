const PHASES = (:static, :workload)

# The checks of one phase, in registry order. An unknown phase is a typo, so it throws.
function checks_in(checks, wanted::Symbol)
    for check in checks
        stage = phase(check)
        stage in PHASES || throw(ArgumentError("$(typeof(check)) runs in phase $stage"))
    end
    Tuple(check for check in checks if phase(check) === wanted)
end

# One parse of `pkg`'s src/, the static checks, then `workload()` under `probes` and the checks that read it; one
# JSONL report, and an error on any error finding. `entries` seed the method graph; `derived` declares values.
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
    observing = checks_in(checks, :workload)
    if isnothing(workload)
        waiting = typeof.(observing)
        isempty(observing) || throw(ArgumentError("workload checks $waiting need a workload"))
        isnothing(probes) || throw(ArgumentError("probes observe a workload, and none is declared"))
    end
    pkg_name = string(nameof(pkg))
    spine = joinpath(src, pkg_name * ".jl")
    root = nameof(pkg)
    rank, dir2mod = package_layout(spine, root)
    index = build_source_index(src, rank, dir2mod; entry_dirs, root)   # the one parse, src/ and entry dirs
    ordered = sort(collect(keys(index.rank)), by = m -> index.rank[m])
    mods = [loaded_module(pkg, m) for m in ordered]

    methods = isempty(entries) ? nothing : method_graph(entries, package_modules(pkg, mods))
    ctx = Context(index, pkg, mods; entry_dirs, methods, derived)
    findings = run_checks(ctx, static)
    if !isnothing(workload)
        observed = observe(workload, probes, ctx)
        after_workload = Context(ctx; observed)
        # Restored probes define methods and keyword bodies after this call's world began.
        observed_findings = Base.invokelatest(run_checks, after_workload, observing)
        append!(findings, observed_findings)
    end

    mkpath(dirname(report_path))
    previous = previous_fingerprints(report_path)
    current = Set(fingerprint(f) for f in findings)
    new = new_findings(findings, previous)
    fixed = isnothing(previous) ? 0 : length(setdiff(previous, current))
    print_architecture(io, findings, new, fixed, index.rank, severity)
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
