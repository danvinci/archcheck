# A search whose predicate measures against a configured tolerance.

struct ToleranceSearch{N} <: Check
    tolerances::NTuple{N,Symbol}   # constants a search predicate may measure against
end

kinds(::ToleranceSearch) = (:tolerance_search => :advisory,)

const SEARCH_HEADS = (:findfirst, :findlast, :findall)
const RANGE_OPS = (:<, :<=, :>, :>=, :≈, :isapprox)

struct SearchHit
    head::Symbol             # called search name
    predicate::JS.SyntaxNode # expression the call tests
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

function is_tolerance_use(node, bound, tolerances, place)
    place === :value || return false
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

function name_place_of(node, root)
    node === root && return :value
    parent = node.parent
    isnothing(parent) && return :value
    index = child_index(parent, node)
    isnothing(index) && return :value
    name_place(parent, index)
end

function inside_compare(node, root)
    node === root && return false
    current = node.parent
    while !isnothing(current)
        is_range_compare(current) && return true
        current === root && return false
        current = current.parent
    end
    false
end

function note_uses!(used, called, root, root_bound, tolerances, known)
    memo = IdDict{JS.SyntaxNode,Set{Symbol}}()
    memo[root] = root_bound
    for node in walk_nodes(root)
        bound = bound_of(node, root, root_bound, memo)
        place = name_place_of(node, root)
        if inside_compare(node, root) && is_tolerance_use(node, bound, tolerances, place)
            push!(used, node.val)
        end
        if place === :value
            value = node.val
            if value isa Symbol && value in known
                push!(called, value)
            end
        end
        head = call_head_symbol(node)
        if !isnothing(head) && head in known
            push!(called, head)
        end
    end
end

function defined_locally(method)
    form = method.body.parent
    isnothing(form) && return false
    is_method_form(form) || return false
    kids = child_nodes(form)
    (isnothing(kids) || isempty(kids)) && return false
    named = sig_name(kids[1])
    !isnothing(named)
end

function local_methods(methods, method)
    found = MethodBody[]
    for other in methods
        other.body === method.body && continue
        node_inside(other.body, method.body) || continue
        defined_locally(other) || continue
        push!(found, other)
    end
    found
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
    note_uses!(used, called, predicate.body, predicate.bound, tolerances, known)
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
    note_uses!(used, called, node, bound, tolerances, known)
    for name in called
        if haskey(reached, name)
            union!(used, reached[name])
        end
    end
    names = collect(used)
    sort!(names)
    names
end

function do_block(kids)
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
    block = do_block(kids)
    isnothing(block) || return SearchHit(head, block)
    length(kids) < 2 && return nothing
    SearchHit(head, kids[2])
end

function inside_nested_method(node, root)
    current = node.parent
    while !isnothing(current) && current !== root
        is_method_form(current) && return true
        current = current.parent
    end
    false
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

function walk_searches!(found, method, tolerances, reached)
    root = method.body
    is_method_form(root) && return
    root_bound = method.bound
    memo = IdDict{JS.SyntaxNode,Set{Symbol}}()
    memo[root] = root_bound
    for node in walk_nodes(root)
        is_method_form(node) && continue
        inside_nested_method(node, root) && continue
        parts = search_parts(node)
        isnothing(parts) && continue
        bound = bound_of(node, root, root_bound, memo)
        names = search_tolerances(parts.predicate, bound, tolerances, reached)
        isempty(names) && continue
        push_search!(found, method, node, parts.head, names)
    end
end

function tolerance_findings(index, tolerances)
    names = Set(tolerances)
    found = Finding[]
    for file in index.files
        methods = file_methods(file)
        for method in methods
            predicates = local_methods(methods, method)
            reached = reached_tolerances(predicates, names)
            walk_searches!(found, method, names, reached)
        end
    end
    found
end

function run(check::ToleranceSearch, ctx)
    tolerance_findings(ctx.index, check.tolerances)
end
