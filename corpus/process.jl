# Run one state in its own process and read what that process wrote.

const SKIPPED_S = 0.0   # a state whose checks are all unbuilt (s)

struct Found
    kind::String                       # finding kind
    file::String                       # repo-relative path
    symbol::String                     # offending name
    line::String                       # source line
end

struct StateRun
    name::String                       # state or mutant
    seconds::Float64                   # wall time of the state process (s)
    findings::Vector{Found}            # findings the report held
    missing::Set{String}               # check names with no definition
    failed::Set{String}                # check names whose constructor threw
    errored::Bool                      # the state process failed
end

# The child process uses the state directory as its working directory, so the workload's writes stay there.
function run_process(env, spec_path)
    drive = joinpath(@__DIR__, "drive_main.jl")
    directory = dirname(spec_path)
    command = Cmd(`julia --project=$env $drive $spec_path`; dir = directory)
    started = time()
    crashed = ""
    try
        run(command)
    catch err
        crashed = sprint(showerror, err)
    end
    seconds = time() - started
    (seconds = seconds, crashed = crashed)
end

function empty_status(message)
    missing = Set{String}()
    failed = Set{String}()
    (missing = missing, failed = failed, message = message, gate_red = false)
end

function read_status(path)
    parsed = TOML.parsefile(path)
    missing_labels = string.(parsed["missing"])
    missing = Set{String}(missing_labels)
    failed_keys = keys(parsed["failed"])
    failed_labels = string.(failed_keys)
    failed = Set{String}(failed_labels)
    message = string(parsed["error"])
    red = parsed["gate_red"]
    (missing = missing, failed = failed, message = message, gate_red = red)
end

function load_findings(path)
    records = Found[]
    isfile(path) || return records
    for line in eachline(path)
        parsed = JSON.parse(line)
        kind = string(parsed["kind"])
        file = string(parsed["file"])
        symbol = string(parsed["symbol"])
        line_text = string(parsed["line"])
        push!(records, Found(kind, file, symbol, line_text))
    end
    records
end

function skipped_run(name, missing_names)
    missing = Set{String}(missing_names)
    failed = Set{String}()
    findings = Found[]
    StateRun(name, SKIPPED_S, findings, missing, failed, false)
end

function drive_directory(host, name, directory, built_names)
    payloads = Dict{String,Any}[]
    for check_name in built_names
        spec = host.checks[check_name]
        push!(payloads, check_payload(spec))
    end
    place = place_spec(host, name)
    report = joinpath(directory, "report.jsonl")
    log = joinpath(directory, "gate.log")
    status_path = joinpath(directory, "status.toml")
    spec_path = joinpath(directory, "spec.toml")
    env = joinpath(directory, "env")
    write_spec(spec_path, host, place, report, log, status_path, payloads)
    rm(status_path; force = true)
    outcome = run_process(env, spec_path)
    (outcome = outcome, status_path = status_path, report = report)
end

function collect_run(name, missing_names, driven)
    status = empty_status("drive wrote no status")
    if isfile(driven.status_path)
        status = read_status(driven.status_path)
    end
    declared_missing = Set{String}(missing_names)
    missing = union(declared_missing, status.missing)
    process_failed = !isempty(driven.outcome.crashed)
    status_failed = !status.gate_red && !isempty(status.message)
    errored = process_failed || status_failed
    findings = Found[]
    if !errored
        findings = load_findings(driven.report)
    end
    StateRun(name, driven.outcome.seconds, findings, missing, status.failed, errored)
end

function score_state(host, name, directory)
    names = checks_for(host, name)
    parts = split_built(names)
    if isempty(parts.built)
        return skipped_run(name, parts.missing)
    end
    driven = drive_directory(host, name, directory, parts.built)
    collect_run(name, parts.missing, driven)
end

function run_places(host, cache, label)
    runs = Dict{String,StateRun}()
    names = known_names(host.states, host.mutants)
    ordered = sort!(collect(names))
    for name in ordered
        directory = place_dir(cache, label, name)
        runs[name] = score_state(host, name, directory)
    end
    runs
end
