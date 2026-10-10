# Signatures: the name a method defines, the names and types it binds.

"""The locals one scope binds, each with the identifier that declares the binding the name resolves to there."""
struct Bindings
    declared::Dict{Symbol,JS.SyntaxNode}   # name -> its declaring identifier
end

Bindings() = Bindings(Dict{Symbol,JS.SyntaxNode}())

Base.in(name::Symbol, bound::Bindings) = haskey(bound.declared, name)
Base.copy(bound::Bindings) = Bindings(copy(bound.declared))
Base.empty(::Bindings) = Bindings()

# A binder declares a new binding, which shadows one the scope around it holds.
function Base.union!(bound::Bindings, extra::Bindings)
    merge!(bound.declared, extra.declared)
    bound
end

function Base.setdiff!(bound::Bindings, names::Vector{Symbol})
    for name in names
        delete!(bound.declared, name)
    end
    bound
end

# A plain name set keeps the name; a scope's bindings keep the identifier that declares it.
declare!(names, node) = push!(names, node.val)

function declare!(bound::Bindings, node)
    bound.declared[node.val] = node
    bound
end

"""The names one scope's own statements bind: assignments, each at its first assignment, and `local` lines."""
struct Assigned{S}
    assigned::S   # names assignments bind
    declared::S   # names a `local` line declares
end

function assignments(bound)
    assigned = empty(bound)
    declared = empty(bound)
    Assigned(assigned, declared)
end

function declare!(found::Assigned{Bindings}, node)
    get!(found.assigned.declared, node.val, node)
    found
end

declare!(found::Assigned, node) = declare!(found.assigned, node)

# An assignment reuses a binding an enclosing local scope holds; a `local` line makes a new one.
function adopt!(bound, found::Assigned)
    union!(bound, found.declared)
    adopt_assigned!(bound, found.assigned)
end

adopt_assigned!(bound, assigned) = union!(bound, assigned)

function adopt_assigned!(bound::Bindings, assigned::Bindings)
    for (name, node) in assigned.declared
        get!(bound.declared, name, node)
    end
    bound
end

# A call, a `where` wrapping a call, or a return type on a call (`f(x)::T`).
# `x::T` is a typed binding.
function is_sig(node)
    kind = JS.kind(node)
    kind == K"call" && return true
    is_wrapper = kind == K"where" || kind == K"::"
    is_wrapper || return false
    children = child_nodes(node)
    child_count(children) == 0 && return false
    is_sig(children[1])
end

# The call inside a signature, past `where` clauses and a return type.
function signature_call(signature)
    node = signature
    while JS.kind(node) == K"where" || JS.kind(node) == K"::"
        children = child_nodes(node)
        child_count(children) == 0 && return nothing
        node = first(children)
    end
    JS.kind(node) == K"call" || return nothing
    node
end

# The head and the arguments of a signature's call; nothing past a `where`, a return type, or a bare binding.
function call_parts(signature)
    call = signature_call(signature)
    isnothing(call) && return nothing
    children = child_nodes(call)
    child_count(children) == 0 && return nothing
    (head = children[1], arguments = children[2:end])
end

# A type name, unwrapping `<:` and `{}` to the bare identifier.
function type_name(node)::Union{Nothing,Symbol}
    named = node_symbol(node)
    isnothing(named) || return named
    children = child_nodes(node)
    child_count(children) == 0 && return nothing
    kind = JS.kind(node)
    kind == K"<:" || kind == K"curly" || return nothing
    type_name(children[1])
end

# The name a signature defines. A dotted head (`M.getindex`) is a method on another module's generic:
# the dispatch that reaches it belongs to that module, so this module does not own the name.
function sig_name(signature)::Union{Nothing,Symbol}
    parts = call_parts(signature)
    isnothing(parts) && return nothing
    head = parts.head
    named = node_symbol(head)
    isnothing(named) || return named
    JS.kind(head) == K"curly" || return nothing
    type_name(head)
end

# A curly head (`T{P}(x) = ...`) adds a constructor method to the type `T` already bound, so it binds no name.
function is_type_constructor(signature)
    parts = call_parts(signature)
    isnothing(parts) && return false
    JS.kind(parts.head) == K"curly"
end

# The member a dotted head writes quoted, `-` in `Base.:-` and in `Base.:(-)`; nothing for a bare member.
function quoted_member(head)
    children = child_nodes(head)
    child_count(children) == 2 || return nothing
    member = children[2]
    JS.kind(member) == K"quote" || return nothing
    quoted = child_nodes(member)
    child_count(quoted) == 1 || return nothing
    node_symbol(only(quoted))
end

# A qualified generic identifies a method site without declaring a locally owned function. A quoted member is named
# bare, `Base.-`, as the loaded method's name reads.
function qualified_method_name(signature)
    parts = call_parts(signature)
    isnothing(parts) && return nothing
    head = parts.head
    JS.kind(head) == K"." || return nothing
    member = quoted_member(head)
    if isnothing(member)
        text = JS.sourcetext(head)
        return Symbol(text)
    end
    qualifier = first(child_nodes(head))
    qualifier_text = JS.sourcetext(qualifier)
    Symbol(qualifier_text, ".", member)
end

# Receiver type of `(x::T)(...)` and `(::T)(...)`.
function callable_receiver(signature)
    parts = call_parts(signature)
    isnothing(parts) && return nothing
    head = parts.head
    JS.kind(head) == K"::" || return nothing
    head_children = child_nodes(head)
    child_count(head_children) == 0 && return nothing
    type_name(last(head_children))
end

# The declared type of one positional argument. `nothing` means the argument is untyped.
function argtype_of(argument)
    kind = JS.kind(argument)
    if kind == K"::"
        children = child_nodes(argument)
        return type_name(last(children))
    end
    if kind == K"=" || kind == K"..."
        children = child_nodes(argument)
        inner = first(children)
        return argtype_of(inner)
    end
    nothing
end

# The one name a positional argument binds at its slot. A splat, a destructured tuple and a bare `::T` bind none.
function argname_of(argument)
    JS.kind(argument) == K"..." && return nothing
    names = Symbol[]
    _argname!(names, argument)
    length(names) == 1 || return nothing
    only(names)
end

# One reading per positional argument, in order. The keyword block is skipped.
function read_positionals(read, signature)
    found = Union{Symbol,Nothing}[]
    parts = call_parts(signature)
    isnothing(parts) && return found
    for argument in parts.arguments
        JS.kind(argument) == K"parameters" && continue
        value = read(argument)
        push!(found, value)
    end
    found
end

# The name bound by the first child of a bound, a default, or a splat.
function named_head!(names, node)
    children = child_nodes(node)
    child_count(children) == 0 && return
    _argname!(names, children[1])
end

# The name a macro call calls, bare or qualified, with its `@`.
function macro_call_name(call)
    head = first(child_nodes(call))
    if JS.kind(head) == K"."
        head = last(child_nodes(head))
    end
    named_symbol(head)
end

# `@nospecialize(x)` or `@specialize(x)`: compiler hints that leave `x` the argument it names.
function is_argument_hint(node)
    JS.kind(node) == K"macrocall" || return false
    name = macro_call_name(node)
    name === Symbol("@nospecialize") || name === Symbol("@specialize")
end

# A scope's bindings see through a hint to the argument it names. A plain name set keeps the hinted name out, as the
# checks reading one were built on.
hinted_argname!(_names, _node) = nothing

function hinted_argname!(names::Union{Bindings,Assigned{Bindings}}, node)
    children = child_nodes(node)
    child_count(children) == 2 || return
    _argname!(names, children[2])
end

# The parameter names a signature binds. Inside the body these shadow any module name,
# so a body mentioning one is reading its own local.
function _argname!(names, node)
    kind = JS.kind(node)
    is_argument_hint(node) && return hinted_argname!(names, node)
    if kind == K"parameters" || kind == K"tuple" || kind == K"braces"
        children = child_nodes(node)
        isnothing(children) && return
        for child in children
            _argname!(names, child)
        end
        return
    end
    if kind == K"::"
        children = child_nodes(node)
        child_count(children) < 2 && return
        _argname!(names, children[1])
        return
    end
    if kind == K"<:" || kind == K">:" || kind == K"=" || kind == K"..."
        named_head!(names, node)
        return
    end
    node.val isa Symbol && declare!(names, node)
    nothing
end

# The identifier a type name sits in, unwrapping `<:` and `{}` to the bare identifier.
function type_name_node(node)
    isnothing(node_symbol(node)) || return node
    children = child_nodes(node)
    child_count(children) == 0 && return nothing
    kind = JS.kind(node)
    kind == K"<:" || kind == K"curly" || return nothing
    type_name_node(children[1])
end

# Declares the name a signature defines at its identifier: a bare head, or the type a curly head names.
function declare_sig_name!(names, signature)
    parts = call_parts(signature)
    isnothing(parts) && return
    head = parts.head
    if JS.kind(head) == K"curly"
        head = type_name_node(head)
    end
    isnothing(head) && return
    isnothing(node_symbol(head)) && return
    declare!(names, head)
end

# Type variables on `where` clauses, including nested and bounded (`T<:Integer`) forms.
function where_vars!(names, signature)
    kind = JS.kind(signature)
    if kind == K"::"
        inner = child_nodes(signature)[1]
        where_vars!(names, inner)
        return
    end
    kind == K"where" || return
    children = child_nodes(signature)
    isnothing(children) && return
    where_vars!(names, children[1])
    for variable in children[2:end]
        _argname!(names, variable)
    end
end

# A callable's receiver, `(x::T)(...)`, binds `x` the way an argument does.
function bind_receiver!(names, head)
    JS.kind(head) == K"::" || return
    _argname!(names, head)
end

# The names a signature's call binds: a callable's receiver and every argument.
function call_argnames!(names, parts)
    bind_receiver!(names, parts.head)
    for argument in parts.arguments
        _argname!(names, argument)
    end
    names
end

# The names a signature binds: `where` variables, a callable's receiver, and every argument.
function sig_argnames!(names, signature)
    where_vars!(names, signature)
    parts = call_parts(signature)
    isnothing(parts) && return names
    call_argnames!(names, parts)
end

sig_argnames(signature) = sig_argnames!(Symbol[], signature)

function is_method_form(node)
    kind = JS.kind(node)
    kind == K"function" && return true
    kind == K"=" || return false
    children = child_nodes(node)
    child_count(children) == 0 && return false
    is_sig(children[1])
end
