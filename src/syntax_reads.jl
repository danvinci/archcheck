# Every name one piece of code reads, recorded once at index build by the scoped walk: each bare name as Julia
# binds it, and each member read through a qualifier with the loaded module that qualifier names.

# Code no loaded module holds binds no module by name.
bound_module(::Nothing, name::Symbol) = nothing

# The recorder files reads in a flat list, so no def opens a set.
open_target!(::ReadRecorder, target) = nothing

is_type_form(kind) = kind == K"struct" || kind == K"abstract" || kind == K"primitive"

# The name an identifier reads, as Julia binds it: a macro's with its `@`, a string macro's with its suffix.
# A name an import clause writes and a lone quoted symbol read nothing.
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
    if parent_kind == K"quote"
        quoted = child_nodes(parent)
        child_count(quoted) == 1 && return nothing
    end
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
function type_parameters(definition)
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

# Whether `node` declares `name` where the scoped walk meets it: a struct field, a type's parameter, or a `where`
# variable outside a signature. The walk binds a macro's arguments and locals itself.
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
        end
        current = current.parent
    end
    false
end

function note_free_name!(recorder::ReadRecorder, node, scope)
    name = read_name(node)
    isnothing(name) && return
    name in scope.bound && return
    is_declared_name(node, name) && return
    line = source_line(node)
    read = NameRead(name, nothing, nothing, scope.target, scope.method, line, scope.in_signature)
    push!(recorder.reads, read)
end

# The loaded module a qualifier names: a bare name's binding where the code sits, or the module a dotted qualifier
# met earlier in the walk named.
function qualifier_module(recorder::ReadRecorder, qualifier)
    name = node_symbol(qualifier)
    isnothing(name) || return bound_module(recorder.names, name)
    get(recorder.named, qualifier, nothing)
end

# A member read through a qualifier that can name a module, with the module it names; a module the member itself
# names is kept for the dotted path around it.
function note_member!(recorder::ReadRecorder, scope, dot, qualifier, member)
    is_module_path(qualifier, scope.bound) || return
    through = qualifier_module(recorder, qualifier)
    if !isnothing(through)
        reached = bound_module(through, member)
        if !isnothing(reached)
            recorder.named[dot] = reached
        end
    end
    line = source_line(dot)
    read = NameRead(member, qualifier, through, scope.target, scope.method, line, scope.in_signature)
    push!(recorder.reads, read)
end
