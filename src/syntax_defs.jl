# Top-level definitions and the references recorded while walking them.

# The type names in each `x::T` field declaration, const-wrapped included.
# An inner constructor's body is a method of this type, walked with the type as its owner.
function field_types!(refs, block)
    children = child_nodes(block)
    isnothing(children) && return
    for statement in children
        if JS.kind(statement) == K"::"
            parts = child_nodes(statement)
            if length(parts) >= 2
                all_symbols!(refs, parts[2])
            end
        elseif JS.kind(statement) == K"const"
            for child in child_nodes(statement)
                if JS.kind(child) == K"::"
                    parts = child_nodes(child)
                    if length(parts) >= 2
                        all_symbols!(refs, parts[2])
                    end
                end
            end
        end
    end
end

# Slot count when a body's final expression is a bare tuple. A named tuple names its slots, so 0.
function tuple_tail_slots(body)
    tail = body
    if JS.kind(tail) == K"block"
        children = child_nodes(tail)
        missing = isnothing(children) || isempty(children)
        missing && return 0
        tail = last(children)
    end
    if JS.kind(tail) == K"return"
        children = child_nodes(tail)
        missing = isnothing(children) || isempty(children)
        missing && return 0
        tail = first(children)
    end
    JS.kind(tail) == K"tuple" || return 0
    slots = child_nodes(tail)
    isnothing(slots) && return 0
    for slot in slots
        kind = JS.kind(slot)
        if kind == K"=" || kind == K"parameters"
            return 0
        end
    end
    length(slots)
end

# The name a method's calls are filed under. A method that is none of these belongs to its enclosing one.
function method_owner(signature, name, top, current, types)
    top && return name
    qualified = qualified_method_name(signature)
    isnothing(qualified) || return qualified
    receiver = callable_receiver(signature)
    isnothing(receiver) || return receiver
    !isnothing(current) && current in types && return current
    nothing
end

function ref_set(scan, current)
    isnothing(current) && return scan.modrefs
    scan.refs[current]
end

function note_symbol!(scan, node, current)
    node.val isa Symbol || return
    push!(ref_set(scan, current), node.val)
end

function walk_def_children!(scan, node, depth, current)
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        walk_defs!(scan, child, depth, current)
    end
end

function walk_dotted_def!(scan, node, depth, current)
    walked = walk_dot_base!(child -> walk_defs!(scan, child, depth, current), node)
    walked || return false
    children = child_nodes(node)
    member = children[2].val
    member isa Symbol || return true
    push!(ref_set(scan, current), member)
    true
end

function import_items(clause)
    if JS.kind(clause) == K":"
        children = child_nodes(clause)
        return children[2:end]
    end
    [clause]
end

function walk_import!(scan, node, depth, current)
    children = child_nodes(node)
    for clause in children
        items = import_items(clause)
        for item in items
            parts = child_nodes(item)
            bound = last(parts).val
            bound isa Symbol && push!(scan.imports, bound)
        end
    end
    walk_def_children!(scan, node, depth, current)
end

function record_type!(scan, node, name, children, kind)
    push!(scan.types, name)
    scan.line[name] = source_line(node)
    refs = get!(scan.refs, name, Set{Symbol}())
    head = first(children)
    if JS.kind(head) == K"<:"
        parts = child_nodes(head)
        all_symbols!(refs, parts[2])
    end
    kind == K"struct" || return
    field_types!(refs, last(children))
end

function walk_struct_body!(scan, node, depth, current, name)
    children = child_nodes(node)
    for child in children
        is_block = JS.kind(child) == K"block" && depth == 0 && !isnothing(name)
        if !is_block
            walk_defs!(scan, child, depth + 1, current)
            continue
        end
        statements = child_nodes(child)
        isnothing(statements) && continue
        for statement in statements
            owner = current
            if is_inner_constructor(statement)
                owner = name
            end
            walk_defs!(scan, statement, depth + 1, owner)
        end
    end
end

function walk_struct_def!(scan, node, depth, current)
    children = child_nodes(node)
    name = type_name(first(children))
    kind = JS.kind(node)
    if depth == 0 && !isnothing(name)
        record_type!(scan, node, name, children, kind)
    end
    walk_struct_body!(scan, node, depth, current, name)
end

function record_top_method!(scan, name, children)
    push!(scan.funcs, name)
    if !haskey(scan.refs, name)
        scan.refs[name] = Set{Symbol}()
    end
    scan.argtypes[name] = sig_argtypes(children[1])
    slots = 0
    if length(children) >= 2
        slots = tuple_tail_slots(children[2])
    end
    slots > 0 || return
    scan.tupletail[name] = slots
end

function walk_method_def!(scan, node, depth, current)
    children = child_nodes(node)
    name = sig_name(children[1])
    top = depth == 0 && !isnothing(name)
    line = source_line(node)
    if top
        scan.line[name] = line
        record_top_method!(scan, name, children)
    end
    length(children) < 2 && return
    owner = method_owner(children[1], name, top, current, scan.types)
    body = children[2]
    if isnothing(owner)
        walk_defs!(scan, body, depth + 1, current)
        return
    end
    site = MethodSite(owner, line)
    scan.forms[site] = node
    opened = ScanScope(owner, Set{Symbol}(), depth + 1, 0, site, false)
    absorb_method!(scan, children[1], body, opened)
end

function walk_arrow_def!(scan, node, depth, current)
    children = child_nodes(node)
    for child in children
        walk_defs!(scan, child, depth + 1, current)
    end
end

# depth counts function-def nesting. Only a def at depth 0 is top-level.
function walk_defs!(scan, node, depth, current)
    note_symbol!(scan, node, current)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if kind == K"."
        handled = walk_dotted_def!(scan, node, depth, current)
        handled && return
        walk_def_children!(scan, node, depth, current)
    elseif kind == K"export" || kind == K"public"
        return
    elseif kind == K"import"
        walk_import!(scan, node, depth, current)
    elseif kind == K"struct" || kind == K"abstract"
        walk_struct_def!(scan, node, depth, current)
    elseif is_method_form(node)
        walk_method_def!(scan, node, depth, current)
    elseif kind == K"->"
        walk_arrow_def!(scan, node, depth, current)
    elseif holds_values(kind)
        walk_value_children!(child -> walk_defs!(scan, child, depth, current), node)
    else
        walk_def_children!(scan, node, depth, current)
    end
end

# The walk, over a file's one parse.
function scan_tree(tree)
    scan = empty_scan()
    walk_defs!(scan, tree, 0, nothing)
    scan
end
