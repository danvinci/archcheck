# Signatures: the name a method defines, the names and types it binds.

# A call, a `where` wrapping a call, or a return type on a call (`f(x)::T`).
# `x::T` is a typed binding.
function is_sig(node)
    kind = JS.kind(node)
    kind == K"call" && return true
    is_wrapper = kind == K"where" || kind == K"::"
    is_wrapper || return false
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return false
    is_sig(children[1])
end

# The call inside a signature, past `where` clauses and a return type.
function signature_call(signature)
    node = signature
    while JS.kind(node) == K"where" || JS.kind(node) == K"::"
        children = child_nodes(node)
        (isnothing(children) || isempty(children)) && return nothing
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
    (isnothing(children) || isempty(children)) && return nothing
    (head = children[1], arguments = children[2:end])
end

# A struct body allows inner constructors only: a `function` form, or a short-form method.
# A typed field default (`x::T = v`) is a signature-shaped assignment and stays a field.
function is_inner_constructor(node)
    kind = JS.kind(node)
    kind == K"function" && return true
    kind == K"=" || return false
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return false
    signature = children[1]
    is_sig(signature) || return false
    named = sig_name(signature)
    !isnothing(named)
end

# A type name, unwrapping `<:` and `{}` to the bare identifier.
function type_name(node)::Union{Nothing,Symbol}
    named = node_symbol(node)
    isnothing(named) || return named
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return nothing
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

# A qualified generic identifies a method site without declaring a locally owned function.
function qualified_method_name(signature)
    parts = call_parts(signature)
    isnothing(parts) && return nothing
    JS.kind(parts.head) == K"." || return nothing
    text = JS.sourcetext(parts.head)
    Symbol(text)
end

# Receiver type of `(x::T)(...)` and `(::T)(...)`.
function callable_receiver(signature)
    parts = call_parts(signature)
    isnothing(parts) && return nothing
    head = parts.head
    JS.kind(head) == K"::" || return nothing
    head_children = child_nodes(head)
    (isnothing(head_children) || isempty(head_children)) && return nothing
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

# Positional-argument declared types. The keyword block is skipped.
function sig_argtypes(signature)
    found = Union{Symbol,Nothing}[]
    parts = call_parts(signature)
    isnothing(parts) && return found
    for argument in parts.arguments
        JS.kind(argument) == K"parameters" && continue
        declared = argtype_of(argument)
        push!(found, declared)
    end
    found
end

# The name bound by the first child of a bound, a default, or a splat.
function named_head!(names, node)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return
    _argname!(names, children[1])
end

# The parameter names a signature binds. Inside the body these shadow any module name,
# so a body mentioning one is reading its own local.
function _argname!(names, node)
    kind = JS.kind(node)
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
        short = isnothing(children) || length(children) < 2
        short && return
        _argname!(names, children[1])
        return
    end
    if kind == K"<:" || kind == K">:" || kind == K"=" || kind == K"..."
        named_head!(names, node)
        return
    end
    node.val isa Symbol && push!(names, node.val)
    nothing
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

# The names a signature binds: `where` variables, a callable's receiver, and every argument.
function sig_argnames(signature)
    names = Symbol[]
    where_vars!(names, signature)
    parts = call_parts(signature)
    isnothing(parts) && return names
    bind_receiver!(names, parts.head)
    for argument in parts.arguments
        _argname!(names, argument)
    end
    names
end

function is_method_form(node)
    kind = JS.kind(node)
    kind == K"function" && return true
    kind == K"=" || return false
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return false
    is_sig(children[1])
end
