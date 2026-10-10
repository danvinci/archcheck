# One scope of a source walk, and the walk that records names and calls inside it.

function is_sync_macro(node::JS.SyntaxNode)
    JS.kind(node) == K"macrocall" || return false
    children = child_nodes(node)
    child_count(children) == 0 && return false
    head = children[1]
    JS.kind(head) == K"macro_name" || return false
    parts = child_nodes(head)
    child_count(parts) == 0 && return false
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

# Which def the refs belong to, which method the calls belong to, and which method form holds the node.
struct ScanScope
    target::Union{Nothing,Symbol}           # refs key for the body being walked; nothing outside any def
    bound::Set{Symbol}                      # names bound in this scope
    depth::Int                              # function-def nesting
    loop_depth::Int                         # repeating for, while and generator scopes around the node
    site::Union{Nothing,MethodSite}         # method the calls belong to; nothing on a name-resolution walk
    discarded::Bool                         # this node's value is discarded
    method::Union{Nothing,JS.SyntaxNode}    # outermost method, macro or closure form around the node
    in_signature::Bool                      # the node sits in a signature's annotations, run where the method is defined
end

# A scope at the top of a walk: no locals, no loop, no method around it.
function opening_scope(target, depth, site)
    ScanScope(target, Set{Symbol}(), depth, 0, site, false, nothing, false)
end

# The scope inside a method form: the outermost form stays the method every read inside it belongs to.
function retarget(scope::ScanScope, target, bound, form)
    method = isnothing(scope.method) ? form : scope.method
    ScanScope(target, bound, scope.depth + 1, scope.loop_depth, scope.site, false, method, scope.in_signature)
end

function entered_scope(scope, node, index, depth, fn_depth)
    bound = child_locals(node, index, scope.bound)
    discarded = child_discarded(node, index, scope.discarded)
    ScanScope(scope.target, bound, fn_depth, depth, scope.site, discarded, scope.method, scope.in_signature)
end

function entered_scope(scope, node, index)
    entered_scope(scope, node, index, scope.loop_depth, scope.depth)
end

function read_scope(scope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site, false, scope.method, scope.in_signature)
end

function signature_scope(scope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site, false, scope.method, true)
end

function walk_iteration!(scan, node, scope)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if kind == K"in" || kind == K"="
        for index in 2:lastindex(children)
            child_scope = entered_scope(scope, node, index)
            walk_scoped!(scan, children[index], child_scope)
        end
        return
    end
    for index in eachindex(children)
        child_scope = entered_scope(scope, node, index)
        walk_iteration!(scan, children[index], child_scope)
    end
end

# The parts of an assignment's left side that read names: a type annotation, an index target, a property
# base. A bare binding reads nothing; a macro around one, as `@nospecialize(x::T)`, reads what its argument does.
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
    elseif kind == K"macrocall"
        for argument in children[2:end]
            collect_lhs!(found, argument)
        end
    end
    found
end

function walk_assign_lhs!(scan, node, scope)
    targets = collect_lhs!(JS.SyntaxNode[], node)
    for target in targets
        walk_scoped!(scan, target, scope)
    end
end

# A filter's iterator stays at `scope`'s loop depth. Its predicate is inside the loop.
function walk_gen_spec!(scan, node, scope, interior_depth)
    if JS.kind(node) != K"filter"
        walk_iteration!(scan, node, scope)
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
            walk_iteration!(scan, child, child_scope)
        else
            walk_scoped!(scan, child, child_scope)
        end
    end
end

# The index reads a def's bare names from its body and defaults; a signature's annotations run where it is defined.
function note_free_name!(scan::FileScan, node, scope)
    scope.in_signature && return
    name = node_symbol(node)
    isnothing(name) && return
    name in scope.bound && return
    names = open_target!(scan, scope.target)
    push!(names, name)
end

open_target!(scan::FileScan, target) = get!(Set{Symbol}, scan.refs, target)

function scope_children!(scan, node, scope)
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child_scope = entered_scope(scope, node, index)
        walk_scoped!(scan, children[index], child_scope)
    end
end

# A member read through a qualifier that can name a module, kept for the index to resolve against the loaded modules.
function note_member!(scan::FileScan, scope, dot, qualifier, member)
    scope.in_signature && return
    is_module_path(qualifier, scope.bound) || return
    read = QualifiedRead(scope.target, qualifier, member)
    push!(scan.members, read)
end

function scope_plain!(scan, node, scope)
    note_free_name!(scan, node, scope)
    scope_children!(scan, node, scope)
end

function scope_dot!(scan, node, scope)
    walked = walk_dot_base!(child -> walk_scoped!(scan, child, scope), node)
    if !walked
        scope_plain!(scan, node, scope)
        return
    end
    children = child_nodes(node)
    member = named_symbol(children[2])
    isnothing(member) && return
    note_member!(scan, scope, node, children[1], member)
end

# A method nested in a method already on `scope.site` gets its own form.
# Calls inside it stay on the enclosing site.
function record_nested_form!(scan, node, scope)
    isnothing(scope.site) && return
    children = child_nodes(node)
    child_count(children) == 0 && return
    name = sig_name(children[1])
    isnothing(name) && return
    line = source_line(node)
    site = MethodSite(name, line)
    haskey(scan.forms, site) && return
    scan.forms[site] = node
end

# A callable's method files under its receiver type; a method outside any def opens one under the name it defines.
function scope_method!(scan, node, scope)
    record_nested_form!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) < 2 && return
    signature = children[1]
    body = children[2]
    receiver = callable_receiver(signature)
    if !isnothing(receiver)
        inner = retarget(scope, receiver, Set{Symbol}(), node)
        absorb_method!(scan, signature, body, inner)
        return
    end
    target = scope.target
    if isnothing(target)
        named = sig_name(signature)
        target = isnothing(named) ? qualified_method_name(signature) : named
    end
    inner = retarget(scope, target, scope.bound, node)
    absorb_method!(scan, signature, body, inner)
end

# A macro's arguments and the names its body assigns are its own; its name is no read.
function scope_macro!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) < 2 && return
    signature = children[1]
    call = signature_call(signature)
    isnothing(call) && return
    inner = retarget(scope, scope.target, scope.bound, node)
    arguments = child_nodes(call)[2:end]
    noted = signature_scope(inner, inner.bound)
    for argument in arguments
        walk_assign_lhs!(scan, argument, noted)
    end
    bound = body_locals(signature, children[2], inner.bound)
    body_scope = read_scope(inner, bound)
    walk_scoped!(scan, children[2], body_scope)
end

function scope_closure!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) < 2 && return
    closed = retarget(scope, scope.target, scope.bound, node)
    noted = signature_scope(closed, scope.bound)
    walk_assign_lhs!(scan, children[1], noted)
    body_bound = child_locals(node, 2, scope.bound)
    body = read_scope(closed, body_bound)
    walk_scoped!(scan, children[2], body)
end

function scope_loop!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) == 0 && return
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
            walk_iteration!(scan, children[index], child_scope)
        else
            walk_scoped!(scan, children[index], child_scope)
        end
    end
end

function scope_comprehension!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) == 0 && return
    walk_scoped!(scan, children[1], scope)
end

function scope_generator!(scan, node, scope)
    children = child_nodes(node)
    child_count(children) == 0 && return
    interior = scope.loop_depth + 1
    for index in 2:length(children)
        depth = scope.loop_depth
        if index > 2
            depth = interior
        end
        child_scope = entered_scope(scope, node, index, depth, scope.depth)
        walk_gen_spec!(scan, children[index], child_scope, interior)
    end
    element_scope = entered_scope(scope, node, 1, interior, scope.depth)
    walk_scoped!(scan, children[1], element_scope)
end

function scope_declaration!(scan, node, scope)
    children = child_nodes(node)
    isnothing(children) && return
    for declaration in children
        if JS.kind(declaration) == K"="
            walk_scoped!(scan, declaration, scope)
        else
            walk_assign_lhs!(scan, declaration, scope)
        end
    end
end

function scope_assign!(scan, node, scope)
    children = child_nodes(node)
    if child_count(children) < 2 || is_sig(children[1])
        scope_plain!(scan, node, scope)
        return
    end
    read = read_scope(scope, scope.bound)
    walk_assign_lhs!(scan, children[1], read)
    rhs_bound = child_locals(node, 2, scope.bound)
    rhs = read_scope(scope, rhs_bound)
    walk_scoped!(scan, children[2], rhs)
end

function scope_call!(scan, node, scope)
    kind = JS.kind(node)
    is_call = kind == K"call" || kind == K"dotcall"
    if is_call && !scope.in_signature
        record_call!(scan, node, scope)
    end
    note_free_name!(scan, node, scope)
    arguments = read_scope(scope, scope.bound)
    walk_value_children!(child -> walk_scoped!(scan, child, arguments), node)
end

function walk_scoped!(scan, node, scope)
    kind = JS.kind(node)
    if kind == K"."
        scope_dot!(scan, node, scope)
    elseif is_method_form(node)
        scope_method!(scan, node, scope)
    elseif kind == K"macro"
        scope_macro!(scan, node, scope)
    elseif kind == K"->" || kind == K"do"
        scope_closure!(scan, node, scope)
    elseif kind == K"let" || kind == K"try"
        scope_children!(scan, node, scope)
    elseif kind == K"for" || kind == K"while"
        scope_loop!(scan, node, scope)
    elseif kind == K"comprehension"
        scope_comprehension!(scan, node, scope)
    elseif kind == K"generator"
        scope_generator!(scan, node, scope)
    elseif kind == K"global" || kind == K"local"
        scope_declaration!(scan, node, scope)
    elseif kind == K"="
        scope_assign!(scan, node, scope)
    elseif kind == K"call" || kind == K"dotcall" || kind == K"parameters" || kind == K"tuple"
        scope_call!(scan, node, scope)
    else
        scope_plain!(scan, node, scope)
    end
end

# `where` and return-type wrappers unwrap; their annotations are signature reads.
function unwrap_signature!(scan, signature, noted)
    kind = JS.kind(signature)
    while kind == K"where" || kind == K"::"
        children = child_nodes(signature)
        for annotation in children[2:end]
            walk_scoped!(scan, annotation, noted)
        end
        signature = children[1]
        kind = JS.kind(signature)
    end
    signature
end

# One argument's default, read with the names bound to its left. The name then joins that set.
function absorb_argument!(scan, argument, prefix, noted, valued)
    walk_assign_lhs!(scan, argument, noted)
    if JS.kind(argument) == K"="
        children = child_nodes(argument)
        if child_count(children) >= 2
            walk_scoped!(scan, children[2], valued)
        end
    end
    _argname!(prefix, argument)
end

function absorb_parameter!(scan, parameter, prefix, noted, valued)
    arguments = (parameter,)
    if JS.kind(parameter) == K"parameters"
        arguments = child_nodes(parameter)
    end
    isnothing(arguments) && return
    for argument in arguments
        absorb_argument!(scan, argument, prefix, noted, valued)
    end
end

# Default right-hand sides in signature order: positionals, then the keyword block.
# Each value is filtered by where-typevars plus the names of arguments to its left.
function absorb_defaults!(scan, signature, scope)
    prefix = copy(scope.bound)
    where_vars!(prefix, signature)
    annotation_bound = copy(prefix)
    noted = signature_scope(scope, annotation_bound)
    valued = read_scope(scope, prefix)
    signature = unwrap_signature!(scan, signature, noted)
    JS.kind(signature) == K"call" || return
    children = child_nodes(signature)
    isnothing(children) && return
    walk_scoped!(scan, children[1], noted)
    bind_receiver!(prefix, children[1])
    for parameter in children[2:end]
        absorb_parameter!(scan, parameter, prefix, noted, valued)
    end
end

"""The scoped walk's recorder over one piece of code: the reads so far, and what a qualifier resolves against."""
struct ReadRecorder{N}
    reads::Vector{NameRead}               # every read, in walk order
    names::N                              # what a bare name binds where the code sits; nothing when unloaded
    named::IdDict{JS.SyntaxNode,Module}   # each dotted qualifier already met -> the loaded module it names
end

# Every name `code` reads, each qualifier resolved against `names`: the loaded module the code sits in, or nothing.
function code_reads(code, names)
    named = IdDict{JS.SyntaxNode,Module}()
    recorder = ReadRecorder(NameRead[], names, named)
    scope = opening_scope(nothing, 0, nothing)
    walk_scoped!(recorder, code, scope)
    recorder.reads
end

# Body references minus this method's bindings, plus the references in its defaults.
function absorb_method!(scan, signature, body, scope)
    open_target!(scan, scope.target)
    opened = read_scope(scope, scope.bound)
    absorb_defaults!(scan, signature, opened)
    bound = body_locals(signature, body, scope.bound)
    body_scope = read_scope(scope, bound)
    walk_scoped!(scan, body, body_scope)
end
