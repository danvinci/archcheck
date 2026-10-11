# Which names are local to a child, and each method body with the names it binds. The walk that reads them lives
# beside this.

function is_nested_scope(node)
    kind = JS.kind(node)
    kind == K"->" && return true
    kind == K"do" && return true
    kind == K"let" && return true
    kind == K"for" && return true
    kind == K"while" && return true
    kind == K"try" && return true
    kind == K"generator" && return true
    kind == K"comprehension" && return true
    is_method_form(node)
end

# `@eval`, bare or qualified: its code runs at the module's global scope.
function is_eval_macro(node)
    JS.kind(node) == K"macrocall" || return false
    macro_call_name(node) === Symbol("@eval")
end

# A `name=value` child of a call or a broadcast is a keyword argument. The name binds nothing in the caller.
function is_call_keyword(node)
    JS.kind(node) == K"=" || return false
    parent = node.parent
    isnothing(parent) && return false
    parent_kind = JS.kind(parent)
    parent_kind == K"call" || parent_kind == K"dotcall"
end

# Assignments and nested method names in this scope. A nested scope keeps its own names, and code `@eval` runs
# binds globals.
function collect_scope_assigns!(bound, node)
    is_eval_macro(node) && return
    if is_method_form(node)
        children = child_nodes(node)
        declare_sig_name!(bound, children[1])
        return
    end
    is_nested_scope(node) && return
    kind = JS.kind(node)
    children = child_nodes(node)
    if kind == K"="
        child_count(children) == 0 && return
        if is_call_keyword(node)
            length(children) < 2 && return
            collect_scope_assigns!(bound, children[2])
            return
        end
        _argname!(bound, children[1])
        if length(children) >= 2
            collect_scope_assigns!(bound, children[2])
        end
        return
    end
    if kind == K"local"
        isnothing(children) && return
        declared = local_names(bound)
        for child in children
            _argname!(declared, child)
        end
        return
    end
    if holds_values(kind)
        walk_value_children!(child -> collect_scope_assigns!(bound, child), node)
        return
    end
    isnothing(children) && return
    for child in children
        collect_scope_assigns!(bound, child)
    end
end

# Every name a binding under `node` introduces: assignment and loop targets, closure and method
# parameters, local method names, `local` and `catch` variables. Keyword labels count too.
function bound_names!(names::Union{Vector{Symbol}, Set{Symbol}}, node::JS.SyntaxNode)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if is_method_form(node)
        local_name = sig_name(children[1])
        isnothing(local_name) || push!(names, local_name)
        arguments = sig_argnames(children[1])::Vector{Symbol}
        union!(names, arguments)
    elseif kind == K"=" || kind == K"in" || kind == K"->" || kind == K"do" || kind == K"catch"
        _argname!(names, children[1])
    elseif kind == K"local"
        for declared in children
            _argname!(names, declared)
        end
    end
    for child in children
        bound_names!(names, child)
    end
end

function collect_scope_globals!(names, node)
    is_nested_scope(node) && return
    kind = JS.kind(node)
    children = child_nodes(node)
    if kind == K"global"
        isnothing(children) && return
        for child in children
            _argname!(names, child)
        end
        return
    end
    isnothing(children) && return
    for child in children
        collect_scope_globals!(names, child)
    end
end

# A `local` line declares into its own set where the scope's statements keep one apart.
local_names(found::Assigned) = found.declared
local_names(bound) = bound

# The walk passes bindings; a method body passes a name set. An untyped copy infers as a vector.
function nested_bound(outer::Union{Set{Symbol},Bindings}, extra::Union{Set{Symbol},Bindings}, body::JS.SyntaxNode)
    bound = copy(outer)
    union!(bound, extra)
    found = assignments(outer)
    collect_scope_assigns!(found, body)
    adopt!(bound, found)
    globals = Symbol[]
    collect_scope_globals!(globals, body)
    setdiff!(bound, globals)
    bound
end

# Names local in `body`, plus the signature's names, minus names the body declares global.
function body_locals(signature, body, outer)
    names = sig_argnames!(empty(outer), signature)
    nested_bound(outer, names, body)
end

function is_iteration_clause(node)
    kind = JS.kind(node)
    kind == K"iteration" || kind == K"in" || kind == K"="
end

function add_iteration_names!(bound, children)
    for child in children
        is_iteration_clause(child) || continue
        iteration_names!(bound, child)
    end
end

function iteration_names!(bound, node)
    kind = JS.kind(node)
    children = child_nodes(node)
    is_binding = kind == K"in" || kind == K"="
    has_target = child_count(children) > 0
    if is_binding && has_target
        _argname!(bound, children[1])
        return
    end
    isnothing(children) && return
    if kind == K"filter"
        add_iteration_names!(bound, children)
        return
    end
    for child in children
        iteration_names!(bound, child)
    end
end

# `outer`, plus the names `binder` finds from `first_position` through the child before `index`.
function bound_before(outer, children, index::Int, binder, first_position::Int)
    last_earlier = index - 1
    last_earlier < first_position && return outer
    bound = copy(outer)
    for position in first_position:last_earlier
        binder(bound, children[position])
    end
    bound
end

function binding_names!(bound, node)
    kind = JS.kind(node)
    if kind == K"="
        named_head!(bound, node)
        return
    end
    kind == K"block" || return
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        binding_names!(bound, child)
    end
end

function is_let_bindings(node)
    parent = node.parent
    isnothing(parent) && return false
    JS.kind(parent) == K"let" || return false
    children = child_nodes(parent)
    child_count(children) == 0 && return false
    children[1] === node
end

function bind_catch_name!(bound, node)
    JS.kind(node) == K"catch" || return
    children = child_nodes(node)
    child_count(children) == 0 && return
    JS.kind(children[1]) == K"block" && return
    _argname!(bound, children[1])
end

function method_child(node, index, outer)
    children = child_nodes(node)
    past_end = isnothing(children) || index > length(children)
    past_end && return outer
    if index == 1
        bound = copy(outer)
        names = sig_argnames!(empty(outer), children[1])
        union!(bound, names)
        return bound
    end
    body_locals(children[1], children[index], outer)
end

function for_child(children, index, outer)
    last_index = length(children)
    if index == last_index
        empty_bound = empty(outer)
        extra = bound_before(empty_bound, children, last_index, iteration_names!, 1)
        return nested_bound(outer, extra, children[index])
    end
    bound_before(outer, children, index, iteration_names!, 1)
end

function while_child(children, index, outer)
    if index == length(children)
        none = empty(outer)
        return nested_bound(outer, none, children[index])
    end
    outer
end

function generator_child(children::Vector{JS.SyntaxNode}, index::Int, outer)
    if index == 1
        extra = empty(outer)
        for spec in children[2:end]
            iteration_names!(extra, spec)
        end
        return nested_bound(outer, extra, children[1])
    end
    bound_before(outer, children, index, iteration_names!, 2)
end

function filter_child(children, index, outer)
    child = children[index]
    is_iteration_clause(child) && return outer
    bound = copy(outer)
    add_iteration_names!(bound, children)
    bound
end

function lambda_child(children, index, outer)
    if index == 1
        bound = copy(outer)
        _argname!(bound, children[1])
        return bound
    end
    names = empty(outer)
    _argname!(names, children[1])
    nested_bound(outer, names, children[index])
end

function let_child(children, index, outer)
    if index == 1
        return outer
    end
    seeded = copy(outer)
    binding_names!(seeded, children[1])
    if index == length(children)
        none = empty(outer)
        return nested_bound(seeded, none, children[index])
    end
    seeded
end

function try_child(children, index, outer)
    clause = children[index]
    seeded = copy(outer)
    bind_catch_name!(seeded, clause)
    none = empty(outer)
    nested_bound(seeded, none, clause)
end

# The left side binds a name. Later children read the names around the node.
function lhs_child(children, index, outer)
    if index == 1
        bound = copy(outer)
        _argname!(bound, children[1])
        return bound
    end
    outer
end

# Names local to the child at `index`. A child that binds nothing returns `outer` for the caller to read.
# A `for` or a generator reads its first iterator outside that scope.
function child_locals(node, index, outer)
    if is_method_form(node)
        return method_child(node, index, outer)
    end
    if is_let_bindings(node)
        children = child_nodes(node)
        isnothing(children) && return outer
        return bound_before(outer, children, index, binding_names!, 1)
    end
    children = child_nodes(node)
    out_of_range = isnothing(children) || index < 1 || index > length(children)
    out_of_range && return outer
    kind = JS.kind(node)
    if kind == K"for"
        return for_child(children, index, outer)
    end
    if kind == K"while"
        return while_child(children, index, outer)
    end
    if kind == K"generator"
        return generator_child(children, index, outer)
    end
    if kind == K"filter"
        return filter_child(children, index, outer)
    end
    if kind == K"->" || kind == K"do"
        return lambda_child(children, index, outer)
    end
    if kind == K"let"
        return let_child(children, index, outer)
    end
    if kind == K"try"
        return try_child(children, index, outer)
    end
    if kind == K"iteration"
        return bound_before(outer, children, index, iteration_names!, 1)
    end
    if kind == K"in" || kind == K"="
        return lhs_child(children, index, outer)
    end
    outer
end

# The lambda arguments and loop variables this child binds itself, including a name the outer scope already holds.
function child_bindings(node::JS.SyntaxNode, index::Int)
    names = Set{Symbol}()
    children = child_nodes(node)
    isnothing(children) && return names
    kind = JS.kind(node)
    is_lambda = kind == K"->" || kind == K"do"
    if is_lambda && index > 1 && !isempty(children)
        _argname!(names, children[1])
        return names
    end
    if kind == K"for" && index == length(children)
        last_spec = index - 1
        for spec_index in 1:last_spec
            iteration_names!(names, children[spec_index])
        end
    end
    names
end

struct MethodBody
    name::Symbol          # method name
    line::Int             # source line of the method
    file::String          # repo-relative path
    mod::Symbol           # owning module
    body::JS.SyntaxNode   # body syntax
    bound::Set{Symbol}    # names this body binds
end

function child_index(parent, node)
    children = child_nodes(parent)
    isnothing(children) && return nothing
    for index in eachindex(children)
        children[index] === node && return index
    end
    nothing
end

function node_inside(node, ancestor)
    current = node
    while !isnothing(current)
        current === ancestor && return true
        current = current.parent
    end
    false
end

function bound_of(node, root, root_bound, memo)
    haskey(memo, node) && return memo[node]
    if node === root || isnothing(node.parent)
        memo[node] = root_bound
        return root_bound
    end
    parent = node.parent
    parent_bound = bound_of(parent, root, root_bound, memo)
    index = child_index(parent, node)
    if isnothing(index)
        memo[node] = parent_bound
        return parent_bound
    end
    inner = child_locals(parent, index, parent_bound)
    memo[node] = inner
    inner
end

# A method written in a default argument sits in the signature, outside the body.
function in_method_body(node, root)
    current = node.parent
    while !isnothing(current) && current !== root
        if is_method_form(current)
            body = method_body(current)
            isnothing(body) && return false
            return node_inside(node, body)
        end
        current = current.parent
    end
    true
end

function method_name_of(sig)
    named = sig_name(sig)
    isnothing(named) || return named
    qualified = qualified_method_name(sig)
    isnothing(qualified) || return qualified
    callable_receiver(sig)
end

# Every method written in one piece of code, nested ones included, each with the names its body binds.
function method_bodies(root, path::String, mod::Symbol)
    found = MethodBody[]
    root_bound = Set{Symbol}()
    memo = IdDict{JS.SyntaxNode,Set{Symbol}}()
    memo[root] = root_bound
    for node in walk_nodes(root)
        is_method_form(node) || continue
        in_method_body(node, root) || continue
        body = method_body(node)
        isnothing(body) && continue
        children = child_nodes(node)
        signature = children[1]
        name = method_name_of(signature)
        isnothing(name) && continue
        enclosing = bound_of(node, root, root_bound, memo)
        bound = body_locals(signature, body, enclosing)
        line = source_line(node)
        record = MethodBody(name, line, path, mod, body, bound)
        push!(found, record)
    end
    found
end

# Visits every node with the name of the nearest enclosing top-level def.
# `visit(node, enclosing_name)` answers which function an expression sits inside.
function walk_with_enclosing(visit, node, current = Symbol(""))
    children = child_nodes(node)
    if is_method_form(node)
        name = sig_name(children[1])
        enclosed = isnothing(name) ? current : name
        isnothing(children) && return
        for child in children
            walk_with_enclosing(visit, child, enclosed)
        end
        return
    end
    visit(node, current)
    isnothing(children) && return
    for child in children
        walk_with_enclosing(visit, child, current)
    end
end
