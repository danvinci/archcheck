# Construct the checks, probes, entries and derived values, then run the gate and record the status.
using TOML

function named_check(name)
    binding = Symbol(name)
    isdefined(ArchCheck, binding) || return nothing
    value = getfield(ArchCheck, binding)
    value isa Type || return nothing
    value <: ArchCheck.Check || return nothing
    value
end

# A config argument is a name, or a list of names that the check takes as one tuple.
check_argument(value::AbstractString) = Symbol(value)

function check_argument(values::AbstractVector)
    names = Symbol[]
    for value in values
        push!(names, Symbol(value))
    end
    Tuple(names)
end

# A config keyword is a number or a string as written; a list becomes a tuple.
keyword_value(value::AbstractVector) = Tuple(value)
keyword_value(value) = value

function keyword_pairs(keywords)
    pairs = Pair{Symbol,Any}[]
    for (key, value) in keywords
        converted = keyword_value(value)
        push!(pairs, Symbol(key) => converted)
    end
    pairs
end

function construct_check(name, args, keywords)
    check_type = named_check(name)
    isnothing(check_type) && return nothing
    positional = Any[]
    for arg in args
        push!(positional, check_argument(arg))
    end
    named = keyword_pairs(keywords)
    check_type(positional...; named...)
end

function try_construct(entry)
    name = entry["name"]
    args = entry["args"]
    keywords = entry["keywords"]
    try
        instance = construct_check(name, args, keywords)
        isnothing(instance) && return (status = :missing, name = name, value = nothing)
        (status = :built, name = name, value = instance)
    catch err
        shown = sprint(showerror, err)
        (status = :failed, name = name, value = shown)
    end
end

function partition_checks(spec)
    missing = String[]
    built = String[]
    failed = Dict{String,String}()
    instances = Any[]
    for entry in spec["checks"]
        outcome = try_construct(entry)
        status = outcome.status
        name = outcome.name
        value = outcome.value
        if status === :missing
            push!(missing, name)
        elseif status === :failed
            failed[name] = value
        else
            push!(built, name)
            push!(instances, value)
        end
    end
    (missing = missing, built = built, failed = failed, instances = instances)
end

function collect_modules!(found, mod)
    push!(found, mod)
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        value = getfield(mod, name)
        value isa Module || continue
        value === mod && continue
        parentmodule(value) === mod || continue
        collect_modules!(found, value)
    end
    found
end

# A probe name is a function, or a type whose constructors are probed.
is_probe_target(value::Function) = true
is_probe_target(value::Type) = true
is_probe_target(value) = false

function functions_named(modules, name)
    target = Symbol(name)
    found = Any[]
    for mod in modules
        isdefined(mod, target) || continue
        value = getfield(mod, target)
        is_probe_target(value) || continue
        push!(found, value)
    end
    unique!(found)
end

function resolve_named(modules, labels)
    found = Any[]
    for label in labels
        matches = functions_named(modules, label)
        isempty(matches) && throw(ArgumentError("probe name $label is absent"))
        append!(found, matches)
    end
    unique!(found)
end

function build_probes(pkg, entry)
    labels = entry["functions"]
    isempty(labels) && return nothing
    modules = collect_modules!(Module[], pkg)
    functions = resolve_named(modules, labels)
    ambient = resolve_named(modules, entry["ambient"])
    slow_s = Float64(entry["slow_s"])
    function_tuple = (functions...,)
    ambient_tuple = (ambient...,)
    ArchCheck.Probes(; functions = function_tuple, ambient = ambient_tuple, slow_s = slow_s)
end

# The included file defines the call in a later world than this function's.
function workload_from(file, call)
    isempty(file) && return nothing
    Base.include(Main, file)
    binding = Symbol(call)
    Base.invokelatest(getfield, Main, binding)
end

# `function` is a dotted path below the package; `types` is a tuple type read in that function's module.
function method_entry(pkg, entry)
    path = split(entry["function"], ".")
    owner = pkg
    for part in path[1:end-1]
        owner = getfield(owner, Symbol(part))
    end
    func = getfield(owner, Symbol(last(path)))
    parsed = Meta.parse(entry["types"])
    types = Core.eval(owner, parsed)
    (func, types)
end

function method_entries(pkg, listed)
    entries = Tuple[]
    for entry in listed
        push!(entries, method_entry(pkg, entry))
    end
    entries
end

function needs_workload(instances)
    for instance in instances
        ArchCheck.phase(instance) === :workload && return true
    end
    false
end

function resolve_one(modules, label)
    matches = functions_named(modules, label)
    count = length(matches)
    count == 1 || throw(ArgumentError("$label matched $count functions"))
    only(matches)
end

function named_functions(modules, entry, key)
    labels = get(entry, key, String[])
    found = Any[]
    for label in labels
        push!(found, resolve_one(modules, label))
    end
    Tuple(found)
end

# A config table names functions by their bare names in the package; `cache` names a field.
function build_one_derived(modules, entry)
    producer = resolve_one(modules, entry["producer"])
    key = nothing
    if haskey(entry, "key")
        key = resolve_one(modules, entry["key"])
    end
    cache = nothing
    if haskey(entry, "cache")
        cache = Symbol(entry["cache"])
    end
    readers = named_functions(modules, entry, "readers")
    converters = named_functions(modules, entry, "converters")
    ArchCheck.Derived(producer; key, cache, readers, converters)
end

function build_derived(pkg, listed)
    isempty(listed) && return ()
    modules = collect_modules!(Module[], pkg)
    built = Any[]
    for entry in listed
        push!(built, build_one_derived(modules, entry))
    end
    Tuple(built)
end

function drive_loaded(spec, pkg, instances)
    workload = nothing
    probes = nothing
    if needs_workload(instances)
        workload = workload_from(spec["workload_file"], spec["workload_call"])
        isnothing(workload) && throw(ArgumentError("workload checks have no workload"))
        probes = build_probes(pkg, spec["probes"])
    end
    entries = method_entries(pkg, spec["entries"])
    derived = build_derived(pkg, spec["derived"])
    checks = (instances...,)
    open(spec["log"], "w") do io
        ArchCheck.gate(pkg; checks = checks, report_path = spec["report"], io = io,
                       workload = workload, probes = probes, entries = entries, derived = derived)
    end
end

function write_status(path, missing, built, failed, red, message)
    payload = Dict{String,Any}()
    payload["missing"] = missing
    payload["built"] = built
    payload["failed"] = failed
    payload["gate_red"] = red
    payload["error"] = message
    open(path, "w") do io
        TOML.print(io, payload)
    end
end

function record_drive(spec, pkg)
    parts = partition_checks(spec)
    red = false
    message = ""
    try
        if !isempty(parts.instances)
            rm(spec["report"]; force = true)
            drive_loaded(spec, pkg, parts.instances)
        end
    catch err
        message = sprint(showerror, err)
        red = startswith(message, "architecture gate RED")
    end
    write_status(spec["status"], parts.missing, parts.built, parts.failed, red, message)
end
