# One exported tree: construct the named checks, run the gate, record what happened.
using TOML

function entry_min_nodes(entry)
    haskey(entry, "min_nodes") || return nothing
    Int(entry["min_nodes"])
end

function construct_check(name, min_nodes, args)
    binding = Symbol(name)
    isdefined(ArchCheck, binding) || return nothing
    check_type = getfield(ArchCheck, binding)
    check_type isa Type || return nothing
    check_type <: ArchCheck.Check || return nothing
    symbols = Symbol[]
    for arg in args
        push!(symbols, Symbol(arg))
    end
    if !isnothing(min_nodes)
        return check_type(; min_nodes = min_nodes)
    end
    if isempty(symbols)
        return check_type()
    end
    packed = (symbols...,)
    check_type(packed)
end

function try_construct(entry)
    name = entry["name"]
    min_nodes = entry_min_nodes(entry)
    args = entry["args"]
    try
        instance = construct_check(name, min_nodes, args)
        isnothing(instance) && return (status = :missing, name = name, value = nothing)
        (status = :built, name = name, value = instance)
    catch err
        shown = sprint(showerror, err)
        (status = :failed, name = name, value = shown)
    end
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

function functions_named(modules, name)
    target = Symbol(name)
    found = Any[]
    for mod in modules
        isdefined(mod, target) || continue
        value = getfield(mod, target)
        value isa Function || continue
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

function workload_from(file, call)
    isempty(file) && return nothing
    Base.include(Main, file)
    binding = Symbol(call)
    getfield(Main, binding)
end

function needs_workload(instances)
    for instance in instances
        ArchCheck.phase(instance) === :workload && return true
    end
    false
end

function run_gate(pkg, instances, report, log, workload, probes)
    checks = (instances...,)
    open(log, "w") do io
        ArchCheck.gate(pkg; checks = checks, report_path = report, io = io, workload = workload,
                       probes = probes)
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

function drive_loaded(spec, pkg)
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
    red = false
    message = ""
    try
        if !isempty(instances)
            rm(spec["report"]; force = true)
            workload = nothing
            probes = nothing
            if needs_workload(instances)
                workload = workload_from(spec["workload_file"], spec["workload_call"])
                isnothing(workload) && throw(ArgumentError("workload checks have no workload"))
                probes = build_probes(pkg, spec["probes"])
            end
            run_gate(pkg, instances, spec["report"], spec["log"], workload, probes)
        end
    catch err
        message = sprint(showerror, err)
        red = startswith(message, "architecture gate RED")
    end
    write_status(spec["status"], missing, built, failed, red, message)
end

function read_host_spec(path)
    TOML.parsefile(path)
end
