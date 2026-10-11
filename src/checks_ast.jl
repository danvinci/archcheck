# Checks over the static index: corpus, dead code, module rank, and contracts purity.

# Names an `export` or `public` statement lists. Those lines are declarations, so the def walk skips them.
function collect_published!(names, node)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    kind == K"quote" && return
    if kind == K"export" || kind == K"public"
        for child in children
            if child.val isa Symbol
                push!(names, child.val)
            end
        end
        return
    end
    for child in children
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

# Each definition form's name -> the lines it starts on, nested forms included.
function form_lines(scan::FileScan)
    lines = Dict{Symbol,Vector{Int}}()
    for site in keys(scan.forms)
        push!(get!(Vector{Int}, lines, site.name), site.line)
    end
    lines
end

# Whether a loaded method at one of `starts` in `path` adds to the package's own function `name`.
function defines_own_function(owned, path, starts, name)
    for line in starts
        added = get(owned, (path, line), nothing)
        isnothing(added) && continue
        name in added && return true
    end
    false
end

# A form is judged only when a loaded method at its line adds to the package's own function of its name; an alias
# to another module's function, a macro's rewrite or an unloaded extension adds none, so what it reads stays a root.
function judged_defs(index, owned)
    defs = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()
    for file in index.files
        lines = form_lines(file.scan)
        for name in file.scan.funcs
            name in file.scan.constructors && continue
            starts = get(lines, name, Int[])
            defines_own_function(owned, file.path, starts, name) || continue
            line = file.scan.line[name]
            defs[(file.mod, name)] = (file.path, line)
        end
    end
    defs
end

# Each name a definition's code reads, by the definition's name, merged over its methods and modules.
function name_edges(index)
    edges = Dict{Symbol,Set{Symbol}}()
    for file in index.files, (name, used) in file.scan.refs
        targets = get!(Set{Symbol}, edges, name)
        union!(targets, used)
    end
    edges
end

# The entries, every name read outside a function (an import, a top-level call, a macro's body, a type's own
# name), and code keyed by a name no judged function holds: a method on another module's function, a type's members.
function name_roots(index, edges, judged, entries)
    roots = Set{Symbol}(entries)
    for file in index.files
        union!(roots, file.scan.modrefs)
    end
    for name in keys(edges)
        name in judged || push!(roots, name)
    end
    roots
end

# Every name the roots reach by following what each reached definition reads.
function reached_names(edges, roots)
    reached = Set{Symbol}()
    pending = collect(roots)
    while !isempty(pending)   # unbounded: each name enters `reached` once, so the walk ends
        name = pop!(pending)
        name in reached && continue
        push!(reached, name)
        targets = get(edges, name, ())
        for target in targets
            target in reached || push!(pending, target)
        end
    end
    reached
end

# Each unreached judged name -> the unreached definitions that read it. A root reads nothing unreached.
function dead_readers(edges, reached, judged)
    readers = Dict{Symbol,Vector{Symbol}}()
    for (name, used) in edges
        name in reached && continue
        for target in used
            target in judged || continue
            target in reached && continue
            push!(get!(Vector{Symbol}, readers, target), name)
        end
    end
    readers
end

function dead_code_findings(index, entries, owned)
    defs = judged_defs(index, owned)
    judged = Set(last(key) for key in keys(defs))
    edges = name_edges(index)
    roots = name_roots(index, edges, judged, entries)
    reached = reached_names(edges, roots)
    readers = dead_readers(edges, reached, judged)
    findings = Finding[]
    for ((mod, name), (file, line)) in defs
        name in reached && continue
        symbol = string(name)
        if haskey(readers, name)
            names = sort!(string.(readers[name]))
            evidence = [:named_by => join(names, ",")]
            detail = "only dead definitions name it"
            push!(findings, Finding(mod, :dead_code, file, symbol, line, detail, evidence))
        else
            detail = "no reference in src or scripts"
            push!(findings, Finding(mod, :dead_code, file, symbol, line, detail))
        end
    end
    findings
end

# Julia calls a module's `__init__` when it loads, so its definition needs no source reference.
const RUNTIME_ENTRIES = (:__init__,)

# A top-level function no root reaches through names, cycles included. A loaded module's `names` holds what its
# load exported or declared public, as an `@eval export` loop does, beside the lists the parse reads.
function check_dead_code_static(index, modules, owned; public_is_entry::Bool)
    entries = union(index.external, RUNTIME_ENTRIES)
    if public_is_entry
        published = published_names(index)
        union!(entries, published)
        for mod in modules
            loaded = names(mod)
            union!(entries, loaded)
        end
    end
    dead_code_findings(index, entries, owned)
end

# Every .jl the tool touches is a ranked member, a module wrapper, or a hole.
# A hole makes the analysis silently incomplete, so it blocks.
function check_corpus(index)
    findings = Finding[]
    for (owner, path) in index.unparsed
        push!(findings, Finding(owner, :unparsed, path, "", 0, "could not be parsed"))
    end
    for (owner, from, spec, line) in index.missing
        detail = "include names a file that is not on disk"
        push!(findings, Finding(owner, :missing_include, from, spec, line, detail))
    end
    for (owner, from, line) in index.nonliteral
        detail = "include argument is not a string literal"
        push!(findings, Finding(owner, :nonliteral_include, from, "", line, detail))
    end
    for file in index.files
        file.filerank == 0 || continue
        is_wrapper(file) && continue
        detail = "nothing in the module includes it, at any depth"
        push!(findings, Finding(file.mod, :unranked_file, file.path, "", 0, detail))
    end
    findings
end

# Rank 0 means the position was left unset, so both rules below skip it.
is_placed(position::Integer) = position > 0

function is_placed(path::AbstractVector{<:Integer})
    isempty(path) && return false
    all(>(0), path)
end

function isranked(rank, left, right)
    haskey(rank, left) || return false
    haskey(rank, right) || return false
    left_rank = rank[left]
    right_rank = rank[right]
    is_placed(left_rank) && is_placed(right_rank)
end

# Load order, the one comparison both zooms make: left finishes loading strictly before right.
# A module rank orders siblings by their wrapper's include order and puts a module after everything nested in it.
completes_before(left::Integer, right::Integer) = left < right

function completes_before(left::AbstractVector{<:Integer}, right::AbstractVector{<:Integer})
    for (left_part, right_part) in zip(left, right)
        if left_part != right_part
            return left_part < right_part
        end
    end
    length(left) > length(right)
end

# The rank rule, shared by both zooms; exhaustive over the ranked domain.
function is_backedge(rank, from, to)
    isranked(rank, from, to) || return false
    target = rank[to]
    source = rank[from]
    !completes_before(target, source)
end

function is_downrank(rank, from, to)
    isranked(rank, from, to) || return false
    target = rank[to]
    source = rank[from]
    completes_before(target, source)
end

# A module reaching one that encloses it: the root encloses every module, and a dotted key encloses those below it.
function reaches_enclosing(ref::ModRef, root::Symbol)
    ref.to === root && return true
    is_within_module(ref.from, ref.to)
end

# The references the layering rules judge. A package may let its modules use what encloses them; `strict` holds
# every module to the layering.
function layered_refs(index, root::Symbol, strict::Bool)
    strict && return index.refs
    filter(ref -> !reaches_enclosing(ref, root), index.refs)
end

# Any cross-module reference whose target does not finish loading strictly before its source.
function check_backedges(index, root::Symbol; strict::Bool)
    findings = Finding[]
    for ref in layered_refs(index, root, strict)
        is_backedge(index.rank, ref.from, ref.to) || continue
        from_rank = index.rank[ref.from]
        to_rank = index.rank[ref.to]
        from_text = join(from_rank, ".")
        to_text = join(to_rank, ".")
        order = from_text * "->" * to_text
        via = string(ref.via)
        evidence = [:include_order => order, :via => via]
        target = string(ref.to)
        detail = "references a module that finishes loading at or after it"
        finding = Finding(ref.from, :back_edge, ref.file, target, ref.line, detail, evidence)
        push!(findings, finding)
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

function walk_cycle!(color, stack, cycles, adjacent, node)
    color[node] = :gray
    push!(stack, node)
    for successor in get(adjacent, node, ())
        haskey(color, successor) || continue
        if color[successor] === :gray
            start = cycle_start(stack, successor)
            loop = stack[start:end]
            push!(cycles, loop)
        elseif color[successor] === :white
            walk_cycle!(color, stack, cycles, adjacent, successor)
        end
    end
    pop!(stack)
    color[node] = :black
    return
end

# Three-colour cycle detection; each cycle returned as its node loop.
function find_cycles(nodes, adjacent::AbstractDict)
    color = Dict(node => :white for node in nodes)
    node_type = eltype(nodes)
    stack = node_type[]
    cycles = Vector{Vector{node_type}}()
    for node in nodes
        color[node] === :white || continue
        walk_cycle!(color, stack, cycles, adjacent, node)
    end
    cycles
end

# A cycle at module zoom. A down-only graph is already acyclic.
function check_cycles(index, root::Symbol; strict::Bool)
    adjacent = Dict{Symbol,Vector{Symbol}}()
    for ref in layered_refs(index, root, strict)
        targets = get!(adjacent, ref.from, Symbol[])
        push!(targets, ref.to)
    end
    nodes = collect(keys(index.rank))
    loops = find_cycles(nodes, adjacent)
    findings = Finding[]
    for loop in loops
        names = string.(loop)
        joined = join(names, "->")
        head = string(first(loop))
        closed = joined * "->" * head
        evidence = [:loop => closed]
        detail = "the module graph is not a DAG"
        finding = Finding(first(loop), :cycle, "", "", 0, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# Whether module `key` is `owner` or nested in it, by dotted key.
function is_within_module(key::Symbol, owner::Symbol)
    key === owner && return true
    prefix = string(owner, ".")
    text = string(key)
    startswith(text, prefix)
end

# A reference from one member of the set, or a module nested in it, to another member's tree.
function check_independent(index, modules)
    for mod in modules
        if !haskey(index.rank, mod)
            throw(ArgumentError("Independent names $mod, which the module graph does not rank"))
        end
    end
    findings = Finding[]
    for ref in index.refs
        source_at = findfirst(member -> is_within_module(ref.from, member), modules)
        target_at = findfirst(member -> is_within_module(ref.to, member), modules)
        isnothing(source_at) && continue
        isnothing(target_at) && continue
        source_at == target_at && continue
        from_member = modules[source_at]
        to_member = modules[target_at]
        from_text = string(from_member)
        to_text = string(to_member)
        via = string(ref.via)
        evidence = [:from => from_text, :to => to_text, :via => via]
        reached = string(ref.to)
        detail = "references a module the independence set keeps apart from it"
        finding = Finding(ref.from, :sibling_edge, ref.file, reached, ref.line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# Type surface: an outer constructor whose name is a contract type, or an accessor over contract types only.
# A raw or domain argument, or no argument, computes and belongs in a domain module.
function is_type_interface(name, argtypes, contract_types)
    name in contract_types && return true
    haskey(argtypes, name) || return false
    types = argtypes[name]
    isempty(types) && return false
    all(type -> !isnothing(type) && type in contract_types, types)
end

# The package's contracts module: seam types and their intrinsic interface, read field by field across modules.
const CONTRACTS_MODULE = :Contracts

function check_contracts_logic(index)
    files = files_of(index, CONTRACTS_MODULE)
    contract_types = Set{Symbol}()
    for file in files
        for type_name in file.scan.types
            push!(contract_types, type_name)
        end
    end
    findings = Finding[]
    for file in files
        names = unique(file.scan.funcs)
        for name in names
            is_type_interface(name, file.scan.argtypes, contract_types) && continue
            line = file.scan.line[name]
            symbol = string(name)
            detail = "a function in contracts/, which holds types only"
            finding = Finding(CONTRACTS_MODULE, :contracts_logic, file.path, symbol, line, detail)
            push!(findings, finding)
        end
    end
    findings
end
