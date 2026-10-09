# The host config: pinned states, checks, and the rows to score.

const DEFAULT_SLOW_S = 0.005   # calls shorter than this leave no record (s)

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
    functions = string.(block["functions"])
    ambient = string.(block["ambient"])
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

# A state and a mutant both carry the workload and the derived values.
function place_spec(host, name)
    for state in host.states
        state.name == name && return state
    end
    for mutant in host.mutants
        mutant.name == name && return mutant
    end
    throw(ArgumentError("$name is not a declared state"))
end
