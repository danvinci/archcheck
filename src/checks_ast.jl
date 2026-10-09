# Checks over the static index: corpus, dead code, and the module-zoom rank rules.

# Names an `export` or `public` statement lists. Those lines are declarations, so the def walk skips them.
function collect_published!(names, node)
    kids = child_nodes(node)
    isnothing(kids) && return
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
    (haskey(argtypes, n) && !isempty(argtypes[n]) && all(t -> !isnothing(t) && t in ctypes, argtypes[n]))

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

function is_index_colon(children)
    length(children) == 3 || return false
    children[2].val === :(:) || return false
    children[1].val in (0, 1)
end

function is_division(children)
    length(children) == 3 || return false
    children[2].val === :/
end

function record_stop!(stops, children, bindings, line)
    count = scan_integer(children[3], bindings)
    isnothing(count) && return
    known = get(stops, count, line)
    stops[count] = known
end

function record_divisor!(divisors, children, bindings)
    count = scan_integer(children[3], bindings)
    isnothing(count) && return
    push!(divisors, count)
end

# Arguments after the callee, keywords written as `name = value` left out.
function counted_arguments(node)
    arguments = call_args(node)
    counted = JS.SyntaxNode[]
    for argument in arguments
        JS.kind(argument) == K"=" && continue
        push!(counted, argument)
    end
    counted
end

function option_nodes(child)
    JS.kind(child) == K"parameters" || return (child,)
    child_nodes(child)
end

function keyword_length(count, child, bindings)
    for option in option_nodes(child)
        JS.kind(option) == K"=" || continue
        pair = child_nodes(option)
        pair[1].val === :length || continue
        count = scan_integer(pair[2], bindings)
    end
    count
end

function range_length(node, children, bindings)
    positional = counted_arguments(node)
    length(positional) >= 2 || return nothing
    count = nothing
    if length(positional) == 3
        count = scan_integer(positional[3], bindings)
    end
    for child in children
        count = keyword_length(count, child, bindings)
    end
    count
end

function record_range!(lengths, node, children, bindings, line)
    children[1].val in (:range, :LinRange) || return
    count = range_length(node, children, bindings)
    isnothing(count) && return
    lengths[count] = line
end

function record_grid!(stops, divisors, lengths, node, bindings)
    kind = JS.kind(node)
    kind == K"call" || kind == K"dotcall" || return
    children = child_nodes(node)
    location = JS.source_location(node)
    line = Int(location[1])
    if is_index_colon(children)
        record_stop!(stops, children, bindings, line)
        return
    end
    if is_division(children)
        record_divisor!(divisors, children, bindings)
        return
    end
    record_range!(lengths, node, children, bindings, line)
end

function fold_divisors!(lengths, stops, divisors)
    for count in divisors
        if haskey(stops, count)
            lengths[count] = stops[count]
        elseif haskey(stops, count - 1)
            lengths[count] = stops[count - 1]
        end
    end
end

function scan_grids(nodes, bindings)
    stops = Dict{Int,Int}()
    divisors = Set{Int}()
    lengths = Dict{Int,Int}()
    for node in nodes
        record_grid!(stops, divisors, lengths, node, bindings)
    end
    fold_divisors!(lengths, stops, divisors)
    lengths
end

function is_seed_file(index, file, directories)
    path = joinpath(index.repo, file.path)
    for directory in directories
        root = joinpath(index.repo, directory)
        is_within(path, root) && return true
    end
    false
end

function seed_files(index, directories)
    files = FileNode[]
    for file in index.files
        is_seed_file(index, file, directories) && push!(files, file)
    end
    files
end

function record_module_constant!(constants, node, owner)
    owner_name = string(owner)
    isempty(owner_name) || return
    JS.kind(node) == K"const" || return
    for assignment in child_nodes(node)
        JS.kind(assignment) == K"=" || continue
        pair = child_nodes(assignment)
        name = pair[1].val
        value = pair[2].val
        name isa Symbol || continue
        value isa Int || continue
        constants[name] = value
    end
end

function record_seed_node!(owners, constants, node, owner)
    nodes = get!(Vector{JS.SyntaxNode}, owners, owner)
    push!(nodes, node)
    record_module_constant!(constants, node, owner)
end

function collect_file_seeds!(groups, constants, file)
    owners = Dict{Symbol,Vector{JS.SyntaxNode}}()
    module_constants = get!(Dict{Symbol,Int}, constants, file.mod)
    walk_with_enclosing(file.tree) do node, owner
        record_seed_node!(owners, module_constants, node, owner)
    end
    groups[file.path] = owners
end

function seed_tables(files)
    groups = Dict{String,Dict{Symbol,Vector{JS.SyntaxNode}}}()
    constants = Dict{Symbol,Dict{Symbol,Int}}()
    for file in files
        collect_file_seeds!(groups, constants, file)
    end
    groups, constants
end

function record_assignment!(bindings, assigned, blocked, node)
    pair = child_nodes(node)
    name = pair[1].val
    name isa Symbol || return
    value = pair[2].val
    if name in assigned || !(value isa Int)
        push!(blocked, name)
    else
        bindings[name] = value
    end
    push!(assigned, name)
end

function record_binding!(bindings, assigned, blocked, node, owner)
    if JS.kind(node) == K"call" && sig_name(node) === owner
        names = sig_argnames(node)
        union!(blocked, names)
        return
    end
    JS.kind(node) == K"=" || return
    record_assignment!(bindings, assigned, blocked, node)
end

function method_bindings(nodes, owner, module_constants)
    bindings = copy(module_constants)
    assigned = Set{Symbol}()
    blocked = Set{Symbol}()
    for node in nodes
        record_binding!(bindings, assigned, blocked, node, owner)
    end
    for name in blocked
        delete!(bindings, name)
    end
    bindings
end

function grid_finding(file, owner, nodes, module_constants)
    owner_name = string(owner)
    isempty(owner_name) && return nothing
    bindings = method_bindings(nodes, owner, module_constants)
    grids = scan_grids(nodes, bindings)
    isempty(grids) && return nothing
    counts = collect(keys(grids))
    sort!(counts)
    samples = join(counts, ", ")
    evidence = [:samples => samples]
    detail = "fixed integer counts form a uniform parameter grid"
    line = minimum(values(grids))
    Finding(file.mod, :scan_seed, file.path, owner_name, line, detail, evidence)
end

function seed_findings(file, groups, constants)
    findings = Finding[]
    haskey(groups, file.path) || return findings
    owners = groups[file.path]
    module_constants = constants[file.mod]
    for (owner, nodes) in owners
        finding = grid_finding(file, owner, nodes, module_constants)
        isnothing(finding) || push!(findings, finding)
    end
    findings
end

function finding_before(left, right)
    if left.file != right.file
        return left.file < right.file
    end
    if left.line != right.line
        return left.line < right.line
    end
    left.symbol < right.symbol
end

function check_scan_seeds(index::SourceIndex; directories)
    files = seed_files(index, directories)
    groups, constants = seed_tables(files)
    findings = Finding[]
    for file in files
        append!(findings, seed_findings(file, groups, constants))
    end
    sort!(findings, lt = finding_before)
end
