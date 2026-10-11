# Expression clones: one syntax tree, locals renamed in order of appearance.

"""Runs in `CHECKS`. The same expression, with locals renamed in order of appearance, is written in two or more methods."""
Base.@kwdef struct ExpressionClones <: Check
    min_nodes::Int = 20   # smallest subtree that can form a group, in syntax nodes
end

kinds(::ExpressionClones) = (:expression_clone => :advisory,)

const MIX_SALT = 0x9e3779b97f4a7c15

struct CloneDigest
    primary::UInt64     # first 64-bit mix of this subtree
    secondary::UInt64   # second 64-bit mix, salted apart from the first
    nodes::Int          # syntax-node count of this subtree
end

struct CloneSite
    file::String        # repo-relative path
    mod::Symbol         # module that owns the file
    method::Symbol      # enclosing method name
    method_line::Int    # source line where the method starts
    line::Int           # source line of this subtree
    path::Vector{Int}   # child indices down from the method body
end

struct CloneGroup
    nodes::Int                  # syntax-node count shared by every site
    sites::Vector{CloneSite}    # places this subtree text occurs
end

# Syntax nodes in each subtree of a method body, the subtree's root included.
const SubtreeSizes = IdDict{JS.SyntaxNode,Int}

mutable struct MixState
    primary::UInt64                         # running first mix
    secondary::UInt64                       # running second mix
    nodes::Int                              # nodes visited so far
    next_local::Int                         # count of distinct locals seen so far
    renames::IdDict{JS.SyntaxNode,Int}      # local's declaring identifier -> its first-appearance number
    const scan::FileScan                    # the index record naming each identifier's local
end

function absorb!(state, token)
    state.primary = hash(token, state.primary)
    state.secondary = hash(token, state.secondary)
end

function empty_mix(scan)
    renames = IdDict{JS.SyntaxNode,Int}()
    MixState(zero(UInt64), MIX_SALT, 0, 0, renames, scan)
end

# One count per node of a method body, shared by every subtree digested inside it. Returns the node's subtree size.
function count_nodes!(sizes, node)
    children = child_nodes(node)
    total = 1
    if !isnothing(children)
        for child in children
            total += count_nodes!(sizes, child)
        end
    end
    sizes[node] = total
    total
end

function local_slot!(state, binding)
    slot = get(state.renames, binding, 0)
    slot == 0 || return slot
    state.next_local += 1
    state.renames[binding] = state.next_local
    state.next_local
end

function call_child_place(node, index)
    if JS.is_infix_op_call(node)
        index == 2 && return :head
        return :value
    end
    if JS.is_postfix_op_call(node)
        children = child_nodes(node)
        if !isnothing(children) && index == length(children)
            return :head
        end
        return :value
    end
    index == 1 && return :head
    :value
end

# Where a child sits: a callee or operator, a field name, or a value.
function name_place(node, index)
    kind = JS.kind(node)
    if kind == K"."
        index == 2 && return :field
        return :value
    end
    if kind == K"comparison" || kind == K".op="
        iseven(index) && return :head
        return :value
    end
    if kind == K"call" || kind == K"dotcall" || kind == K"macrocall"
        return call_child_place(node, index)
    end
    :value
end

# A local renames by its binding. Inside a quote only a local the quoted code declares is one; `hidden` is that quote.
function emit_leaf!(state, node, place, hidden)
    value = node.val
    binding = value isa Symbol && place === :value ? local_binding(state.scan, node) : nothing
    if !isnothing(binding) && (isnothing(hidden) || node_inside(binding, hidden))
        absorb!(state, :local)
        slot = local_slot!(state, binding)
        absorb!(state, slot)
        return
    end
    absorb!(state, value)
end

# A quote hides the names around it from its children, except an interpolation written directly in it.
function hiding_quote(node, child, hidden)
    JS.kind(node) == K"quote" || return hidden
    JS.kind(child) == K"$" ? hidden : node
end

function absorb_children!(state, node, children, hidden)
    for index in eachindex(children)
        child = children[index]
        place = name_place(node, index)
        absorb!(state, place)
        inner = hiding_quote(node, child, hidden)
        absorb_tree!(state, child, place, inner)
    end
end

function absorb_tree!(state, node, place, hidden)
    state.nodes += 1
    kind = JS.kind(node)
    absorb!(state, kind)
    children = child_nodes(node)
    if child_count(children) == 0
        emit_leaf!(state, node, place, hidden)
        return
    end
    absorb_children!(state, node, children, hidden)
end

function digest_of(node, scan)
    state = empty_mix(scan)
    absorb_tree!(state, node, :value, nothing)
    CloneDigest(state.primary, state.secondary, state.nodes)
end

function push_site!(grouped, digest, method, node, path)
    line = source_line(node)
    owned = copy(path)
    site = CloneSite(method.file, method.mod, method.name, method.line, line, owned)
    push!(get!(Vector{CloneSite}, grouped, digest), site)
end

# One method body's digest walk: where groups go, the method, and the counts and record its subtrees read.
struct SiteWalk
    grouped::Dict{CloneDigest,Vector{CloneSite}}   # digest -> the places it occurs, across every method
    method::MethodBody                             # the method being walked
    min_nodes::Int                                 # smallest subtree digested, in syntax nodes
    sizes::SubtreeSizes                            # syntax nodes under each node of the body
    scan::FileScan                                 # the index record of the code holding the method
end

function walk_sites!(walk::SiteWalk, node, path)
    walk.sizes[node] < walk.min_nodes && return
    digest = digest_of(node, walk.scan)
    push_site!(walk.grouped, digest, walk.method, node, path)
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child = children[index]
        is_method_form(child) && continue
        child_path = copy(path)
        push!(child_path, index)
        walk_sites!(walk, child, child_path)
    end
end

site_place(places, site) = get(places, (site.mod, site.file), Int[])

function sort_sites(sites, places)
    sort(sites; by = site -> (site_place(places, site), site.line, site.path))
end

function method_keys(sites)
    seen = Set{Tuple{String,Symbol,Int}}()
    keys = Tuple{String,Symbol,Int}[]
    for site in sites
        key = (site.file, site.method, site.method_line)
        key in seen && continue
        push!(seen, key)
        push!(keys, key)
    end
    keys
end

function joined_labels(keys)
    parts = String[]
    for key in keys
        label = key[1] * ":" * string(key[2])
        push!(parts, label)
    end
    join(parts, " ")
end

function is_path_prefix(outer, inner)
    length(inner) > length(outer) || return false
    for index in eachindex(outer)
        inner[index] == outer[index] || return false
    end
    true
end

function site_inside(inner, outer)
    inner.file == outer.file || return false
    inner.method === outer.method || return false
    inner.method_line == outer.method_line || return false
    is_path_prefix(outer.path, inner.path)
end

function site_covered(site, kept)
    for group in kept
        for other in group.sites
            site_inside(site, other) && return true
        end
    end
    false
end

function group_covered(sites, kept)
    for site in sites
        site_covered(site, kept) || return false
    end
    true
end

function keep_groups(grouped)
    digests = collect(keys(grouped))
    sort!(digests; by = digest -> digest.nodes, rev = true)
    kept = CloneGroup[]
    for digest in digests
        sites = grouped[digest]
        length(sites) < 2 && continue
        seen = length(method_keys(sites))
        seen < 2 && continue
        group_covered(sites, kept) && continue
        push!(kept, CloneGroup(digest.nodes, sites))
    end
    kept
end

function clone_finding(group, places)
    ranked = sort_sites(group.sites, places)
    keys = method_keys(ranked)
    first_site = first(ranked)
    labels = joined_labels(keys)
    seen = length(keys)
    detail = "the same expression is written in " * string(seen) * " methods"
    nodes = string(group.nodes)
    site_count = string(length(ranked))
    evidence = Pair{Symbol,String}[
        :nodes => nodes,
        :sites => site_count,
        :methods => labels,
    ]
    symbol = string(first_site.method)
    Finding(first_site.mod, :expression_clone, first_site.file, symbol, first_site.line, detail, evidence)
end

function expression_clone_findings(index, min_nodes)
    grouped = Dict{CloneDigest,Vector{CloneSite}}()
    places = load_places(index)
    for file in index.files
        for method in file.bodies
            sizes = SubtreeSizes()
            count_nodes!(sizes, method.body)
            walk = SiteWalk(grouped, method, min_nodes, sizes, file.scan)
            walk_sites!(walk, method.body, Int[])
        end
    end
    kept = keep_groups(grouped)
    found = Finding[]
    for group in kept
        push!(found, clone_finding(group, places))
    end
    found
end

function run(check::ExpressionClones, ctx)
    expression_clone_findings(ctx.index, check.min_nodes)
end
