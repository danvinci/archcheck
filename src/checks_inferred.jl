# Calls the method graph's own inference judges: one no method can take, and a pure value the code drops.

"""Configured through `gate(...; checks)`, and the gate needs `entries`. A call no method matches at any argument type
inference allows, or a discarded call that writes nothing, cannot throw and returns a value at every argument its
method accepts."""
struct InferredCalls <: Check end

kinds(::InferredCalls) = (:failing_call => :advisory, :dropped_value => :advisory)
phase(::InferredCalls) = :graph

function run(::InferredCalls, ctx)
    graph = ctx.methods
    isnothing(graph) && throw(ArgumentError("InferredCalls needs entries"))
    recorded = ctx.recorded
    discarded = discarded_calls(ctx.index)
    findings = Finding[]
    for (caller, facts) in graph.calls
        for fact in facts
            path = fact_path(fact, recorded)
            if is_reported_failure(fact)
                push!(findings, failing_finding(caller, fact, path))
            end
            site = get(discarded, (path, fact.line, fact.callee), nothing)
            isnothing(site) && continue
            is_dropped_value(fact) || continue
            push!(findings, dropped_finding(caller, fact, path, site))
        end
    end
    sort!(findings, by = finding -> (finding.file, finding.line, finding.symbol, finding.kind))
end

# Each call the parse reads as discarded, by file, line and callee.
function discarded_calls(index)
    found = Dict{Tuple{String,Int,Symbol},CallSite}()
    for file in index.files
        for calls in values(file.scan.callsites)
            for call in calls
                call.is_used && continue
                key = (file.path, call.line, call.callee)
                haskey(found, key) && continue
                found[key] = call
            end
        end
    end
    found
end

# A stub with no method is an interface a user's type completes; a keyword forward fails only when a caller passes
# keywords the callee takes none of.
is_reported_failure(fact::CallFact) = fact.is_failing && !fact.is_stub && !fact.is_forward

# A generated callee runs its generator on the call, the one effect its bits leave out.
function is_dropped_value(fact::CallFact)
    fact.is_used && return false
    fact.is_effect_free || return false
    fact.is_nothrow || return false
    fact.is_value || return false
    !fact.is_generated
end

function failing_finding(caller::Method, fact::CallFact, path)
    symbol = written_name(caller.name)
    signature = Base.isdispatchtuple(caller.sig) ? "concrete" : "abstract"
    via = string(fact.via)
    callee = string(fact.callee)
    evidence = [:callee => callee, :failing => fact.failing, :via => via, :signature => signature]
    detail = "no method matches the call at any argument type inference allows"
    owner = module_key(caller.module)
    Finding(owner, :failing_call, path, symbol, fact.line, detail, evidence)
end

function dropped_finding(caller::Method, fact::CallFact, path, site::CallSite)
    symbol = written_name(caller.name)
    text = call_text(site)
    effects = effects_text(fact)
    evidence = [:calls => text, :effects => effects, :returns => fact.returns]
    detail = "the call's value is dropped, and the call writes nothing and cannot throw"
    owner = module_key(caller.module)
    Finding(owner, :dropped_value, path, symbol, fact.line, detail, evidence)
end
