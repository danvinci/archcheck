# Expression clones and tolerance searches over the index's syntax trees.

Base.@kwdef struct ExpressionClones <: Check
    min_nodes::Int = 20   # smallest subtree that can form a group, in syntax nodes
end

struct ToleranceSearch{N} <: Check
    tolerances::NTuple{N,Symbol}   # constants a search predicate may measure against
end

kinds(::ExpressionClones) = (:expression_clone => :advisory,)
kinds(::ToleranceSearch) = (:tolerance_search => :advisory,)

const MIX_SALT = 0x9e3779b97f4a7c15
const SEARCH_HEADS = (:findfirst, :findlast, :findall)
const RANGE_OPS = (:<, :<=, :>, :>=, :≈, :isapprox)

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

struct MethodBody
    name::Symbol          # method name
    line::Int             # source line of the method
    file::String          # repo-relative path
    mod::Symbol           # owning module
    body::JS.SyntaxNode   # body syntax
    bound::Set{Symbol}    # names this body binds
end

struct LocalPredicate
    name::Symbol          # local function name
    body::JS.SyntaxNode   # body syntax
    bound::Set{Symbol}    # names the local function binds
end

struct SearchHit
    head::Symbol             # called search name
    predicate::JS.SyntaxNode # expression the call tests
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

function emit_leaf!(state, node, bound, role)
    value = node.val
    if value isa Symbol && role === :value && value in bound
        absorb!(state, :local)
        slot = local_slot!(state, value)
        absorb!(state, slot)
        return
    end
    absorb!(state, value)
end

function call_child_role(node, index)
    if JS.is_infix_op_call(node)
        index == 2 && return :head
        return :value
    end
    if JS.is_postfix_op_call(node)
        kids = child_nodes(node)
        if !isnothing(kids) && index == length(kids)
            return :head
        end
        return :value
    end
    index == 1 && return :head
    :value
end

function name_role(node, index)
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
        return call_child_role(node, index)
    end
    :value
end

function bind_iteration!(bound, node)
    kind = JS.kind(node)
    kids = child_nodes(node)
    if (kind == K"in" || kind == K"=") && !isnothing(kids) && !isempty(kids)
        _argname!(bound, kids[1])
        return
    end
    isnothing(kids) && return
    for child in kids
        bind_iteration!(bound, child)
    end
end

function bind_body!(bound, body)
    assigned = Symbol[]
    collect_scope_assigns!(assigned, body)
    union!(bound, assigned)
    globals = Symbol[]
    collect_scope_globals!(globals, body)
    setdiff!(bound, globals)
    bound
end

function bind_catch!(bound, node)
    JS.kind(node) == K"catch" || return
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return
    JS.kind(kids[1]) == K"block" && return
    _argname!(bound, kids[1])
end

function method_bound(enclosing, sig, body)
    bound = copy(enclosing)
    args = sig_argnames(sig)
    union!(bound, args)
    bind_body!(bound, body)
end

function method_scope(node, bound)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return bound
    method_bound(bound, kids[1], kids[2])
end

function for_scope(node, bound)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return bound
    inner = copy(bound)
    last_index = length(kids)
    for index in 1:(last_index - 1)
        bind_iteration!(inner, kids[index])
    end
    bind_body!(inner, kids[last_index])
    inner
end

function generator_scope(node, bound)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return bound
    inner = copy(bound)
    for index in 2:length(kids)
        bind_iteration!(inner, kids[index])
    end
    bind_body!(inner, kids[1])
    inner
end

function while_scope(node, bound)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return bound
    inner = copy(bound)
    bind_body!(inner, last(kids))
    inner
end

function lambda_scope(node, bound)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return bound
    inner = copy(bound)
    extra = Symbol[]
    _argname!(extra, kids[1])
    union!(inner, extra)
    bind_body!(inner, kids[2])
    inner
end

function let_scope(node, bound)
    kids = child_nodes(node)
    isnothing(kids) && return bound
    inner = copy(bound)
    for child in kids
        bind_body!(inner, child)
    end
    inner
end

function try_scope(node, bound)
    kids = child_nodes(node)
    isnothing(kids) && return bound
    inner = copy(bound)
    for child in kids
        bind_catch!(inner, child)
        bind_body!(inner, child)
    end
    inner
end

function scoped_locals(node, bound)
    kind = JS.kind(node)
    if is_method_form(node)
        return method_scope(node, bound)
    end
    if kind == K"for"
        return for_scope(node, bound)
    end
    if kind == K"generator"
        return generator_scope(node, bound)
    end
    if kind == K"while"
        return while_scope(node, bound)
    end
    if kind == K"->" || kind == K"do"
        return lambda_scope(node, bound)
    end
    if kind == K"let"
        return let_scope(node, bound)
    end
    if kind == K"try"
        return try_scope(node, bound)
    end
    bound
end

function absorb_children!(state, node, kids, bound)
    for index in eachindex(kids)
        child = kids[index]
        role = name_role(node, index)
        absorb!(state, role)
        absorb_tree!(state, child, bound, role)
    end
end

function absorb_quoted!(state, node, kids, bound)
    quoted = Set{Symbol}()
    for index in eachindex(kids)
        child = kids[index]
        role = name_role(node, index)
        absorb!(state, role)
        if JS.kind(child) == K"$"
            absorb_tree!(state, child, bound, role)
        else
            absorb_tree!(state, child, quoted, role)
        end
    end
end

function absorb_tree!(state, node, bound, role)
    state.nodes += 1
    kind = JS.kind(node)
    absorb!(state, kind)
    kids = child_nodes(node)
    if isnothing(kids) || isempty(kids)
        emit_leaf!(state, node, bound, role)
        return
    end
    if kind == K"quote"
        absorb_quoted!(state, node, kids, bound)
        return
    end
    inner = scoped_locals(node, bound)
    absorb_children!(state, node, kids, inner)
end

function digest_of(node, bound)
    state = empty_mix()
    absorb_tree!(state, node, bound, :value)
    CloneDigest(state.primary, state.secondary, state.nodes)
end

function count_nodes!(counts, node)
    kids = child_nodes(node)
    total = 1
    if !isnothing(kids)
        for child in kids
            child_total = count_nodes!(counts, child)
            total += child_total
        end
    end
    counts[node] = total
    total
end

function method_name_of(sig)
    named = sig_name(sig)
    isnothing(named) || return named
    qualified = qualified_method_name(sig)
    isnothing(qualified) || return qualified
    callable_receiver(sig)
end

function collect_methods!(found, node, enclosing, file)
    if JS.kind(node) == K"quote"
        return
    end
    kids = child_nodes(node)
    if is_method_form(node) && !isnothing(kids) && length(kids) >= 2
        name = method_name_of(kids[1])
        if !isnothing(name)
            body = kids[2]
            bound = method_bound(enclosing, kids[1], body)
            line = source_line(node)
            record = MethodBody(name, line, file.path, file.mod, body, bound)
            push!(found, record)
            collect_methods!(found, body, bound, file)
            return
        end
    end
    isnothing(kids) && return
    inner = scoped_locals(node, enclosing)
    for child in kids
        collect_methods!(found, child, inner, file)
    end
end

function push_site!(grouped, digest, method, node, path)
    line = source_line(node)
    copied = copy(path)
    site = CloneSite(method.file, method.mod, method.name, method.line, line, copied)
    push!(get!(Vector{CloneSite}, grouped, digest), site)
end

function walk_sites!(grouped, counts, node, method, path, min_nodes, bound)
    counted = get(counts, node, 0)
    if counted < min_nodes
        return
    end
    digest = digest_of(node, bound)
    push_site!(grouped, digest, method, node, path)
    kids = child_nodes(node)
    isnothing(kids) && return
    inner = scoped_locals(node, bound)
    for index in eachindex(kids)
        child = kids[index]
        is_method_form(child) && continue
        child_path = vcat(path, index)
        walk_sites!(grouped, counts, child, method, child_path, min_nodes, inner)
    end
end

function file_order(index)
    order = Dict{String,Tuple{Vector{Int},Int}}()
    for file in index.files
        order[file.path] = (file.modrank, file.filerank)
    end
    order
end

function site_rank(order, file)
    haskey(order, file) || return (Int[], 0)
    order[file]
end

function sort_sites(sites, order)
    sort(sites; by = site -> (site_rank(order, site.file), site.line, site.path))
end

function method_count(sites)
    seen = Set{Tuple{String,Symbol,Int}}()
    for site in sites
        key = (site.file, site.method, site.method_line)
        push!(seen, key)
    end
    length(seen)
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
        seen = method_count(sites)
        seen < 2 && continue
        group_covered(sites, kept) && continue
        push!(kept, CloneGroup(digest.nodes, sites))
    end
    kept
end

function method_labels(sites)
    parts = String[]
    seen = Set{Tuple{String,Symbol,Int}}()
    for site in sites
        key = (site.file, site.method, site.method_line)
        key in seen && continue
        push!(seen, key)
        label = site.file * ":" * string(site.method)
        push!(parts, label)
    end
    join(parts, " ")
end

function clone_finding(group, order)
    ranked = sort_sites(group.sites, order)
    first_site = first(ranked)
    labels = method_labels(ranked)
    seen = method_count(ranked)
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
    order = file_order(index)
    empty_bound = Set{Symbol}()
    for file in index.files
        counts = IdDict{JS.SyntaxNode,Int}()
        count_nodes!(counts, file.tree)
        methods = MethodBody[]
        collect_methods!(methods, file.tree, empty_bound, file)
        for method in methods
            root_path = Int[]
            walk_sites!(grouped, counts, method.body, method, root_path, min_nodes, method.bound)
        end
    end
    kept = keep_groups(grouped)
    found = Finding[]
    for group in kept
        push!(found, clone_finding(group, order))
    end
    found
end

function operator_of(node)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return nothing
    kind = JS.kind(node)
    if kind == K"comparison"
        return kids[2].val
    end
    if JS.is_infix_op_call(node)
        return kids[2].val
    end
    if JS.is_postfix_op_call(node)
        return last(kids).val
    end
    if kind == K"call" || kind == K"dotcall"
        return kids[1].val
    end
    nothing
end

function is_range_compare(node)
    op = operator_of(node)
    op isa Symbol || return false
    op in RANGE_OPS
end

function is_tolerance_use(node, bound, tolerances, role)
    role === :value || return false
    value = node.val
    value isa Symbol || return false
    value in bound && return false
    value in tolerances
end

function call_head_symbol(node)
    kind = JS.kind(node)
    if kind != K"call" && kind != K"dotcall"
        return nothing
    end
    if JS.is_infix_op_call(node)
        return nothing
    end
    if JS.is_postfix_op_call(node)
        return nothing
    end
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return nothing
    head = kids[1].val
    head isa Symbol || return nothing
    head
end

function collect_predicates!(found, node, enclosing)
    if JS.kind(node) == K"quote"
        return
    end
    kids = child_nodes(node)
    if is_method_form(node) && !isnothing(kids) && length(kids) >= 2
        name = sig_name(kids[1])
        if !isnothing(name)
            body = kids[2]
            bound = method_bound(enclosing, kids[1], body)
            push!(found, LocalPredicate(name, body, bound))
            collect_predicates!(found, body, bound)
            return
        end
    end
    isnothing(kids) && return
    inner = scoped_locals(node, enclosing)
    for child in kids
        collect_predicates!(found, child, inner)
    end
end

function note_uses!(used, called, node, bound, tolerances, known, role, inside)
    if JS.kind(node) == K"quote"
        return
    end
    if inside && is_tolerance_use(node, bound, tolerances, role)
        push!(used, node.val)
    end
    if role === :value
        value = node.val
        if value isa Symbol && value in known
            push!(called, value)
        end
    end
    head = call_head_symbol(node)
    if !isnothing(head) && head in known
        push!(called, head)
    end
    kids = child_nodes(node)
    isnothing(kids) && return
    inner = scoped_locals(node, bound)
    comparing = inside || is_range_compare(node)
    for index in eachindex(kids)
        child = kids[index]
        child_role = name_role(node, index)
        note_uses!(used, called, child, inner, tolerances, known, child_role, comparing)
    end
end

function merge_uses!(table, name, incoming)
    if haskey(table, name)
        union!(table[name], incoming)
        return
    end
    table[name] = incoming
end

function note_predicate!(direct, calls, predicate, tolerances, known)
    used = Set{Symbol}()
    called = Set{Symbol}()
    note_uses!(used, called, predicate.body, predicate.bound, tolerances, known, :value, false)
    merge_uses!(direct, predicate.name, used)
    merge_uses!(calls, predicate.name, called)
end

function spread_reached!(reached, calls, limit)
    steps = 0
    while steps < limit
        steps += 1
        grew = false
        for name in keys(calls)
            bag = reached[name]
            before = length(bag)
            callees = calls[name]
            for callee in callees
                if haskey(reached, callee)
                    union!(bag, reached[callee])
                end
            end
            if length(bag) != before
                grew = true
            end
        end
        grew || break
    end
end

function reached_tolerances(predicates, tolerances)
    known = Set{Symbol}()
    for predicate in predicates
        push!(known, predicate.name)
    end
    direct = Dict{Symbol,Set{Symbol}}()
    calls = Dict{Symbol,Set{Symbol}}()
    for predicate in predicates
        note_predicate!(direct, calls, predicate, tolerances, known)
    end
    reached = Dict{Symbol,Set{Symbol}}()
    for name in keys(direct)
        bag = direct[name]
        reached[name] = copy(bag)
    end
    limit = length(predicates)
    spread_reached!(reached, calls, limit)
    hot = Dict{Symbol,Set{Symbol}}()
    for name in keys(reached)
        bag = reached[name]
        if !isempty(bag)
            hot[name] = bag
        end
    end
    hot
end

function search_tolerances(node, bound, tolerances, reached)
    hot_names = keys(reached)
    known = Set(hot_names)
    used = Set{Symbol}()
    called = Set{Symbol}()
    note_uses!(used, called, node, bound, tolerances, known, :value, false)
    for name in called
        if haskey(reached, name)
            union!(used, reached[name])
        end
    end
    names = collect(used)
    sort!(names)
    names
end

function do_child(kids)
    for child in kids
        if JS.kind(child) == K"do"
            return child
        end
    end
    nothing
end

function search_parts(node)
    JS.kind(node) == K"call" || return nothing
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return nothing
    head = kids[1].val
    head isa Symbol || return nothing
    head in SEARCH_HEADS || return nothing
    block = do_child(kids)
    if !isnothing(block)
        return SearchHit(head, block)
    end
    length(kids) < 2 && return nothing
    SearchHit(head, kids[2])
end

function push_search!(found, method, node, head, names)
    label = join(names, " ")
    search = string(head)
    evidence = Pair{Symbol,String}[
        :search => search,
        :tolerance => label,
    ]
    line = source_line(node)
    detail = "a search compares within a tolerance"
    symbol = string(method.name)
    finding = Finding(method.mod, :tolerance_search, method.file, symbol, line, detail, evidence)
    push!(found, finding)
end

function walk_searches!(found, node, method, bound, tolerances, reached)
    if JS.kind(node) == K"quote"
        return
    end
    if is_method_form(node)
        return
    end
    parts = search_parts(node)
    if !isnothing(parts)
        names = search_tolerances(parts.predicate, bound, tolerances, reached)
        if !isempty(names)
            push_search!(found, method, node, parts.head, names)
        end
    end
    kids = child_nodes(node)
    isnothing(kids) && return
    inner = scoped_locals(node, bound)
    for child in kids
        walk_searches!(found, child, method, inner, tolerances, reached)
    end
end

function tolerance_findings(index, tolerances)
    names = Set(tolerances)
    found = Finding[]
    empty_bound = Set{Symbol}()
    for file in index.files
        methods = MethodBody[]
        collect_methods!(methods, file.tree, empty_bound, file)
        for method in methods
            predicates = LocalPredicate[]
            collect_predicates!(predicates, method.body, method.bound)
            reached = reached_tolerances(predicates, names)
            walk_searches!(found, method.body, method, method.bound, names, reached)
        end
    end
    found
end

function run(check::ExpressionClones, ctx)
    expression_clone_findings(ctx.index, check.min_nodes)
end

function run(check::ToleranceSearch, ctx)
    tolerance_findings(ctx.index, check.tolerances)
end
