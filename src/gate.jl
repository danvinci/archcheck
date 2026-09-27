# The loaded module a dotted key names below the package.
function loaded_module(pkg::Module, key::Symbol)
    mod = pkg
    for name in key_segments(key)
        mod = getfield(mod, name)
    end
    mod
end

# The consumer's entry: one parse of `pkg`'s src/, every check, a JSONL report, and a hard error on any
# error finding. `error_kinds` promotes advisory kinds to errors for this consumer.
function gate(pkg::Module;
              src = joinpath(pkgdir(pkg), "src"),
              entry_dirs = String[],
              report_path = joinpath(pkgdir(pkg), "test", "out", "architecture.jsonl"),
              io::IO = stdout,
              checks = CHECKS,
              error_kinds = ())
    severity = severities(checks; error_kinds)   # before the parse, so a bad error_kinds fails fast
    pkg_name = string(nameof(pkg))
    spine = joinpath(src, pkg_name * ".jl")
    rank, dir2mod = parse_spine_order(spine)
    root = nameof(pkg)
    index = build_source_index(src, rank, dir2mod; entry_dirs, root)   # the one parse, src/ and entry dirs
    ordered = sort(collect(keys(index.rank)), by = m -> index.rank[m])
    mods = [loaded_module(pkg, m) for m in ordered]

    ctx = Context(index, pkg, mods; entry_dirs)
    findings = run_checks(ctx, checks)

    mkpath(dirname(report_path))
    previous = previous_fingerprints(report_path)
    current = Set(fingerprint(f) for f in findings)
    new = new_findings(findings, previous)
    fixed = previous === nothing ? 0 : length(setdiff(previous, current))
    print_architecture(io, findings, new, fixed, index.rank, severity)
    open(handle -> emit_jsonl(handle, findings, severity), report_path, "w")

    errors = filter(f -> iserror(f, severity), findings)
    if !isempty(errors)
        println(io, "\n  ERRORS")   # in full whether new or standing; the delta cannot hide these
        print_findings(io, errors, severity)
        error("architecture gate RED: $(length(errors)) error finding(s)")
    end
    println(io, "== architecture clean ==")
    findings
end
