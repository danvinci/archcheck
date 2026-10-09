# One scope of a source walk, and the walk that records names and calls inside it.

function is_sync_macro(node::JS.SyntaxNode)
    JS.kind(node) == K"macrocall" || return false
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return false
    head = children[1]
    JS.kind(head) == K"macro_name" || return false
    parts = child_nodes(head)
    parts_missing = isnothing(parts) || isempty(parts)
    parts_missing && return false
    parts[1].val === :sync
end

# Whether the child at `index` has its value discarded. `@sync` returns its enclosed block's value.
function child_discarded(node, index, parent_discarded)
    children = child_nodes(node)
    out_of_range = isnothing(children) || index < 1 || index > length(children)
    out_of_range && return false
    kind = JS.kind(node)
    if kind == K"block"
        parent_discarded && return true
        return index != length(children)
    end
    if kind == K"for" || kind == K"while"
        return index == length(children)
    end
    discards_tail = kind == K"if" || kind == K"elseif" || kind == K"let"
    discards_tail = discards_tail || kind == K"&&" || kind == K"||"
    if parent_discarded && discards_tail
        return index >= 2
    end
    discards_clause = kind == K"try" || kind == K"catch" || kind == K"finally"
    if parent_discarded && discards_clause
        return true
    end
    if is_sync_macro(node) && JS.kind(children[index]) == K"block"
        return parent_discarded
    end
    false
end

# Which def the refs belong to, and which method the calls belong to.
struct ScanScope
    target::Symbol                    # refs key for the body being walked
    bound::Set{Symbol}                # names bound in this scope
    depth::Int                        # function-def nesting
    loop_depth::Int                   # repeating for, while and generator scopes around the node
    site::Union{Nothing,MethodSite}   # method the calls belong to; nothing on a name-resolution walk
    discarded::Bool                   # this node's value is discarded
end

function retarget(scope::ScanScope, target, bound)
    ScanScope(target, bound, scope.depth + 1, scope.loop_depth, scope.site, false)
end

function entered_scope(scope, node, index, depth, fn_depth)
    bound = child_locals(node, index, scope.bound)
    discarded = child_discarded(node, index, scope.discarded)
    ScanScope(scope.target, bound, fn_depth, depth, scope.site, discarded)
end

function entered_scope(scope, node, index)
    entered_scope(scope, node, index, scope.loop_depth, scope.depth)
end

function read_scope(scope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site, false)
end

function walk_iteration!(scan, node, scope, on_qualified = nothing)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if kind == K"in" || kind == K"="
        for index in 2:lastindex(children)
            child_scope = entered_scope(scope, node, index)
            walk_scoped!(scan, children[index], child_scope, on_qualified)
        end
        return
    end
    for index in eachindex(children)
        child_scope = entered_scope(scope, node, index)
        walk_iteration!(scan, children[index], child_scope, on_qualified)
    end
end

# The parts of an assignment's left side that read names: a type annotation, an index target, a property
# base. A bare binding reads nothing.
function collect_lhs!(found, node)
    children = child_nodes(node)
    isnothing(children) && return found
    kind = JS.kind(node)
    if kind == K"::"
        isempty(children) || push!(found, last(children))
    elseif kind == K"." || kind == K"ref" || kind == K"call" || kind == K"dotcall"
        push!(found, node)
    elseif kind == K"=" || kind == K"..."
        isempty(children) || collect_lhs!(found, children[1])
    elseif kind == K"tuple" || kind == K"parameters"
        for child in children
            collect_lhs!(found, child)
        end
    end
    found
end

function walk_assign_lhs!(scan, node, scope, on_qualified = nothing)
    targets = collect_lhs!(JS.SyntaxNode[], node)
    for target in targets
        walk_scoped!(scan, target, scope, on_qualified)
    end
end

# A filter's iterator stays at `scope`'s loop depth. Its predicate is inside the loop.
function walk_gen_spec!(scan, node, scope, interior_depth, on_qualified = nothing)
    if JS.kind(node) != K"filter"
        walk_iteration!(scan, node, scope, on_qualified)
        return
    end
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child = children[index]
        clause = is_iteration_clause(child)
        depth = scope.loop_depth
        if !clause
            depth = interior_depth
        end
        child_scope = entered_scope(scope, node, index, depth, scope.depth)
        if clause
            walk_iteration!(scan, child, child_scope, on_qualified)
        else
            walk_scoped!(scan, child, child_scope, on_qualified)
        end
    end
end

function note_free_name!(scan, node, scope)
    node.val isa Symbol || return
    node.val in scope.bound && return
    push!(scan.refs[scope.target], node.val)
end

function scope_children!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child_scope = entered_scope(scope, node, index)
        walk_scoped!(scan, children[index], child_scope, on_qualified)
    end
end

function scope_plain!(scan, node, scope, on_qualified)
    note_free_name!(scan, node, scope)
    scope_children!(scan, node, scope, on_qualified)
end

# A quote is walked only when no qualified-name callback is listening.
function scope_quote!(scan, node, scope, on_qualified)
    isnothing(on_qualified) || return
    scope_plain!(scan, node, scope, on_qualified)
end

function scope_dot!(scan, node, scope, on_qualified)
    walked = walk_dot_base!(child -> walk_scoped!(scan, child, scope, on_qualified), node)
    if !walked
        scope_plain!(scan, node, scope, on_qualified)
        return
    end
    children = child_nodes(node)
    member = children[2].val
    member isa Symbol || return
    push!(scan.refs[scope.target], member)
    isnothing(on_qualified) && return
    line = source_line(node)
    on_qualified(children[1], member, line, scope.bound)
end

# A method nested in a method already on `scope.site` gets its own form.
# Calls inside it stay on the enclosing site.
function record_nested_form!(scan, node, scope)
    isnothing(scope.site) && return
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    name = sig_name(children[1])
    isnothing(name) && return
    line = source_line(node)
    site = MethodSite(name, line)
    haskey(scan.forms, site) && return
    scan.forms[site] = node
end

function scope_method!(scan, node, scope, on_qualified)
    record_nested_form!(scan, node, scope)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    length(children) < 2 && return
    signature = children[1]
    body = children[2]
    receiver = callable_receiver(signature)
    if !isnothing(receiver)
        inner = retarget(scope, receiver, Set{Symbol}())
        absorb_method!(scan, signature, body, inner, on_qualified)
        return
    end
    inner = retarget(scope, scope.target, scope.bound)
    absorb_method!(scan, signature, body, inner, on_qualified)
end

function scope_closure!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    short = isnothing(children) || length(children) < 2
    short && return
    if !isnothing(on_qualified)
        walk_assign_lhs!(scan, children[1], scope, on_qualified)
    end
    body_bound = child_locals(node, 2, scope.bound)
    closed = retarget(scope, scope.target, body_bound)
    walk_scoped!(scan, children[2], closed, on_qualified)
end

function scope_loop!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    last_index = length(children)
    kind = JS.kind(node)
    for index in eachindex(children)
        depth = scope.loop_depth
        if index == last_index
            depth = scope.loop_depth + 1
        end
        child_scope = entered_scope(scope, node, index, depth, scope.depth)
        header = kind == K"for" && index != last_index
        if header
            walk_iteration!(scan, children[index], child_scope, on_qualified)
        else
            walk_scoped!(scan, children[index], child_scope, on_qualified)
        end
    end
end

function scope_comprehension!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    walk_scoped!(scan, children[1], scope, on_qualified)
end

function scope_generator!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    interior = scope.loop_depth + 1
    for index in 2:length(children)
        depth = scope.loop_depth
        if index > 2
            depth = interior
        end
        child_scope = entered_scope(scope, node, index, depth, scope.depth)
        walk_gen_spec!(scan, children[index], child_scope, interior, on_qualified)
    end
    element_scope = entered_scope(scope, node, 1, interior, scope.depth)
    walk_scoped!(scan, children[1], element_scope, on_qualified)
end

function scope_declaration!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    isnothing(children) && return
    for declaration in children
        if JS.kind(declaration) == K"="
            walk_scoped!(scan, declaration, scope, on_qualified)
        else
            walk_assign_lhs!(scan, declaration, scope, on_qualified)
        end
    end
end

function scope_assign!(scan, node, scope, on_qualified)
    children = child_nodes(node)
    plain = isnothing(children) || length(children) < 2
    if plain || is_sig(children[1])
        scope_plain!(scan, node, scope, on_qualified)
        return
    end
    read = read_scope(scope, scope.bound)
    walk_assign_lhs!(scan, children[1], read, on_qualified)
    rhs_bound = child_locals(node, 2, scope.bound)
    rhs = read_scope(scope, rhs_bound)
    walk_scoped!(scan, children[2], rhs, on_qualified)
end

function scope_call!(scan, node, scope, on_qualified)
    kind = JS.kind(node)
    if kind == K"call" || kind == K"dotcall"
        record_call!(scan, node, scope)
    end
    note_free_name!(scan, node, scope)
    arguments = read_scope(scope, scope.bound)
    walk_value_children!(child -> walk_scoped!(scan, child, arguments, on_qualified), node)
end

function walk_scoped!(scan, node, scope, on_qualified = nothing)
    kind = JS.kind(node)
    if kind == K"quote"
        scope_quote!(scan, node, scope, on_qualified)
    elseif kind == K"."
        scope_dot!(scan, node, scope, on_qualified)
    elseif is_method_form(node)
        scope_method!(scan, node, scope, on_qualified)
    elseif kind == K"->" || kind == K"do"
        scope_closure!(scan, node, scope, on_qualified)
    elseif kind == K"let" || kind == K"try"
        scope_children!(scan, node, scope, on_qualified)
    elseif kind == K"for" || kind == K"while"
        scope_loop!(scan, node, scope, on_qualified)
    elseif kind == K"comprehension"
        scope_comprehension!(scan, node, scope, on_qualified)
    elseif kind == K"generator"
        scope_generator!(scan, node, scope, on_qualified)
    elseif kind == K"global" || kind == K"local"
        scope_declaration!(scan, node, scope, on_qualified)
    elseif kind == K"="
        scope_assign!(scan, node, scope, on_qualified)
    elseif kind == K"call" || kind == K"dotcall" || kind == K"parameters" || kind == K"tuple"
        scope_call!(scan, node, scope, on_qualified)
    else
        scope_plain!(scan, node, scope, on_qualified)
    end
end

# `where` and return-type wrappers unwrap. Their annotations are references when a callback is listening.
function unwrap_signature!(scan, signature, noted, on_qualified)
    kind = JS.kind(signature)
    while kind == K"where" || kind == K"::"
        children = child_nodes(signature)
        if !isnothing(on_qualified)
            for annotation in children[2:end]
                walk_scoped!(scan, annotation, noted, on_qualified)
            end
        end
        signature = children[1]
        kind = JS.kind(signature)
    end
    signature
end

# One argument's default, read with the names bound to its left. The name then joins that set.
function absorb_argument!(scan, argument, prefix, noted, valued, on_qualified)
    if !isnothing(on_qualified)
        walk_assign_lhs!(scan, argument, noted, on_qualified)
    end
    if JS.kind(argument) == K"="
        children = child_nodes(argument)
        if !isnothing(children) && length(children) >= 2
            walk_scoped!(scan, children[2], valued, on_qualified)
        end
    end
    _argname!(prefix, argument)
end

function absorb_parameter!(scan, parameter, prefix, noted, valued, on_qualified)
    arguments = (parameter,)
    if JS.kind(parameter) == K"parameters"
        arguments = child_nodes(parameter)
    end
    isnothing(arguments) && return
    for argument in arguments
        absorb_argument!(scan, argument, prefix, noted, valued, on_qualified)
    end
end

# Default right-hand sides in signature order: positionals, then the keyword block.
# Each value is filtered by where-typevars plus the names of arguments to its left.
function absorb_defaults!(scan, signature, scope, on_qualified = nothing)
    prefix = copy(scope.bound)
    where_vars!(prefix, signature)
    annotation_bound = copy(prefix)
    noted = read_scope(scope, annotation_bound)
    valued = read_scope(scope, prefix)
    signature = unwrap_signature!(scan, signature, noted, on_qualified)
    JS.kind(signature) == K"call" || return
    children = child_nodes(signature)
    isnothing(children) && return
    if !isnothing(on_qualified)
        walk_scoped!(scan, children[1], noted, on_qualified)
    end
    bind_receiver!(prefix, children[1])
    for parameter in children[2:end]
        absorb_parameter!(scan, parameter, prefix, noted, valued, on_qualified)
    end
end

# Body references minus this method's bindings, plus the references in its defaults.
function absorb_method!(scan, signature, body, scope, on_qualified = nothing)
    get!(scan.refs, scope.target, Set{Symbol}())
    opened = read_scope(scope, scope.bound)
    absorb_defaults!(scan, signature, opened, on_qualified)
    bound = body_locals(signature, body, scope.bound)
    body_scope = read_scope(scope, bound)
    walk_scoped!(scan, body, body_scope, on_qualified)
end
