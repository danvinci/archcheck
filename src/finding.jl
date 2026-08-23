# Tiers, worst first. Enforce halts the run; structure is a broken invariant; advice is a suggestion.
const TIERS = (:enforce, :structure, :advice)

const ENFORCE_KINDS = (:unparsed, :missing_include, :nonliteral_include, :unranked_file, :back_edge, :cycle,
                       :duplicate_owner, :contracts_logic)

# Kinds that name a violated architectural invariant rather than a placement or style preference: an
# include order that is not a topological sort, a name nothing reaches.
const STRUCTURE_KINDS = (:file_backedge, :dead_code, :blanket_export, :stale_export, :reaches_internal)

function kind_tier(kind::Symbol)
    kind in ENFORCE_KINDS && return :enforce
    kind in STRUCTURE_KINDS && return :structure
    :advice
end

# One structural problem, owned by the module whose code carries it.
# Severity is set by the emitting check. Engine kinds default from the tuples above; a consumer
# kind has no seat there and must pass it or it is advice.
struct Finding
    mod::Symbol      # module the offending code lives in
    kind::Symbol     # the check that produced it
    file::String     # repo-relative path
    symbol::String   # offending name; "" when the finding is file-level
    line::Int        # source line; 0 when file/module-level
    detail::String   # what was observed
    evidence::Vector{Pair{Symbol,String}}   # measurements the reader weighs; data, never a verdict
    tier::Symbol     # :enforce | :structure | :advice
    function Finding(mod, kind, file, symbol, line::Integer, detail,
                     evidence::Vector{Pair{Symbol,String}}, tier::Symbol)
        tier in TIERS || throw(ArgumentError("finding tier must be one of $TIERS, got $tier"))
        new(mod, kind, file, symbol, Int(line), detail, evidence, tier)
    end
end
Finding(mod, kind, file, symbol, line::Integer, detail, evidence::Vector{Pair{Symbol,String}};
        tier::Symbol = kind_tier(kind)) =
    Finding(mod, kind, file, symbol, line, detail, evidence, tier)
Finding(mod, kind, file, symbol, line::Integer, detail; tier::Symbol = kind_tier(kind)) =
    Finding(mod, kind, file, symbol, line, detail, Pair{Symbol,String}[]; tier)
Finding(mod, kind, file, symbol, detail; tier::Symbol = kind_tier(kind)) =
    Finding(mod, kind, file, symbol, 0, detail; tier)

tier(kind::Symbol) = kind_tier(kind)
tier(f::Finding) = f.tier
tier_rank(f::Finding) = findfirst(==(tier(f)), TIERS)

isblocking(f::Finding) = tier(f) === :enforce

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

# One JSON object per line, greppable per module.
function emit_jsonl(io::IO, findings)
    for f in findings
        JSON.print(io, Dict("module" => string(f.mod), "kind" => string(f.kind),
                            "blocking" => isblocking(f), "tier" => string(f.tier),
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
    previous === nothing && return Finding[]
    known = Set(k.kind for k in previous)
    [f for f in findings if string(f.kind) in known && !(fingerprint(f) in previous)]
end

location(f::Finding) = isempty(f.symbol) ? f.file :
                       f.line > 0 ? "$(f.file):$(f.line):$(f.symbol)" : "$(f.file):$(f.symbol)"

function print_findings(io::IO, findings)
    isempty(findings) && return println(io, "  no findings")
    by_mod = Dict{Symbol,Vector{Finding}}()
    for f in findings
        push!(get!(() -> Finding[], by_mod, f.mod), f)
    end
    for m in sort!(collect(keys(by_mod)))
        fs = by_mod[m]
        println(io, "  $m: $(length(fs)) findings, $(count(isblocking, fs)) blocking")
        for f in fs
            println(io, "    [$(isblocking(f) ? 'x' : ' ')] $(f.kind)  $(location(f))  -  $(f.detail)")
            isempty(f.evidence) || println(io, "        ", render_evidence(f))
        end
    end
end

# The delta in full, the standing set as per-kind counts. Rank order so consecutive runs diff cleanly.
function print_architecture(io::IO, findings, new, fixed, rank)
    standing = length(findings) - length(new)
    println(io, "\narchitecture   $(length(findings)) findings   ",
            "new $(length(new))   fixed $fixed   standing $standing")

    if !isempty(new)
        println(io, "\n  NEW")
        for f in sort(new, by = f -> (tier_rank(f), get(rank, f.mod, 0), string(f.kind), f.file, f.symbol))
            mark = isblocking(f) ? "x" : " "
            owner = rpad(string(f.mod), 12)
            kind = rpad(string(f.kind), 16)
            println(io, "    [$mark] ", owner, kind, location(f), "  -  ", f.detail)
            isempty(f.evidence) || println(io, " "^24, render_evidence(f))
        end
    end

    for name in TIERS
        held = Dict{Symbol,Int}()
        for f in findings
            tier(f) === name || continue
            held[f.kind] = get(held, f.kind, 0) + 1
        end
        isempty(held) && continue
        counted = join(("$k $(held[k])" for k in sort!(collect(keys(held)), by = string)), "  ")
        println(io, "\n  standing $(rpad(name, 10)) ", counted)
    end
end
