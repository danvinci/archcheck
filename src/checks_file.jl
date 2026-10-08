# file adjacency from the call graph: file A -> file B when a function in A calls one in B.
# Edges leave the file the referencing METHOD lives in, not the name's home: one function's methods can sit
# in several files, and attributing them all to one would invent edges the calls never take.
function file_adjacency(cg::CallGraph)
    adj = Dict{String,Set{String}}()
    for ((name, from), callees) in cg.site_refs, g in callees
        g == name && continue
        to = get(cg.files, g, nothing)
        (to === nothing || to == from) && continue
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

# file-sinkable: every intra-module callee lives in one lower-ranked file. The rank condition keeps this
# disjoint from file-backedge, which owns the up-rank direction.
function check_file_sinkable(cg::CallGraph, sites)
    adj = file_adjacency(cg)
    nfiles = length(unique(values(cg.files)))
    reach = Dict{String,Int}()                      # files that reference each file at all
    for (_, tos) in adj, to in tos
        reach[to] = get(reach, to, 0) + 1
    end
    callers = Dict{Tuple{Symbol,String},Int}()
    for ((caller, file), callees) in cg.site_refs, callee in callees
        caller == callee && continue
        site = (callee, file)
        callers[site] = get(callers, site, 0) + 1
    end
    findings = Finding[]
    for f in cg.funcs
        callees = cg.calls[f]
        isempty(callees) && continue
        targets = unique(cg.files[g] for g in callees)
        length(targets) == 1 || continue
        target = only(targets)
        home = cg.files[f]
        target == home && continue
        is_downrank(cg.rank, home, target) || continue
        reached = get(reach, target, 0)
        # more than half the module's files reach this one: shared vocabulary, wherever its callers sit
        2 * reached > nfiles && continue
        _, line = site_of(sites, cg.mod, f, (home, 0))
        athome = get(callers, (f, home), 0)
        athome > 0 && continue          # callers at home place it: what it calls does not move it
        evidence = [:callees_in => basename(target),
                    :files_using_it => "$(get(reach, target, 0))/$nfiles",
                    :callers_in_own_file => string(athome)]
        push!(findings, Finding(cg.mod, :file_sinkable, home, string(f), line,
                                "every callee lives in one lower-ranked file", evidence))
    end
    findings
end

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
