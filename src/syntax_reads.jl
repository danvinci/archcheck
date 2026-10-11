# Every name one piece of code reads, recorded once at index build by the scoped walk: each bare name as Julia
# binds it, and each member read through a qualifier with the loaded module that qualifier names.

is_type_form(kind) = kind == K"struct" || kind == K"abstract" || kind == K"primitive"

# The name an identifier names, as Julia binds it: a macro's with its `@`, a string macro's with its suffix.
# A name an import clause writes names nothing.
function read_name(node)::Union{Nothing,Symbol}
    name = node_symbol(node)
    isnothing(name) && return nothing
    kind = JS.kind(node)
    kind == K"StrMacroName" && return Symbol("@", name, "_str")
    kind == K"CmdMacroName" && return Symbol("@", name, "_cmd")
    parent = node.parent
    isnothing(parent) && return name
    parent_kind = JS.kind(parent)
    parent_kind == K"importpath" && return nothing
    parent_kind == K"as" && return nothing
    parent_kind == K"macro_name" || return name
    holder = parent.parent
    !isnothing(holder) && JS.kind(holder) == K"importpath" && return nothing
    Symbol("@", name)
end

# A form around a field name that keeps it a name: the left of `x::T` and `x = v`, `const`, a docstring's subject.
function is_field_wrapper(parent, child)
    kind = JS.kind(parent)
    kind == K"const" && return true
    children = child_nodes(parent)
    child_count(children) == 0 && return false
    if kind == K"::" || kind == K"="
        return children[1] === child
    end
    if kind == K"doc"
        return last(children) === child
    end
    false
end

# A struct field's name, bare, typed, with a default, `const` or documented, in the struct's own block.
function is_field_name(node)
    current = node
    parent = node.parent
    while !isnothing(parent) && is_field_wrapper(parent, current)
        current = parent
        parent = parent.parent
    end
    isnothing(parent) && return false
    JS.kind(parent) == K"block" || return false
    holder = parent.parent
    isnothing(holder) && return false
    JS.kind(holder) == K"struct"
end

# The type parameters a type definition declares: `T` in `struct S{T<:Real} <: A{T}`.
function type_parameters(definition::JS.SyntaxNode)
    parameters = Symbol[]
    children = child_nodes(definition)
    child_count(children) == 0 && return parameters
    head = children[1]
    if JS.kind(head) == K"<:"
        head = first(child_nodes(head))
    end
    JS.kind(head) == K"curly" || return parameters
    declared = child_nodes(head)
    for parameter in declared[2:end]
        _argname!(parameters, parameter)
    end
    parameters
end

# The name a type definition's head declares: `S` in `struct S{T} <: A{T}`, its supertype left out.
function declared_type_head(definition)
    head = first(child_nodes(definition))
    JS.kind(head) == K"<:" || return head
    first(child_nodes(head))
end

# Whether `node` declares `name` where the scoped walk meets it: a struct field, a type's own name or parameter, or a
# `where` variable outside a signature. The walk binds a macro's arguments and locals itself.
function is_declared_name(node, name)
    is_field_name(node) && return true
    current = node.parent
    while !isnothing(current)
        kind = JS.kind(current)
        if kind == K"where"
            variables = Symbol[]
            where_vars!(variables, current)
            name in variables && return true
        elseif is_type_form(kind)
            name in type_parameters(current) && return true
            head = declared_type_head(current)
            is_own_name = type_name(head) === name && node_inside(node, head)
            is_own_name && return true
        end
        current = current.parent
    end
    false
end

function note_free_name!(walk::CodeWalk, node, scope, in_export = false)
    name = read_name(node)
    isnothing(name) && return
    binding = get(scope.bound.declared, name, nothing)
    if !isnothing(binding)
        note_local_read!(walk, node, name, binding, scope)
        return
    end
    is_declared_name(node, name) && return
    line = source_line(node)
    is_quoted = is_lone_quote(node)
    read = NameRead(name, nothing, nothing, nothing, scope.target, scope.method, line, scope.in_signature, in_export,
                    is_quoted)
    push!(walk.scan.reads, read)
end

# A local read names the binding it resolves to; the declaring identifier itself reads none. A quoted symbol counts,
# since code built from it may read the local.
function note_local_read!(walk::CodeWalk, node, name, binding, scope)
    binding === node && return
    walk.scan.resolved[node] = binding
    line = source_line(node)
    read = NameRead(name, binding, nothing, nothing, scope.target, scope.method, line, scope.in_signature, false, false)
    push!(walk.scan.reads, read)
end

# A symbol quoted alone, `:name`.
function is_lone_quote(node)
    parent = node.parent
    isnothing(parent) && return false
    JS.kind(parent) == K"quote" || return false
    quoted = child_nodes(parent)
    child_count(quoted) == 1
end

# A member read through a qualifier that can name a module, with the module it names; a module the member itself
# names is kept for the dotted path around it.
function note_member!(walk::CodeWalk, scope, dot, qualifier, member)
    is_module_path(qualifier, scope.bound) || return
    through = qualifier_module(walk, qualifier)
    if !isnothing(through)
        reached = bound_module(through, member)
        if !isnothing(reached)
            walk.named[dot] = reached
        end
    end
    line = source_line(dot)
    read = NameRead(member, nothing, qualifier, through, scope.target, scope.method, line, scope.in_signature, false,
                    false)
    push!(walk.scan.reads, read)
end
