# Run inside the packages' environment: the default gate on each named package, one JSON line per package.
# usage: julia --project=<env> gate_packages.jl <results.jsonl> <Name>...
using ArchCheck
using JSON

# The gate's error kinds and its advisory count, from the report it wrote; a red verdict is a result.
function gated(pkg)
    report = joinpath(mktempdir(), "architecture.jsonl")
    try
        ArchCheck.gate(pkg; report_path = report, io = devnull)
    catch err
        is_red = err isa ErrorException && startswith(err.msg, "architecture gate RED")
        is_red || rethrow()
    end
    errors = String[]
    advisories = 0
    for line in eachline(report)
        record = JSON.parse(line)
        if record["severity"] == "error"
            push!(errors, record["kind"])
        else
            advisories += 1
        end
    end
    (errors = sort!(unique!(errors)), advisories = advisories)
end

function gate_package(name)
    started = time()
    row = Dict{String,Any}("package" => name)
    try
        binding = Symbol(name)
        Core.eval(Main, :(import $binding))
        pkg = Base.invokelatest(getfield, Main, binding)
        result = Base.invokelatest(gated, pkg)
        row["errors"] = result.errors
        row["advisories"] = result.advisories
    catch err
        row["error_text"] = sprint(showerror, err)
    end
    row["seconds"] = time() - started
    row
end

function gate_listed(args)
    results = args[1]
    open(results, "w") do io
        for name in args[2:end]
            row = gate_package(name)
            println(io, JSON.json(row))
            flush(io)
        end
    end
end

gate_listed(ARGS)
