# Write the spec one state's process reads.

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
        if isnothing(named_check(name))
            push!(missing, name)
        else
            push!(built, name)
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
