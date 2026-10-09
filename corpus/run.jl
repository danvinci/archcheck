# Replay a host config: export pinned trees, run the gate, score each row.
using JSON
using SHA
using TOML
using UUIDs
using ArchCheck

include("prepare.jl")
include("drive.jl")
include("mutants/vector_kernels.jl")
include("workloads/dart_build.jl")

const KIND_WEIGHT = 4
const FILE_WEIGHT = 2
const SYMBOL_WEIGHT = 1
const FULL_MATCH = KIND_WEIGHT + FILE_WEIGHT + SYMBOL_WEIGHT
const DEFAULT_SLOW_S = 0.005   # calls shorter than this leave no record (s)
const SKIPPED_S = 0.0          # a state whose checks are all unbuilt (s)

struct CheckSpec
    name::String                       # check type name
    args::Vector{Any}                  # positional arguments: a name, or a list of names taken as one tuple
    keywords::Dict{String,Any}         # keyword arguments as the config writes them
end

struct EntrySpec
    function_path::String              # dotted path below the package to the entry function
    types::String                      # argument tuple type, read in that function's module
end

struct ProbeSpec
    functions::Vector{String}          # names resolved to functions in the loaded package
    ambient::Vector{String}            # names whose callees read state no argument shows
    slow_s::Float64                    # calls shorter than this leave no record (s)
end

struct StateSpec
    name::String                       # state name
    commit::String                     # revision to export
    workload_file::String              # absolute path; empty when this state declares none
    workload_call::String              # zero-argument function that file defines
    derived::Vector{Dict{String,Any}}  # derived-value tables this state declares
end

struct MutantSpec
    name::String                       # mutant name, used as its state in expectations
    base::String                       # state whose tree is copied
    source::String                     # state whose parent revision supplies the edited source
    script::String                     # absolute path of the editor
    workload_file::String              # absolute path; empty when this mutant declares none
    workload_call::String              # zero-argument function that file defines
    derived::Vector{Dict{String,Any}}  # derived-value tables this mutant declares
end

struct Expectation
    case::String                       # evidence-table case
    check::String                      # check type to construct
    state::String                      # state or mutant this row scores
    expect::String                     # fire or quiet
    kind::String                       # finding kind
    file_suffix::String                # finding file ends with this
    symbol::String                     # finding symbol contains this
end

struct Host
    module_name::String                # package module the gate loads
    repo::String                       # read-only repository
    states::Vector{StateSpec}          # pinned revisions
    mutants::Vector{MutantSpec}        # trees edited from a base state
    checks::Dict{String,CheckSpec}     # how to construct each check
    expectations::Vector{Expectation}  # rows to score
    probes::ProbeSpec                  # probe names for a workload run
    entries::Vector{EntrySpec}         # method-graph entries the gate expands
end

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

struct RowResult
    expectation::Expectation           # the row that was scored
    got::String                        # fired, quiet, not built, or error
    finding::String                    # the matched finding, or the nearest one
    seconds::Float64                   # the state's wall time (s)
end

function string_list(value)
    names = String[]
    for item in value
        push!(names, string(item))
    end
    names
end

function derived_rows(table)
    rows = get(table, "derived", Any[])
    Vector{Dict{String,Any}}(rows)
end

function workload_of(table, base)
    if !haskey(table, "workload")
        return (file = "", call = "")
    end
    block = table["workload"]
    relative = string(block["file"])
    file = joinpath(base, relative)
    call = string(block["call"])
    (file = file, call = call)
end

function parse_checks(table)
    specs = Dict{String,CheckSpec}()
    for (name, body) in table
        args = Vector{Any}(get(body, "args", Any[]))
        keywords = Dict{String,Any}(get(body, "keywords", Dict{String,Any}()))
        specs[name] = CheckSpec(name, args, keywords)
    end
    specs
end

function parse_entries(rows)
    entries = EntrySpec[]
    for row in rows
        path = string(row["function"])
        types = string(row["types"])
        push!(entries, EntrySpec(path, types))
    end
    entries
end

function parse_probes(table)
    if !haskey(table, "probes")
        return ProbeSpec(String[], String[], DEFAULT_SLOW_S)
    end
    block = table["probes"]
    functions = string_list(block["functions"])
    ambient = string_list(block["ambient"])
    slow_s = Float64(block["slow_s"])
    ProbeSpec(functions, ambient, slow_s)
end

function parse_states(table, base)
    names = collect(keys(table))
    sort!(names)
    states = StateSpec[]
    for name in names
        body = table[name]
        commit = string(body["commit"])
        workload = workload_of(body, base)
        derived = derived_rows(body)
        spec = StateSpec(name, commit, workload.file, workload.call, derived)
        push!(states, spec)
    end
    states
end

function parse_mutants(table, base)
    names = collect(keys(table))
    sort!(names)
    mutants = MutantSpec[]
    for name in names
        body = table[name]
        script = joinpath(base, string(body["script"]))
        base_name = string(body["base"])
        source_name = string(body["source"])
        workload = workload_of(body, base)
        derived = derived_rows(body)
        spec = MutantSpec(name, base_name, source_name, script, workload.file, workload.call, derived)
        push!(mutants, spec)
    end
    mutants
end

function parse_expectation(row)
    expect = string(row["expect"])
    expect in ("fire", "quiet") || throw(ArgumentError("expect is fire or quiet, got $expect"))
    case = string(row["case"])
    check = string(row["check"])
    state = string(row["state"])
    kind = string(row["kind"])
    file_suffix = string(row["file"])
    symbol = string(row["symbol"])
    Expectation(case, check, state, expect, kind, file_suffix, symbol)
end

function parse_expectations(rows)
    expectations = Expectation[]
    for row in rows
        push!(expectations, parse_expectation(row))
    end
    expectations
end

function known_names(states, mutants)
    names = Set{String}()
    for state in states
        push!(names, state.name)
    end
    for mutant in mutants
        push!(names, mutant.name)
    end
    names
end

function validate_host(host)
    known = known_names(host.states, host.mutants)
    for row in host.expectations
        haskey(host.checks, row.check) || throw(ArgumentError("$(row.check) has no constructor table entry"))
        row.state in known || throw(ArgumentError("$(row.state) is not a declared state"))
    end
    host
end

function parse_host(path)
    parsed = TOML.parsefile(path)
    absolute = abspath(path)
    base = dirname(absolute)
    states = parse_states(parsed["states"], base)
    mutants = MutantSpec[]
    if haskey(parsed, "mutants")
        mutants = parse_mutants(parsed["mutants"], base)
    end
    checks = parse_checks(parsed["checks"])
    expectations = parse_expectations(parsed["expectations"])
    probes = parse_probes(parsed)
    entry_rows = get(parsed, "entries", Any[])
    entries = parse_entries(entry_rows)
    module_name = string(parsed["module"])
    repo = string(parsed["repo"])
    host = Host(module_name, repo, states, mutants, checks, expectations, probes, entries)
    validate_host(host)
end

function archcheck_root()
    project = Base.active_project()
    isnothing(project) && throw(ArgumentError("activate the package project first"))
    dirname(project)
end

function host_label(config)
    file = basename(config)
    splitext(file)[1]
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

function resolve_commit(repo, commit)
    raw = read(`git -C $repo rev-parse $commit`, String)
    strip(raw)
end

function stamp_text(lines)
    join(lines, "\n") * "\n"
end

function same_stamp(path, text)
    isfile(path) || return false
    held = read(path, String)
    held == text
end

function file_digest(path)
    bytes = read(path)
    digest = sha256(bytes)
    bytes2hex(digest)
end

function reset_dir(path)
    rm(path; force = true, recursive = true)
    mkpath(path)
end

function export_commit(repo, commit, tree)
    reset_dir(tree)
    archive = `git -C $repo archive --format=tar $commit`
    extract = `tar -x -C $tree`
    stream = pipeline(archive, extract)
    run(stream)
end

function prepare_export(label, repo, commit, tree, stamp_path, archcheck)
    text = stamp_text(["commit=$commit", "archcheck=$archcheck"])
    if same_stamp(stamp_path, text)
        println("prepare ", label, " export reused")
        return
    end
    export_commit(repo, commit, tree)
    write(stamp_path, text)
    println("prepare ", label, " export")
end

function replace_tree(source, dest)
    rm(dest; force = true, recursive = true)
    parent = dirname(dest)
    mkpath(parent)
    cp(source, dest)
end

function prepare_mutant(label, base_tree, tree, script, repo, source_commit, stamp_path, archcheck)
    digest = file_digest(script)
    text = stamp_text(["commit=$source_commit", "script=$digest", "archcheck=$archcheck"])
    if same_stamp(stamp_path, text)
        println("prepare ", label, " export reused")
        return
    end
    replace_tree(base_tree, tree)
    run(`julia $script $tree $repo $source_commit`)
    write(stamp_path, text)
    println("prepare ", label, " export")
end

function ensure_project(env)
    mkpath(env)
    project = joinpath(env, "Project.toml")
    isfile(project) && return
    identity = uuid4()
    text = "name = \"CorpusEnv\"\nuuid = \"$identity\"\n"
    write(project, text)
end

function instantiate_env(env, tree, archcheck, prepare)
    reset_dir(env)
    ensure_project(env)
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
        run(`julia --project=$env $prepare $tree $archcheck`)
    end
end

function prepare_env(label, env, tree, archcheck, prepare, stamp_path)
    text = stamp_text(["tree=$tree", "archcheck=$archcheck"])
    if same_stamp(stamp_path, text)
        println("prepare ", label, " instantiate reused")
        return
    end
    instantiate_env(env, tree, archcheck, prepare)
    write(stamp_path, text)
    println("prepare ", label, " instantiate")
end

function is_built_check(name)
    binding = Symbol(name)
    isdefined(ArchCheck, binding) || return false
    value = getfield(ArchCheck, binding)
    value isa Type && value <: ArchCheck.Check
end

function checks_for(host, state_name)
    names = String[]
    for row in host.expectations
        row.state == state_name || continue
        row.check in names && continue
        push!(names, row.check)
    end
    names
end

function split_built(names)
    built = String[]
    missing = String[]
    for name in names
        if is_built_check(name)
            push!(built, name)
        else
            push!(missing, name)
        end
    end
    (built = built, missing = missing)
end

function check_payload(spec)
    payload = Dict{String,Any}()
    payload["name"] = spec.name
    payload["args"] = spec.args
    payload["keywords"] = spec.keywords
    payload
end

function entry_payloads(entries)
    payloads = Dict{String,Any}[]
    for entry in entries
        payload = Dict{String,Any}("function" => entry.function_path, "types" => entry.types)
        push!(payloads, payload)
    end
    payloads
end

function write_spec(path, host, place, report, log, status, checks)
    probes = host.probes
    probe_payload = Dict("functions" => probes.functions, "ambient" => probes.ambient,
                         "slow_s" => probes.slow_s)
    entries = entry_payloads(host.entries)
    payload = Dict("module" => host.module_name, "report" => report, "log" => log, "status" => status,
                   "checks" => checks, "workload_file" => place.workload_file,
                   "workload_call" => place.workload_call, "probes" => probe_payload, "entries" => entries,
                   "derived" => place.derived)
    open(path, "w") do io
        TOML.print(io, payload)
    end
end

# The state's process runs in its cache directory, so whatever the workload writes stays there.
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

function string_set(items)
    found = Set{String}()
    for item in items
        push!(found, string(item))
    end
    found
end

function empty_status(message)
    missing = Set{String}()
    failed = Set{String}()
    (missing = missing, failed = failed, message = message, gate_red = false)
end

function read_status(path)
    parsed = TOML.parsefile(path)
    missing = string_set(parsed["missing"])
    failed_keys = keys(parsed["failed"])
    failed = string_set(failed_keys)
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

# The state or mutant a name declares; both carry the workload and the derived values.
function place_spec(host, name)
    for state in host.states
        state.name == name && return state
    end
    for mutant in host.mutants
        mutant.name == name && return mutant
    end
    throw(ArgumentError("$name is not a declared state"))
end

function score_state(host, name, directory)
    names = checks_for(host, name)
    parts = split_built(names)
    if isempty(parts.built)
        missing = Set(parts.missing)
        failed = Set{String}()
        empty_findings = Found[]
        return StateRun(name, SKIPPED_S, empty_findings, missing, failed, false)
    end
    report = joinpath(directory, "report.jsonl")
    log = joinpath(directory, "gate.log")
    status_path = joinpath(directory, "status.toml")
    spec_path = joinpath(directory, "spec.toml")
    env = joinpath(directory, "env")
    payloads = Dict{String,Any}[]
    for check_name in parts.built
        push!(payloads, check_payload(host.checks[check_name]))
    end
    place = place_spec(host, name)
    write_spec(spec_path, host, place, report, log, status_path, payloads)
    rm(status_path; force = true)
    outcome = run_process(env, spec_path)
    status = empty_status("drive wrote no status")
    if isfile(status_path)
        status = read_status(status_path)
    end
    missing = union(Set(parts.missing), status.missing)
    process_failed = !isempty(outcome.crashed)
    status_failed = !status.gate_red && !isempty(status.message)
    errored = process_failed || status_failed
    findings = Found[]
    if !errored
        findings = load_findings(report)
    end
    StateRun(name, outcome.seconds, findings, missing, status.failed, errored)
end

function match_score(found, expectation)
    score = 0
    if found.kind == expectation.kind
        score += KIND_WEIGHT
    end
    if endswith(found.file, expectation.file_suffix)
        score += FILE_WEIGHT
    end
    if occursin(expectation.symbol, found.symbol)
        score += SYMBOL_WEIGHT
    end
    score
end

function best_finding(findings, expectation)
    chosen = nothing
    best = -1
    for found in findings
        score = match_score(found, expectation)
        if score > best
            chosen = found
            best = score
        end
    end
    chosen
end

function describe(found)
    isnothing(found) && return "-"
    string(found.file, ":", found.line, ":", found.symbol)
end

function got_for(expectation, state)
    if expectation.check in state.missing
        return "not built"
    end
    if expectation.check in state.failed || state.errored
        return "error"
    end
    for found in state.findings
        match_score(found, expectation) == FULL_MATCH && return "fired"
    end
    "quiet"
end

function finding_text(expectation, state, got)
    got == "not built" && return "-"
    got == "error" && return "-"
    chosen = best_finding(state.findings, expectation)
    describe(chosen)
end

function score_rows(host, runs)
    rows = RowResult[]
    for expectation in host.expectations
        state = runs[expectation.state]
        got = got_for(expectation, state)
        text = finding_text(expectation, state, got)
        push!(rows, RowResult(expectation, got, text, state.seconds))
    end
    rows
end

function row_cells(row)
    rounded = round(row.seconds; digits = 3)
    seconds = string(rounded)
    expectation = row.expectation
    cells = String[]
    push!(cells, expectation.case)
    push!(cells, expectation.check)
    push!(cells, expectation.state)
    push!(cells, expectation.expect)
    push!(cells, row.got)
    push!(cells, row.finding)
    push!(cells, seconds)
    cells
end

function column_width(rows, index, header)
    width = length(header)
    for row in rows
        cells = row_cells(row)
        width = max(width, length(cells[index]))
    end
    width
end

function print_cells(io, cells, widths)
    padded = String[]
    for index in 1:length(cells)
        push!(padded, rpad(cells[index], widths[index]))
    end
    println(io, join(padded, "  "))
end

function print_table(io, rows)
    headers = ("case", "check", "state", "expected", "got", "finding", "seconds")
    widths = Int[]
    for index in 1:length(headers)
        push!(widths, column_width(rows, index, headers[index]))
    end
    print_cells(io, headers, widths)
    for row in rows
        print_cells(io, row_cells(row), widths)
    end
end

function is_failure(row)
    row.got == "error" && return true
    row.got == "not built" && return false
    if row.expectation.expect == "fire"
        return row.got != "fired"
    end
    row.got != "quiet"
end

function print_failure(io, row)
    expectation = row.expectation
    println(io, "FAIL ", expectation.case, " ", expectation.check, " ", expectation.state,
            " expected ", expectation.expect, " got ", row.got)
end

function failure_count(rows)
    failures = 0
    for row in rows
        is_failure(row) && (failures += 1)
    end
    failures
end

function place_dir(cache, label, name)
    joinpath(cache, label, name)
end

function prepare_states(host, cache, label, archcheck, prepare)
    trees = Dict{String,String}()
    commits = Dict{String,String}()
    for state in host.states
        directory = place_dir(cache, label, state.name)
        mkpath(directory)
        tree = joinpath(directory, "tree")
        commit = resolve_commit(host.repo, state.commit)
        stamp = joinpath(directory, "export.stamp")
        prepare_export(state.name, host.repo, commit, tree, stamp, archcheck)
        env = joinpath(directory, "env")
        env_stamp = joinpath(directory, "env.stamp")
        prepare_env(state.name, env, tree, archcheck, prepare, env_stamp)
        trees[state.name] = tree
        commits[state.name] = commit
        flush(stdout)
    end
    for mutant in host.mutants
        directory = place_dir(cache, label, mutant.name)
        mkpath(directory)
        tree = joinpath(directory, "tree")
        source = commits[mutant.source]
        stamp = joinpath(directory, "export.stamp")
        prepare_mutant(mutant.name, trees[mutant.base], tree, mutant.script, host.repo, source,
                       stamp, archcheck)
        env = joinpath(directory, "env")
        env_stamp = joinpath(directory, "env.stamp")
        prepare_env(mutant.name, env, tree, archcheck, prepare, env_stamp)
        flush(stdout)
    end
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

function main(args)
    taken = take_args(args)
    host = parse_host(taken.config)
    archcheck = archcheck_root()
    label = host_label(taken.config)
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
