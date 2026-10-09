# Replay a host config: export pinned trees, run the gate, score each row.
using JSON
using SHA
using TOML
using UUIDs
using ArchCheck

include("prepare.jl")
include("drive.jl")
include("host.jl")
include("export.jl")
include("spec.jl")
include("process.jl")
include("score.jl")
include("mutants/vector_kernels.jl")
include("workloads/dart_build.jl")

function archcheck_root()
    project = Base.active_project()
    isnothing(project) && throw(ArgumentError("activate the package project first"))
    dirname(project)
end

function take_args(args)
    config = ""
    cache = joinpath(homedir(), ".cache", "archcheck-corpus")
    index = 1
    while index <= length(args)
        arg = args[index]
        if arg == "--cache"
            cache = args[index + 1]
            index += 2
        else
            config = arg
            index += 1
        end
    end
    isempty(config) && throw(ArgumentError("usage: julia --project=. corpus/run.jl <host.toml> [--cache DIR]"))
    (config = config, cache = cache)
end

function main(args)
    taken = take_args(args)
    host = parse_host(taken.config)
    archcheck = archcheck_root()
    file_name = basename(taken.config)
    label = splitext(file_name)[1]
    prepare = joinpath(@__DIR__, "prepare.jl")
    prepare_states(host, taken.cache, label, archcheck, prepare)
    runs = run_places(host, taken.cache, label)
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
