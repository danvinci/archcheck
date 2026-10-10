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

mutable struct MixState
    primary::UInt64            # running first mix
    secondary::UInt64          # running second mix
    nodes::Int                 # nodes visited so far
    next_local::Int            # count of distinct locals seen so far
    renames::Dict{Symbol,Int}  # local name to its first-appearance number
end

function absorb!(state, token)
    state.primary = hash(token, state.primary)
    state.secondary = hash(token, state.secondary)
end

function empty_mix()
    renames = Dict{Symbol,Int}()
    MixState(zero(UInt64), MIX_SALT, 0, 0, renames)
end

function local_slot!(state, name)
    slot = get(state.renames, name, 0)
    slot == 0 || return slot
    state.next_local += 1
    state.renames[name] = state.next_local
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

function emit_leaf!(state, node, bound, place)
    value = node.val
    if value isa Symbol && place === :value && value in bound
        absorb!(state, :local)
        slot = local_slot!(state, value)
        absorb!(state, slot)
        return
    end
    absorb!(state, value)
end

# A quote hides the surrounding names. Interpolation reads them.
function scoped_bound(node, index, bound, child)
    if JS.kind(node) != K"quote"
        return child_locals(node, index, bound)
    end
    if JS.kind(child) == K"$"
        return bound
    end
    Set{Symbol}()
end

function absorb_children!(state, node, children, bound)
    for index in eachindex(children)
        child = children[index]
        place = name_place(node, index)
        absorb!(state, place)
        inner = scoped_bound(node, index, bound, child)
        absorb_tree!(state, child, inner, place)
    end
end

function absorb_tree!(state, node, bound, place)
    state.nodes += 1
    kind = JS.kind(node)
    absorb!(state, kind)
    children = child_nodes(node)
    if child_count(children) == 0
        emit_leaf!(state, node, bound, place)
        return
    end
    absorb_children!(state, node, children, bound)
end

function digest_of(node, bound)
    state = empty_mix()
    absorb_tree!(state, node, bound, :value)
    CloneDigest(state.primary, state.secondary, state.nodes)
end

function count_nodes!(counts, node)
    children = child_nodes(node)
    total = 1
    if !isnothing(children)
        for child in children
            child_total = count_nodes!(counts, child)
            total += child_total
        end
    end
    counts[node] = total
    total
end

function push_site!(grouped, digest, method, node, path)
    line = source_line(node)
    owned = copy(path)
    site = CloneSite(method.file, method.mod, method.name, method.line, line, owned)
    push!(get!(Vector{CloneSite}, grouped, digest), site)
end

function walk_sites!(grouped, counts, node, method, path, min_nodes, bound)
    counted = get(counts, node, 0)
    if counted < min_nodes
        return
    end
    digest = digest_of(node, bound)
    push_site!(grouped, digest, method, node, path)
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child = children[index]
        is_method_form(child) && continue
        inner = child_locals(node, index, bound)
        child_path = vcat(path, index)
        walk_sites!(grouped, counts, child, method, child_path, min_nodes, inner)
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
        counts = IdDict{JS.SyntaxNode,Int}()
        count_nodes!(counts, file.tree)
        for method in file.bodies
            root_path = Int[]
            walk_sites!(grouped, counts, method.body, method, root_path, min_nodes, method.bound)
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
