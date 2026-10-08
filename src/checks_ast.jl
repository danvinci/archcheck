# Checks over the static index: corpus, dead code, and the module-zoom rank rules.

# Names an `export` or `public` statement lists. Those lines are declarations, so the def walk skips them.
function collect_published!(names, node)
    kids = child_nodes(node)
    kids === nothing && return
    k = JS.kind(node)
    k == K"quote" && return
    if k == K"export" || k == K"public"
        for child in kids
            child.val isa Symbol && push!(names, child.val)
        end
        return
    end
    for child in kids
        collect_published!(names, child)
    end
end

function published_names(index)
    names = Set{Symbol}()
    for file in index.files
        collect_published!(names, file.tree)
    end
    names
end

function dead_code_findings(index, entries)
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
    [Finding(m, :dead_code, file, string(nm), line, "no reference in src or scripts")
     for ((m, nm), (file, line)) in defs if !(nm in referenced) && !(nm in entries)]
end

# dead-code: a top-level def with no call site in src and not named in scripts/.
# JuliaSyntax sees closure-internal calls, so deck-wrapped functions are not dead.
function check_dead_code_static(index; public_is_entry::Bool = false)
    entries = index.external
    if public_is_entry
        entries = union(index.external, published_names(index))
    end
    dead_code_findings(index, entries)
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
    for (owner, from, line) in index.nonliteral
        push!(findings, Finding(owner, :nonliteral_include, from, "", line,
                                "include argument is not a string literal"))
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
is_placed(position::Integer) = position > 0
is_placed(path::AbstractVector{<:Integer}) = !isempty(path) && all(>(0), path)
function isranked(rank, a, b)
    haskey(rank, a) && haskey(rank, b) || return false
    is_placed(rank[a]) && is_placed(rank[b])
end

# Load order, the one comparison both zooms make: `a` finishes loading strictly before `b`. A module rank
# orders siblings by their wrapper's include order and puts a module after everything nested in it.
completes_before(a::Integer, b::Integer) = a < b
function completes_before(a::AbstractVector{<:Integer}, b::AbstractVector{<:Integer})
    for (x, y) in zip(a, b)
        x == y || return x < y
    end
    length(a) > length(b)
end

# The rank rule, shared by both zooms; exhaustive over the ranked domain.
is_backedge(rank, from, to) = isranked(rank, from, to) && !completes_before(rank[to], rank[from])
is_downrank(rank, from, to) = isranked(rank, from, to) && completes_before(rank[to], rank[from])

# back-edge: any cross-module reference whose target does not finish loading strictly before its source.
function check_backedges(g::ModuleGraph)
    findings = Finding[]
    for r in g.refs
        is_backedge(g.rank, r.from, r.to) || continue
        order = join(g.rank[r.from], ".") * "->" * join(g.rank[r.to], ".")
        evidence = [:include_order => order, :via => string(r.via)]
        target = string(r.to)
        detail = "references a module that finishes loading at or after it"
        push!(findings, Finding(r.from, :back_edge, r.file, target, r.line, detail, evidence))
    end
    findings
end

# Index of `node` on `stack`; a gray node sits on it.
function cycle_start(stack, node)
    index = lastindex(stack)
    while index >= firstindex(stack)
        stack[index] === node && return index
        index -= 1
    end
    firstindex(stack)
end

function walk_cycle!(color, stack, cycles, adj, node)
    color[node] = :gray
    push!(stack, node)
    for next in get(adj, node, ())
        haskey(color, next) || continue
        if color[next] === :gray
            start = cycle_start(stack, next)
            loop = stack[start:end]
            push!(cycles, loop)
        elseif color[next] === :white
            walk_cycle!(color, stack, cycles, adj, next)
        end
    end
    pop!(stack)
    color[node] = :black
    return
end

# DFS three-colour cycle detection; each cycle returned as its node loop.
function find_cycles(nodes, adj::AbstractDict)
    color = Dict(n => :white for n in nodes)
    stack = eltype(nodes)[]
    cycles = Vector{Vector{eltype(nodes)}}()
    for node in nodes
        color[node] === :white || continue
        walk_cycle!(color, stack, cycles, adj, node)
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

# Whether module `key` is `owner` or nested in it, by dotted key.
function is_within_module(key::Symbol, owner::Symbol)
    key === owner && return true
    prefix = string(owner, ".")
    startswith(string(key), prefix)
end

# sibling-edge: a reference from one member of the set, or a module nested in it, to another member's tree.
function check_independent(g::ModuleGraph, modules)
    for mod in modules
        haskey(g.rank, mod) || throw(ArgumentError("Independent names $mod, which the module graph does not rank"))
    end
    findings = Finding[]
    for r in g.refs
        source = findfirst(mod -> is_within_module(r.from, mod), modules)
        target = findfirst(mod -> is_within_module(r.to, mod), modules)
        (isnothing(source) || isnothing(target) || source == target) && continue
        from_member = modules[source]
        to_member = modules[target]
        evidence = [:from => string(from_member), :to => string(to_member), :via => string(r.via)]
        reached = string(r.to)
        detail = "references a module the independence set keeps apart from it"
        push!(findings, Finding(r.from, :sibling_edge, r.file, reached, r.line, detail, evidence))
    end
    findings
end

# A contracts/ function is type surface, not logic, when it is an outer constructor (name is a contract
# type) or dispatches purely over contract types (an accessor). Anything mixing in a raw or domain type,
# or taking no argument, computes something and belongs in a domain module.
is_type_interface(n, argtypes, ctypes) =
    n in ctypes ||
    (haskey(argtypes, n) && !isempty(argtypes[n]) && all(t -> t !== nothing && t in ctypes, argtypes[n]))

# The package's contracts module: seam types and their intrinsic interface, read field by field across modules.
const CONTRACTS_MODULE = :Contracts

function check_contracts_logic(index)
    files = files_of(index, CONTRACTS_MODULE)
    ctypes = Set{Symbol}(t for f in files for t in f.scan.types)   # every type across the contracts dir
    findings = Finding[]
    for f in files, name in unique(f.scan.funcs)
        is_type_interface(name, f.scan.argtypes, ctypes) && continue
        line = f.scan.line[name]
        push!(findings, Finding(CONTRACTS_MODULE, :contracts_logic, f.path, string(name), line,
                                "a function in contracts/, which holds types only"))
    end
    findings
end

# Literal uniform grids with module constants or single-assignment local counts.
# Counts produced by calls or reassigned bindings require separate analysis.
function scan_integer(node, bindings)
    node.val isa Int && return node.val
    node.val isa Symbol && return get(bindings, node.val, nothing)
    operation = infix_op(node)
    operation in (:+, :-) || return nothing
    children = child_nodes(node)
    left = scan_integer(children[1], bindings)
    right = scan_integer(children[3], bindings)
    (isnothing(left) || isnothing(right)) && return nothing
    operation === :+ ? left + right : left - right
end

function scan_grids(nodes, bindings)
    stops = Dict{Int,Int}()
    divisors = Set{Int}()
    lengths = Dict{Int,Int}()
    for node in nodes
        JS.kind(node) in (K"call", K"dotcall") || continue
        children = child_nodes(node)
        line = Int(JS.source_location(node)[1])
        if length(children) == 3 && children[2].val === :(:)
            children[1].val in (0, 1) || continue
            count = scan_integer(children[3], bindings)
            isnothing(count) && continue
            stops[count] = get(stops, count, line)
        elseif length(children) == 3 && children[2].val === :/
            count = scan_integer(children[3], bindings)
            isnothing(count) || push!(divisors, count)
        elseif children[1].val in (:range, :LinRange)
            arguments = call_args(node)
            positional = filter(arg -> JS.kind(arg) != K"=", arguments)
            length(positional) >= 2 || continue
            count = length(positional) == 3 ? scan_integer(positional[3], bindings) : nothing
            for child in children
                options = JS.kind(child) == K"parameters" ? child_nodes(child) : (child,)
                for option in options
                    JS.kind(option) == K"=" || continue
                    pair = child_nodes(option)
                    pair[1].val === :length || continue
                    count = scan_integer(pair[2], bindings)
                end
            end
            isnothing(count) || (lengths[count] = line)
        end
    end
    for count in divisors
        if haskey(stops, count)
            lengths[count] = stops[count]
        elseif haskey(stops, count - 1)
            lengths[count] = stops[count - 1]
        end
    end
    lengths
end

function check_scan_seeds(index::SourceIndex; directories)
    files = filter(index.files) do file
        any(directories) do directory
            path = joinpath(index.repo, file.path)
            root = joinpath(index.repo, directory)
            is_within(path, root)
        end
    end
    groups = Dict{String,Dict{Symbol,Vector{JS.SyntaxNode}}}()
    constants = Dict{Symbol,Dict{Symbol,Int}}()
    for file in files
        path = joinpath(index.repo, file.path)
        tree = parse_file(read(path, String), file.path)
        isnothing(tree) && continue
        owners = Dict{Symbol,Vector{JS.SyntaxNode}}()
        module_constants = get!(Dict{Symbol,Int}, constants, file.mod)
        walk_with_enclosing(tree) do node, owner
            owner_nodes = get!(Vector{JS.SyntaxNode}, owners, owner)
            push!(owner_nodes, node)
            isempty(string(owner)) && JS.kind(node) == K"const" || return
            for assignment in child_nodes(node)
                JS.kind(assignment) == K"=" || continue
                pair = child_nodes(assignment)
                name = pair[1].val
                value = pair[2].val
                name isa Symbol && value isa Int || continue
                module_constants[name] = value
            end
        end
        groups[file.path] = owners
    end
    findings = Finding[]
    for file in files
        haskey(groups, file.path) || continue
        for (owner, nodes) in groups[file.path]
            isempty(string(owner)) && continue
            bindings = copy(constants[file.mod])
            assigned = Set{Symbol}()
            blocked = Set{Symbol}()
            for node in nodes
                if JS.kind(node) == K"call" && sig_name(node) === owner
                    union!(blocked, sig_argnames(node))
                elseif JS.kind(node) == K"="
                    pair = child_nodes(node)
                    name = pair[1].val
                    name isa Symbol || continue
                    value = pair[2].val
                    if name in assigned || !(value isa Int)
                        push!(blocked, name)
                    else
                        bindings[name] = value
                    end
                    push!(assigned, name)
                end
            end
            foreach(name -> delete!(bindings, name), blocked)
            grids = scan_grids(nodes, bindings)
            isempty(grids) && continue
            counts = sort!(collect(keys(grids)))
            evidence = [:samples => join(counts, ", ")]
            detail = "fixed integer counts form a uniform parameter grid"
            line = minimum(values(grids))
            symbol = string(owner)
            finding = Finding(file.mod, :scan_seed, file.path, symbol, line, detail, evidence)
            push!(findings, finding)
        end
    end
    sort!(findings, by = finding -> (finding.file, finding.line, finding.symbol))
end
