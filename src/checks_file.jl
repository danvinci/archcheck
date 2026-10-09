# file adjacency from the call graph: file A -> file B when a function in A calls one in B.
# Edges leave the file the referencing METHOD lives in, not the name's home: one function's methods can sit
# in several files, and attributing them all to one would invent edges the calls never take.
function file_adjacency(cg::CallGraph)
    adj = Dict{String,Set{String}}()
    for ((name, from), callees) in cg.site_refs, g in callees
        g == name && continue
        to = get(cg.files, g, nothing)
        (isnothing(to) || to == from) && continue
        push!(get!(adj, from, Set{String}()), to)
    end
    adj
end

# The defs in file `from` that reference something in file `to` - who carries the edge.
function edge_carriers(cg::CallGraph, from, to)
    carriers = Symbol[]
    for ((name, file), callees) in cg.site_refs
        file == from || continue
        any(g -> g != name && get(cg.files, g, "") == to, callees) && push!(carriers, name)
    end
    sort!(unique!(carriers))
end

# file-backedge: the rank rule at file zoom, over the wrapper's include order. Subsumes cycle detection -
# a cycle over ranked files always contains an up-rank edge.
function check_file_backedges(cg::CallGraph)
    findings = Finding[]
    for (from, tos) in file_adjacency(cg), to in tos
        is_backedge(cg.rank, from, to) || continue
        carriers = edge_carriers(cg, from, to)
        evidence = [:include_order => "$(cg.rank[from])->$(cg.rank[to])",
                    :via => join(carriers, " ")]
        push!(findings, Finding(cg.mod, :file_backedge, from, to, 0,
                                "references a file the wrapper includes later", evidence))
    end
    findings
end

# tuple-return: a body ending in a bare tuple is a data layer that never got a type.
const TUPLE_SLOTS_MIN = 3

function check_tuple_returns(index)
    findings = Finding[]
    for f in index.files, (name, slots) in f.scan.tupletail
        slots >= TUPLE_SLOTS_MIN || continue
        line = f.scan.line[name]
        push!(findings, Finding(f.mod, :tuple_return, f.path, string(name), line,
                                "body ends in a bare tuple", [:slots => string(slots)]))
    end
    findings
end

# How many module files reference each file at all.
function file_reach(adj)
    reach = Dict{String,Int}()
    for pair in adj
        targets = pair.second
        for target in targets
            reach[target] = get(reach, target, 0) + 1
        end
    end
    reach
end

# Defs in a file that reference a name: (name, the file of the reference) -> count.
function caller_counts(cg)
    callers = Dict{Tuple{Symbol,String},Int}()
    for ((caller, file), callees) in cg.site_refs
        for callee in callees
            caller == callee && continue
            site = (callee, file)
            callers[site] = get(callers, site, 0) + 1
        end
    end
    callers
end

# A callee file more than half the module's files reach is shared vocabulary.
function is_shared_vocabulary(reach, target, nfiles)
    reached = get(reach, target, 0)
    2 * reached > nfiles
end

function sink_finding(cg, home, name, line, target, reach, nfiles, athome)
    reached = get(reach, target, 0)
    using_it = "$reached/$nfiles"
    evidence = [:callees_in => basename(target),
                :files_using_it => using_it,
                :callers_in_own_file => string(athome)]
    Finding(cg.mod, :file_sinkable, home, string(name), line,
            "every callee lives in one lower-ranked file", evidence)
end

function sink_verdict(cg, home, name, line, targets, reach, nfiles, callers)
    length(targets) == 1 || return nothing
    target = only(targets)
    target == home && return nothing
    is_downrank(cg.rank, home, target) || return nothing
    is_shared_vocabulary(reach, target, nfiles) && return nothing
    athome = get(callers, (name, home), 0)
    athome > 0 && return nothing
    sink_finding(cg, home, name, line, target, reach, nfiles, athome)
end

# file-sinkable: every intra-module callee lives in one lower-ranked file. The rank condition keeps this
# disjoint from file-backedge, which owns the up-rank direction.
function check_file_sinkable(cg::CallGraph, sites)
    adj = file_adjacency(cg)
    homes = unique(values(cg.files))
    nfiles = length(homes)
    reach = file_reach(adj)
    callers = caller_counts(cg)
    findings = Finding[]
    for name in cg.funcs
        callees = cg.calls[name]
        targets = String[]
        for callee in callees
            push!(targets, cg.files[callee])
        end
        unique!(targets)
        home = cg.files[name]
        located = site_of(sites, cg.mod, name, (home, 0))
        line = located[2]
        finding = sink_verdict(cg, home, name, line, targets, reach, nfiles, callers)
        isnothing(finding) || push!(findings, finding)
    end
    findings
end

function graph_methods(methods::MethodGraph)
    callers = Set{Method}()
    for caller in keys(methods.edges)
        push!(callers, caller)
    end
    for caller in keys(methods.unresolved)
        push!(callers, caller)
    end
    callers
end

# Methods of this module's functions, each at the file and line the loader recorded.
function judged_methods(cg, methods, repo)
    owned = Set(cg.funcs)
    judged = Tuple{Method,String,Int}[]
    for caller in graph_methods(methods)
        caller.name in owned || continue
        located = method_site(caller, repo)
        home = located[1]
        haskey(cg.rank, home) || continue
        line = located[2]
        push!(judged, (caller, home, line))
    end
    judged
end

function covered_names(judged)
    names = Set{Symbol}()
    for placed in judged
        caller = placed[1]
        push!(names, caller.name)
    end
    names
end

function add_unresolved_targets!(targets, cg, caller_name, pending)
    for called in pending
        called === caller_name && continue
        path = get(cg.files, called, nothing)
        isnothing(path) || push!(targets, path)
    end
end

# A callee with no top-level name is a closure. Its body's callee files belong to the caller.
function add_callee_target!(targets, cg, caller_name, callee, methods, repo, seen)
    if !haskey(cg.files, callee.name)
        add_body_targets!(targets, cg, caller_name, callee, methods, repo, seen)
        return
    end
    located = method_site(callee, repo)
    path = located[1]
    haskey(cg.rank, path) || return
    callee.name === caller_name && return
    push!(targets, path)
end

function add_body_targets!(targets, cg, caller_name, method, methods, repo, seen)
    method in seen && return
    push!(seen, method)
    callees = get(methods.edges, method, nothing)
    if !isnothing(callees)
        for callee in callees
            add_callee_target!(targets, cg, caller_name, callee, methods, repo, seen)
        end
    end
    pending = get(methods.unresolved, method, nothing)
    isnothing(pending) && return
    add_unresolved_targets!(targets, cg, caller_name, pending)
end

function add_method_targets!(targets, cg, method, methods, repo)
    caller_name = method.name
    seen = Set{Method}()
    add_body_targets!(targets, cg, caller_name, method, methods, repo, seen)
end

function method_findings(cg, methods, judged, repo)
    adj = file_adjacency(cg)
    home_files = collect(values(cg.files))
    distinct = unique(home_files)
    nfiles = length(distinct)
    reach = file_reach(adj)
    callers = caller_counts(cg)
    findings = Finding[]
    for placed in judged
        caller = placed[1]
        home = placed[2]
        line = placed[3]
        targets = Set{String}()
        add_method_targets!(targets, cg, caller, methods, repo)
        finding = sink_verdict(cg, home, caller.name, line, targets, reach, nfiles, callers)
        isnothing(finding) || push!(findings, finding)
    end
    findings
end

# With a method graph, each method is judged on the callees inference resolved for it.
# A function with no method in the graph keeps the name-level verdict.
function check_file_sinkable(cg::CallGraph, sites, methods::MethodGraph, repo)
    judged = judged_methods(cg, methods, repo)
    named = check_file_sinkable(cg, sites)
    per_method = method_findings(cg, methods, judged, repo)
    covered = covered_names(judged)
    kept = Finding[]
    for finding in named
        name = Symbol(finding.symbol)
        name in covered && continue
        push!(kept, finding)
    end
    append!(kept, per_method)
    kept
end

check_file_sinkable(cg::CallGraph, sites, ::Nothing, repo) = check_file_sinkable(cg, sites)

# extract-candidate: the density view of sinkable - a file holding several such defs.
const EXTRACT_DEFS_MIN = 3

function check_extract_candidates(sinkables; min_defs = EXTRACT_DEFS_MIN)
    byfile = Dict{String,Tuple{Symbol,Vector{String}}}()
    for f in sinkables
        (f.kind === :sinkable && !isempty(f.file)) || continue
        _, syms = get!(byfile, f.file, (f.mod, String[]))
        push!(syms, f.symbol)
    end
    [Finding(m, :extract_candidate, file, "", 0, "holds several defs that only touch lower-ranked modules",
             [:defs => string(length(syms)), :names => join(sort(syms), " ")])
     for (file, (m, syms)) in byfile if length(syms) >= min_defs]
end
