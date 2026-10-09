# Replay a host config: export pinned trees, run the gate, score each row.
using JSON
using SHA
using TOML
using UUIDs
using ArchCheck

include("cli.jl")
include("prepare.jl")
include("drive.jl")
include("host.jl")
include("export.jl")
include("spec.jl")
include("process.jl")
include("score.jl")
include("mutants/vector_kernels.jl")
include("workloads/dart_build.jl")

const USAGE = "usage: julia --project=. corpus/run.jl <host.toml> [--cache DIR]"

function main(args)
    taken = take_args(args, USAGE)
    host = parse_host(taken.config)
    archcheck = archcheck_root()
    prepare = joinpath(@__DIR__, "prepare.jl")
    prepare_states(host, taken.cache, taken.label, archcheck, prepare)
    runs = run_places(host, taken.cache, taken.label)
    rows = score_rows(host, runs)
    println()
    print_table(stdout, rows)
    for row in rows
        is_failure(row) && print_failure(stdout, row)
    end
    failures = failure_count(rows)
    failures == 0 || exit(1)
end

if @__MODULE__() === Main
    main(ARGS)
end
