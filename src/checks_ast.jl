# Checks over the static index: corpus, dead code, and the module-zoom rank rules.

# dead-code: a top-level def never appearing as a call site in src and not named in test/ or scripts/.
# JuliaSyntax sees closure-internal calls, so deck-wrapped functions are not dead.
function check_dead_code_static(index, external = index.external)
    defs = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()
    referenced = Set{Symbol}()
    for f in index.files
        for s in values(f.scan.refs)
            union!(referenced, s)
        end
        union!(referenced, f.scan.modrefs)
        for nm in f.scan.funcs
            defs[(f.mod, nm)] = (f.path, f.scan.line[nm])
        end
    end
    [Finding(m, :dead_code, file, string(nm), line, "no textual reference in src, test, or scripts")
     for ((m, nm), (file, line)) in defs if !(nm in referenced) && !(nm in external)]
end

# corpus: every .jl the tool touches is a ranked member, a module wrapper, or a hole. A hole makes the
# analysis silently incomplete, so it blocks.
function check_corpus(index)
    findings = Finding[]
    for (owner, path) in index.unparsed
        push!(findings, Finding(owner, :unparsed, path, "", 0, "could not be parsed"))
    end
    for (owner, from, spec, line) in index.missing
        push!(findings, Finding(owner, :missing_include, from, spec, line,
                                "include names a file that is not on disk"))
    end
    for f in index.files
        f.filerank == 0 || continue
        is_wrapper(f) && continue
        push!(findings, Finding(f.mod, :unranked_file, f.path, "", 0,
              "nothing in the module includes it, at any depth"))
    end
    findings
end

# Rank 0 = position never declared, so exempt from both rules below.
isranked(rank, a, b) = haskey(rank, a) && haskey(rank, b) && rank[a] > 0 && rank[b] > 0

# The rank rule, shared by both zooms; exhaustive over the ranked domain.
is_backedge(rank, from, to) = isranked(rank, from, to) && rank[to] >= rank[from]
is_downrank(rank, from, to) = isranked(rank, from, to) && rank[to] < rank[from]

# back-edge: any cross-module reference that does not point strictly down-rank.
check_backedges(g::ModuleGraph) =
    [Finding(r.from, :back_edge, r.file, string(r.to), r.line,
             "references a module the package spine includes at or after it",
             [:include_order => "$(g.rank[r.from])->$(g.rank[r.to])", :via => string(r.via)])
     for r in g.refs if is_backedge(g.rank, r.from, r.to)]

# DFS three-colour cycle detection; each cycle returned as its node loop.
function find_cycles(nodes, adj::AbstractDict)
    color = Dict(n => :white for n in nodes)
    stack = eltype(nodes)[]
    cycles = Vector{Vector{eltype(nodes)}}()
    function visit(u)
        color[u] = :gray; push!(stack, u)
        for v in get(adj, u, ())
            haskey(color, v) || continue
            if color[v] === :gray
                push!(cycles, stack[findlast(==(v), stack):end])
            elseif color[v] === :white
                visit(v)
            end
        end
        pop!(stack); color[u] = :black
    end
    for n in nodes
        color[n] === :white && visit(n)
    end
    cycles
end

# cycle at module zoom (a down-only graph is already acyclic).
function check_cycles(g::ModuleGraph)
    adj = Dict{Symbol,Vector{Symbol}}()
    for r in g.refs
        push!(get!(adj, r.from, Symbol[]), r.to)
    end
    [Finding(first(c), :cycle, "", "", 0, "the module graph is not a DAG",
             [:loop => join(string.(c), "->") * "->" * string(first(c))])
     for c in find_cycles(collect(keys(g.rank)), adj)]
end

# A contracts/ function is type surface, not logic, when it is an outer constructor (name is a contract
# type) or dispatches purely over contract types (an accessor). Anything mixing in a raw or domain type,
# or taking no argument, computes something and belongs in a domain module.
is_type_interface(n, argtypes, ctypes) =
    n in ctypes ||
    (haskey(argtypes, n) && !isempty(argtypes[n]) && all(t -> t !== nothing && t in ctypes, argtypes[n]))

function check_contracts_logic(index)
    files = files_of(index, :Contracts)
    ctypes = Set{Symbol}(t for f in files for t in f.scan.types)   # every type across the contracts dir
    findings = Finding[]
    for f in files, name in unique(f.scan.funcs)
        is_type_interface(name, f.scan.argtypes, ctypes) && continue
        line = f.scan.line[name]
        push!(findings, Finding(:Contracts, :contracts_logic, f.path, string(name), line,
                                "a function in contracts/, which holds types only"))
    end
    findings
end
