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
    bound::Bindings                         # names bound in this scope, each at its declaring identifier
    depth::Int                              # function-def nesting
    loop_depth::Int                         # repeating for, while and generator scopes around the node
    site::Union{Nothing,MethodSite}         # method the calls belong to; nothing on a name-resolution walk
    discarded::Bool                         # this node's value is discarded
    method::Union{Nothing,JS.SyntaxNode}    # outermost method, macro or closure form around the node
    in_signature::Bool                      # the node sits in a signature's annotations, run where the method is defined
end

# A scope at the top of a walk: no locals, no loop, no method around it.
function opening_scope(target, depth, site)
    ScanScope(target, Bindings(), depth, 0, site, false, nothing, false)
end

# A form whose first child declares arguments: a method, a macro, or a closure.
function is_argument_form(node)
    is_method_form(node) && return true
    kind = JS.kind(node)
    kind == K"macro" || kind == K"->" || kind == K"do"
end

# The identifier a signature names its method by, as a local method binds it.
function is_method_name(signature, node)
    found = Bindings()
    declare_sig_name!(found, signature)
    any(declared -> declared === node, values(found.declared))
end

# Where a declaring identifier sits: a `where` variable, the name of a local method, an argument of the nearest
# method, macro or closure, or a local of its body.
function binding_kind(node)
    child = node
    current = node.parent
    while !isnothing(current)
        children = child_nodes(current)
        is_first = child_count(children) > 0 && children[1] === child
        JS.kind(current) == K"where" && !is_first && return :parameter
        if is_argument_form(current)
            is_first && is_method_name(children[1], node) && return :function
            return is_first ? :argument : :local
        end
        child = current
        current = current.parent
    end
    :local
end

# Files each binding `inner` holds that `outer` does not, once: the scope entering it opens it.
function open_bindings!(walk, outer::Bindings, inner::Bindings, scope)
    filed = walk.filed
    for (name, node) in inner.declared
        get(outer.declared, name, nothing) === node && continue
        node in filed && continue
        push!(filed, node)
        walk.scan.resolved[node] = node
        line = source_line(node)
        kind = binding_kind(node)
        binding = LocalBinding(name, node, line, kind, scope.target, scope.method)
        push!(walk.scan.bindings, binding)
    end
end

# The scope inside a method form: the outermost form stays the method every read inside it belongs to.
function retarget(scope::ScanScope, target, bound, form)
    method = isnothing(scope.method) ? form : scope.method
    ScanScope(target, bound, scope.depth + 1, scope.loop_depth, scope.site, false, method, scope.in_signature)
end

function entered_scope(walk, scope, node, index, depth, fn_depth)
    bound = child_locals(node, index, scope.bound)
    open_bindings!(walk, scope.bound, bound, scope)
    discarded = child_discarded(node, index, scope.discarded)
    ScanScope(scope.target, bound, fn_depth, depth, scope.site, discarded, scope.method, scope.in_signature)
end

function entered_scope(walk, scope, node, index)
    entered_scope(walk, scope, node, index, scope.loop_depth, scope.depth)
end

function read_scope(scope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site, false, scope.method, scope.in_signature)
end

function signature_scope(scope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site, false, scope.method, true)
end

function walk_iteration!(scan, node::JS.SyntaxNode, scope)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if kind == K"in" || kind == K"="
        for index in 2:lastindex(children)
            child_scope = entered_scope(scan, scope, node, index)
            walk_scoped!(scan, children[index], child_scope)
        end
        return
    end
    for index in eachindex(children)
        child_scope = entered_scope(scan, scope, node, index)
        walk_iteration!(scan, children[index], child_scope)
    end
end

# The parts of an assignment's left side that read names: a type annotation, an index target, a property
# base. A bare binding reads nothing; a macro around one, as `@nospecialize(x::T)`, reads what its argument does.
function collect_lhs!(found, node::JS.SyntaxNode)
    children = child_nodes(node)
    isnothing(children) && return found
    kind = JS.kind(node)
    if kind == K"::"
        isempty(children) || push!(found, last(children))
    elseif kind == K"." || kind == K"ref" || kind == K"call" || kind == K"dotcall" || kind == K"$"
        push!(found, node)
    elseif kind == K"=" || kind == K"..."
        isempty(children) || collect_lhs!(found, children[1])
    elseif kind == K"tuple" || kind == K"parameters"
        for child in children
            collect_lhs!(found, child)
        end
    elseif kind == K"curly"
        # A parametric alias, `A{T<:B} = ...`, declares its parameters and reads each bound.
        for parameter in children[2:end]
            is_bounded = JS.kind(parameter) == K"<:" || JS.kind(parameter) == K">:"
            is_bounded && push!(found, last(child_nodes(parameter)))
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

# An assignment's bare targets name the local they assign. A `let` binding resolves here to the local it shadows
# until the scope entering the `let` body files it as its own.
function note_targets!(walk, lhs, scope)
    targets = JS.SyntaxNode[]
    _argname!(targets, lhs)
    for target in targets
        name = target.val::Symbol
        binding = get(scope.bound.declared, name, nothing)
        isnothing(binding) && continue
        get!(walk.scan.resolved, target, binding)
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
        child_scope = entered_scope(scan, scope, node, index, depth, scope.depth)
        if clause
            walk_iteration!(scan, child, child_scope)
        else
            walk_scoped!(scan, child, child_scope)
        end
    end
end

"""The one scoped walk over a piece of code: the scan it fills, and what a qualifier resolves against."""
struct CodeWalk{N}
    scan::FileScan                        # the defs, calls and reads the walk records
    names::N                              # what a bare name binds where the code sits: a loaded module, a script's names, or nothing
    named::IdDict{JS.SyntaxNode,Module}   # each dotted qualifier already met -> the loaded module it names
    filed::IdSet{JS.SyntaxNode}           # declaring identifiers whose binding the scan already holds
end

# The walk's read recorders, and its recorders of import clauses and module aliases, each defined beside the module
# lookup it resolves paths with.
function note_free_name! end
function note_member! end
function note_import! end
function note_alias! end

# A definition's refs set exists once the walk opens it, read or not.
function open_target!(walk::CodeWalk, target)
    isnothing(target) && return
    get!(Set{Symbol}, walk.scan.refs, target)
end

function scope_children!(scan, node, scope)
    children = child_nodes(node)
    isnothing(children) && return
    for index in eachindex(children)
        child_scope = entered_scope(scan, scope, node, index)
        walk_scoped!(scan, children[index], child_scope)
    end
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
    # A spliced member, `a.$name`, reads the name it splices.
    if JS.kind(children[2]) == K"$"
        walk_scoped!(scan, children[2], scope)
        return
    end
    member = named_symbol(children[2])
    isnothing(member) && return
    note_member!(scan, scope, node, children[1], member)
end

# A method nested in a method already on `scope.site` gets its own form.
# Calls inside it stay on the enclosing site.
function record_nested_form!(walk::CodeWalk, node, scope)
    isnothing(scope.site) && return
    children = child_nodes(node)
    child_count(children) == 0 && return
    name = sig_name(children[1])
    isnothing(name) && return
    line = source_line(node)
    site = MethodSite(name, line)
    forms = walk.scan.forms
    haskey(forms, site) && return
    forms[site] = node
end

# Slot count when a body's final expression is a bare tuple. A named tuple names its slots, so 0.
function tuple_tail_slots(body)
    tail = body
    if JS.kind(tail) == K"block"
        children = child_nodes(tail)
        child_count(children) == 0 && return 0
        tail = last(children)
    end
    if JS.kind(tail) == K"return"
        children = child_nodes(tail)
        child_count(children) == 0 && return 0
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

# A function the code defines outside any other: its name, line and tuple tail.
function record_top_method!(scan::FileScan, name, line, children)
    push!(scan.funcs, name)
    scan.line[name] = line
    get!(Set{Symbol}, scan.refs, name)
    if is_type_constructor(children[1])
        push!(scan.constructors, name)
    end
    slots = tuple_tail_slots(children[2])
    slots > 0 || return
    scan.tupletail[name] = slots
end

# The name a method's calls are filed under: a top-level function's, a qualified generic's, a callable's receiver
# type, or the type whose block holds an inner constructor. A method that is none of these has no site of its own.
function method_owner(signature, name, top, current)
    top && return name
    qualified = qualified_method_name(signature)
    isnothing(qualified) || return qualified
    receiver = callable_receiver(signature)
    isnothing(receiver) || return receiver
    current
end

# Inside a method already on a site: the calls stay there, and a callable's method files its reads under its type.
function nested_method_scope(walk::CodeWalk, scope, signature, form)
    receiver = callable_receiver(signature)
    isnothing(receiver) && return retarget(scope, scope.target, scope.bound, form)
    open_target!(walk, receiver)
    retarget(scope, receiver, Bindings(), form)
end

# A method outside any other opens a site under its owner, where its calls and forms are filed.
function method_scope(walk::CodeWalk, scope, node, children)
    signature = children[1]
    name = sig_name(signature)
    top = scope.depth == 0 && !isnothing(name)
    line = source_line(node)
    if top
        record_top_method!(walk.scan, name, line, children)
    end
    owner = method_owner(signature, name, top, scope.target)
    isnothing(owner) && return retarget(scope, scope.target, scope.bound, node)
    site = MethodSite(owner, line)
    walk.scan.forms[site] = node
    open_target!(walk, owner)
    receiver = callable_receiver(signature)
    bound = isnothing(receiver) ? scope.bound : Bindings()
    method = isnothing(scope.method) ? node : scope.method
    ScanScope(owner, bound, scope.depth + 1, 0, site, false, method, scope.in_signature)
end

function scope_method!(walk::CodeWalk, node, scope)
    record_nested_form!(walk, node, scope)
    children = child_nodes(node)
    child_count(children) < 2 && return
    signature = children[1]
    body = children[2]
    if isnothing(scope.site)
        inner = method_scope(walk, scope, node, children)
    else
        inner = nested_method_scope(walk, scope, signature, node)
    end
    absorb_method!(walk, signature, body, inner)
end

# A type definition: at the top it records the type and files its supertype, field and constructor reads under it.
function scope_type!(walk::CodeWalk, node, scope)
    children = child_nodes(node)
    child_count(children) == 0 && return
    name = type_name(first(children))
    target = scope.target
    if scope.depth == 0 && !isnothing(name)
        scan = walk.scan
        push!(scan.types, name)
        scan.line[name] = source_line(node)
        open_target!(walk, name)
        target = name
    end
    inner = ScanScope(target, scope.bound, scope.depth + 1, scope.loop_depth, scope.site, false, scope.method,
                      scope.in_signature)
    for child in children
        walk_scoped!(walk, child, inner)
    end
end

# A `const` line at the top of the code binds a name: one naming a module is an alias of it.
function scope_const!(walk::CodeWalk, node, scope)
    scope_plain!(walk, node, scope)
    isnothing(scope.method) || return
    note_alias!(walk, node)
end

# A macro's arguments and the names its body assigns are its own; its name is no read.
function scope_macro!(scan, node::JS.SyntaxNode, scope)
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
    open_bindings!(scan, inner.bound, bound, inner)
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
    open_bindings!(scan, scope.bound, body_bound, closed)
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
        child_scope = entered_scope(scan, scope, node, index, depth, scope.depth)
        header =kind == K"for" && index != last_index
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

function scope_generator!(scan, node::JS.SyntaxNode, scope)
    children = child_nodes(node)
    child_count(children) == 0 && return
    interior = scope.loop_depth + 1
    for index in 2:length(children)
        depth = scope.loop_depth
        if index > 2
            depth = interior
        end
        child_scope = entered_scope(scan, scope, node, index, depth, scope.depth)
        walk_gen_spec!(scan, children[index], child_scope, interior)
    end
    element_scope = entered_scope(scan, scope, node, 1, interior, scope.depth)
    walk_scoped!(scan, children[1], element_scope)
end

# A `global` method defines a module function wherever it is written, a struct body or a function included, so it
# opens at the top; a `local` one stays nested where it is.
function scope_declaration!(scan, node, scope)
    children = child_nodes(node)
    isnothing(children) && return
    is_global = JS.kind(node) == K"global"
    for declaration in children
        if is_method_form(declaration)
            method_scope = is_global ? opening_scope(nothing, 0, nothing) : scope
            walk_scoped!(scan, declaration, method_scope)
        elseif JS.kind(declaration) == K"="
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
    note_targets!(scan, children[1], scope)
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
    elseif kind == K"struct" || kind == K"abstract"
        scope_type!(scan, node, scope)
    elseif kind == K"using" || kind == K"import"
        note_import!(scan, node, scope)
    elseif kind == K"const"
        scope_const!(scan, node, scope)
    elseif kind == K"export" || kind == K"public"
        scope_export!(scan, node, scope)
    elseif kind == K"="
        scope_assign!(scan, node, scope)
    elseif kind == K"call" || kind == K"dotcall" || kind == K"parameters" || kind == K"tuple"
        scope_call!(scan, node, scope)
    else
        scope_plain!(scan, node, scope)
    end
end

# `where` and return-type wrappers unwrap; their annotations are signature reads.
function unwrap_signature!(scan, signature::JS.SyntaxNode, noted)
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
function absorb_defaults!(scan, signature::JS.SyntaxNode, scope)
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

# An export or public line lists names it publishes, each a use of the binding it names.
function scope_export!(walk::CodeWalk, node, scope)
    for listed in child_nodes(node)
        named = listed
        kind = JS.kind(listed)
        if kind == K"macro_name" || kind == K"var"
            named = first(child_nodes(listed))
        end
        note_free_name!(walk, named, scope, true)
    end
end

# Every definition `code` makes and every name it reads, each qualifier resolved against `names`: the loaded module
# the code sits in, an entry script's names, or nothing.
function scan_tree(code, names)
    scan = empty_scan()
    named = IdDict{JS.SyntaxNode,Module}()
    filed = IdSet{JS.SyntaxNode}()
    walk = CodeWalk(scan, names, named, filed)
    scope = opening_scope(nothing, 0, nothing)
    walk_scoped!(walk, code, scope)
    scan
end

# Body references minus this method's bindings, plus the references in its defaults.
function absorb_method!(scan, signature, body, scope)
    opened = read_scope(scope, scope.bound)
    absorb_defaults!(scan, signature, opened)
    bound = body_locals(signature, body, scope.bound)
    open_bindings!(scan, scope.bound, bound, scope)
    body_scope = read_scope(scope, bound)
    walk_scoped!(scan, body, body_scope)
end
