# The loaded module a dotted key names below the package.
function loaded_module(pkg::Module, key::Symbol)
    mod = pkg
    for name in key_segments(key)
        mod = getfield(mod, name)
    end
    mod
end

# The consumer's entry: one parse of `pkg`'s src/, every check, a JSONL report, and a hard error on any
# blocking finding. The reflection checks read the package's modules at every depth.
function gate(pkg::Module;
              src = joinpath(pkgdir(pkg), "src"),
              entry_dirs = String[],
              report_path = joinpath(pkgdir(pkg), "test", "out", "architecture.jsonl"),
              io::IO = stdout,
              checks = CHECKS)
    pkg_name = string(nameof(pkg))
    spine = joinpath(src, pkg_name * ".jl")
    rank, dir2mod = parse_spine_order(spine)
    root = nameof(pkg)
    index = build_source_index(src, rank, dir2mod; entry_dirs, root)   # the one parse, src/ and entry dirs
    ordered = sort(collect(keys(index.rank)), by = m -> index.rank[m])
    mods = [loaded_module(pkg, m) for m in ordered]

    ctx = Context(index, mods; entry_dirs)
    findings = run_checks(ctx, checks)

    mkpath(dirname(report_path))
    previous = previous_fingerprints(report_path)
    current = Set(fingerprint(f) for f in findings)
    new = new_findings(findings, previous)
    fixed = previous === nothing ? 0 : length(setdiff(previous, current))
    print_architecture(io, findings, new, fixed, index.rank)
    open(handle -> emit_jsonl(handle, findings), report_path, "w")

    block = filter(isblocking, findings)
    if !isempty(block)
        println(io, "\n  BLOCKING")   # in full whether new or standing; the delta cannot hide these
        print_findings(io, block)
        error("architecture gate RED: $(length(block)) blocking finding(s)")
    end
    println(io, "== architecture clean ==")
    findings
end
