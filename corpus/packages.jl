# Replay real packages: one environment holds each listed package at its pinned release, and one process runs the
# default gate on each.
# usage: julia --project=. corpus/packages.jl corpus/packages.toml [--cache DIR]
using JSON
using TOML
using UUIDs

struct ListedPackage
    name::String                       # package and module name
    version::String                    # pinned release
    expected::Vector{String}           # error kinds the default gate should report, sorted
end

struct PackageRun
    errors::Vector{String}             # error kinds the gate reported, sorted
    advisories::Int                    # advisory findings the gate reported
    seconds::Float64                   # load and gate wall time (s)
    error_text::String                 # why loading or gating threw; empty when the gate ran
end

function take_args(args)
    config = ""
    cache = joinpath(homedir(), ".cache", "archcheck-packages")
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
    isempty(config) && throw(ArgumentError("usage: julia --project=. corpus/packages.jl <packages.toml> [--cache DIR]"))
    (config = config, cache = cache)
end

function archcheck_root()
    project = Base.active_project()
    isnothing(project) && throw(ArgumentError("activate the ArchCheck project first"))
    dirname(project)
end

function parse_packages(path)
    parsed = TOML.parsefile(path)
    table = parsed["packages"]
    names = sort!(collect(keys(table)))
    listed = ListedPackage[]
    for name in names
        row = table[name]
        version = string(row["version"])
        errors = String[string(kind) for kind in row["errors"]]
        expected = sort!(errors)
        push!(listed, ListedPackage(name, version, expected))
    end
    listed
end

# One release as Pkg spells it, `Name@1.2.3`.
release_text(package) = string(package.name, "@", package.version)

# The environment is rebuilt only when what it holds changes: the ArchCheck tree and every pinned release.
function prepare_env(listed, env, archcheck)
    arguments = [archcheck]
    for package in listed
        push!(arguments, release_text(package))
    end
    stamp_path = env * ".stamp"
    stamp = join(arguments, "\n")
    if isfile(stamp_path) && read(stamp_path, String) == stamp
        println("environment reused")
        return
    end
    rm(env; force = true, recursive = true)
    mkpath(env)
    identity = uuid4()
    write(joinpath(env, "Project.toml"), "name = \"PackagesEnv\"\nuuid = \"$identity\"\n")
    prepare = joinpath(@__DIR__, "prepare_packages.jl")
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
        run(`julia --project=$env $prepare $arguments`)
    end
    write(stamp_path, stamp)
    println("environment built")
end

function read_runs(results)
    runs = Dict{String,PackageRun}()
    isfile(results) || return runs
    for line in eachline(results)
        row = JSON.parse(line)
        errors = String[string(kind) for kind in get(row, "errors", String[])]
        advisories = Int(get(row, "advisories", 0))
        error_text = string(get(row, "error_text", ""))
        seconds = Float64(row["seconds"])
        runs[row["package"]] = PackageRun(errors, advisories, seconds, error_text)
    end
    runs
end

# A package the gate process did not reach fails with the process's exit code.
function gate_all(listed, env, cache)
    results = joinpath(cache, "results.jsonl")
    log = joinpath(cache, "gate.log")
    rm(results; force = true)
    script = joinpath(@__DIR__, "gate_packages.jl")
    names = [package.name for package in listed]
    command = ignorestatus(`julia --project=$env $script $results $names`)
    logged = pipeline(command; stdout = log, stderr = log)
    process = run(logged)
    runs = read_runs(results)
    unreached = "the gate process exited with code $(process.exitcode) before this package; see $log"
    missed = PackageRun(String[], 0, 0.0, unreached)
    [get(runs, name, missed) for name in names]
end

is_errored(result::PackageRun) = !isempty(result.error_text)

is_passed(package, result) = !is_errored(result) && result.errors == package.expected

kinds_cell(kinds) = isempty(kinds) ? "-" : join(kinds, ",")

reported_cell(result) = is_errored(result) ? "error" : kinds_cell(result.errors)

function result_cells(package, result)
    expected = kinds_cell(package.expected)
    reported = reported_cell(result)
    rounded = round(result.seconds; digits = 1)
    verdict = is_passed(package, result) ? "pass" : "fail"
    [package.name, package.version, expected, reported, string(result.advisories), string(rounded), verdict]
end

# The first line is the header; each column pads to its widest cell.
function print_cells(io, lines)
    column_count = length(first(lines))
    widths = [maximum(line -> length(line[index]), lines) for index in 1:column_count]
    for line in lines
        padded = [rpad(line[index], widths[index]) for index in 1:column_count]
        println(io, join(padded, "  "))
    end
end

function print_package_failure(io, package, result)
    expected = kinds_cell(package.expected)
    reported = reported_cell(result)
    println(io, "FAIL ", package.name, " expected ", expected, " reported ", reported)
    is_errored(result) || return
    indented = replace(result.error_text, "\n" => "\n  ")
    println(io, "  ", indented)
end

function main(args)
    taken = take_args(args)
    listed = parse_packages(taken.config)
    archcheck = archcheck_root()
    mkpath(taken.cache)
    env = joinpath(taken.cache, "env")
    prepare_env(listed, env, archcheck)
    results = gate_all(listed, env, taken.cache)
    headers = ["package", "version", "expected", "reported", "advisories", "seconds", "verdict"]
    lines = [headers]
    for (package, result) in zip(listed, results)
        push!(lines, result_cells(package, result))
    end
    println()
    print_cells(stdout, lines)
    failures = 0
    for (package, result) in zip(listed, results)
        is_passed(package, result) && continue
        print_package_failure(stdout, package, result)
        failures += 1
    end
    failures == 0 || exit(1)
end

if @__MODULE__() === Main
    main(ARGS)
end
