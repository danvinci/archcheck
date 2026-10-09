# Severities, worst first. An error blocks the gate; an advisory reports.
const SEVERITIES = (:error, :advisory)

# One structural problem, owned by the module whose code carries it. Its severity is not its own: the
# emitting check declares it per kind, and the gate's `error_kinds` may promote it.
struct Finding
    mod::Symbol      # module the offending code lives in
    kind::Symbol     # the check that produced it
    file::String     # repo-relative path
    symbol::String   # offending name; "" when the finding is file-level
    line::Int        # source line; 0 when file/module-level
    detail::String   # what was observed
    evidence::Vector{Pair{Symbol,String}}   # measurements the reader weighs; data, never a verdict
end
Finding(mod, kind, file, symbol, line::Integer, detail) =
    Finding(mod, kind, file, symbol, line, detail, Pair{Symbol,String}[])
Finding(mod, kind, file, symbol, detail) = Finding(mod, kind, file, symbol, 0, detail)

# A finding's identity across runs. Line is excluded: it drifts with any edit above it.
struct FindingKey
    mod::String       # module the offending code lives in
    kind::String      # check that produced it
    file::String      # repo-relative path
    symbol::String    # offending name; "" when the finding is file-level
end
Base.:(==)(a::FindingKey, b::FindingKey) =
    a.mod == b.mod && a.kind == b.kind && a.file == b.file && a.symbol == b.symbol
function Base.hash(k::FindingKey, h::UInt)
    seed = hash(k.mod, h)
    seed = hash(k.kind, seed)
    seed = hash(k.file, seed)
    hash(k.symbol, seed)
end

fingerprint(f::Finding) = FindingKey(string(f.mod), string(f.kind), f.file, f.symbol)

# One JSON object per line, greppable per module. `severity` is the one the gate applied, promotions included.
function emit_jsonl(io::IO, findings, severity)
    for f in findings
        JSON.print(io, Dict("module" => string(f.mod), "kind" => string(f.kind),
                            "severity" => string(severity[f.kind]),
                            "file" => f.file, "line" => f.line, "symbol" => f.symbol,
                            "detail" => f.detail,
                            "evidence" => Dict(string(k) => v for (k, v) in f.evidence)))
        println(io)
    end
end

# `key value` pairs, fixed vocabulary per kind, no adjectives.
render_evidence(f::Finding) = join(("$k $v" for (k, v) in f.evidence), "  ")

# Fingerprints from the previous run's report. `nothing` when there is no usable previous run: a partly
# readable report would silently under-report `previous` and show old findings as new.
function previous_fingerprints(path)
    isfile(path) || return nothing
    seen = Set{FindingKey}()
    for line in eachline(path)
        rec = try
            JSON.parse(line)
        catch
            return nothing
        end
        push!(seen, FindingKey(rec["module"], rec["kind"], rec["file"], rec["symbol"]))
    end
    seen
end

# Findings the previous run did not have. A kind absent from that run is a check that did not exist yet,
# so its findings enter as standing rather than as a wall of new ones.
function new_findings(findings, previous)
    isnothing(previous) && return Finding[]
    known = Set(k.kind for k in previous)
    [f for f in findings if string(f.kind) in known && !(fingerprint(f) in previous)]
end

location(f::Finding) = isempty(f.symbol) ? f.file :
                       f.line > 0 ? "$(f.file):$(f.line):$(f.symbol)" : "$(f.file):$(f.symbol)"

function print_findings(io::IO, findings, severity)
    isempty(findings) && return println(io, "  no findings")
    by_mod = Dict{Symbol,Vector{Finding}}()
    for f in findings
        push!(get!(() -> Finding[], by_mod, f.mod), f)
    end
    for m in sort!(collect(keys(by_mod)))
        fs = by_mod[m]
        errors = count(f -> severity[f.kind] === :error, fs)
        println(io, "  $m: $(length(fs)) findings, $errors errors")
        for f in fs
            mark = severity[f.kind] === :error ? 'x' : ' '
            println(io, "    [$mark] $(f.kind)  $(location(f))  -  $(f.detail)")
            isempty(f.evidence) || println(io, "        ", render_evidence(f))
        end
    end
end

# The delta in full, the standing set as per-kind counts. Rank order so consecutive runs diff cleanly.
function print_architecture(io::IO, findings, new, fixed, rank, severity)
    standing = length(findings) - length(new)
    println(io, "\narchitecture   $(length(findings)) findings   ",
            "new $(length(new))   fixed $fixed   standing $standing")

    if !isempty(new)
        println(io, "\n  NEW")
        order(f) = (findfirst(==(severity[f.kind]), SEVERITIES), get(rank, f.mod, Int[]), string(f.kind), f.file,
                    f.symbol)
        for f in sort(new, by = order)
            mark = severity[f.kind] === :error ? "x" : " "
            owner = rpad(string(f.mod), 12)
            kind = rpad(string(f.kind), 16)
            println(io, "    [$mark] ", owner, kind, location(f), "  -  ", f.detail)
            isempty(f.evidence) || println(io, " "^24, render_evidence(f))
        end
    end

    for name in SEVERITIES
        held = Dict{Symbol,Int}()
        for f in findings
            severity[f.kind] === name || continue
            held[f.kind] = get(held, f.kind, 0) + 1
        end
        isempty(held) && continue
        counted = join(("$k $(held[k])" for k in sort!(collect(keys(held)), by = string)), "  ")
        println(io, "\n  standing $(rpad(name, 10)) ", counted)
    end
end
