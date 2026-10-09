# Shared node helpers: children, source text, and a preorder walk.
const JS = Base.JuliaSyntax
using Base.JuliaSyntax: @K_str

is_module_block(node) = JS.kind(node) == K"module"

# Every walk takes children here. A module block's code belongs to that module, so a walk stops at one.
function child_nodes(node)
    is_module_block(node) && return nothing
    JS.children(node)
end

# A module block's name and its body: the one way into the code a walk stops at.
function module_name(block)::Union{Nothing,Symbol}
    parts = JS.children(block)
    node_symbol(parts[1])
end

function module_body(block)
    parts = JS.children(block)
    parts[2]
end

# The module blocks among a code root's own statements, docstring included. A block under a branch or a macro
# loads only on a condition, so the index leaves it unplaced.
function module_blocks(root)
    blocks = JS.SyntaxNode[]
    statements = child_nodes(root)
    isnothing(statements) && return blocks
    for statement in statements
        target = statement
        if JS.kind(statement) == K"doc"
            target = last(child_nodes(statement))
        end
        is_module_block(target) && push!(blocks, target)
    end
    blocks
end

# An identifier node's value. Anything else names no symbol.
function node_symbol(node)::Union{Nothing,Symbol}
    value = node.val
    value isa Symbol || return nothing
    value
end

# A node whose children are values: a call's arguments, a parameter list, a tuple's members.
function holds_values(kind)
    kind == K"call" || kind == K"parameters" || kind == K"tuple"
end

function source_line(node)
    location = JS.source_location(node)
    Int(location[1])
end

function needs_token_collapse(text)
    for char in text
        if char == '#' || char == '"' || char == '\'' || char == '`'
            return true
        end
    end
    false
end

function already_collapsed(text)
    isempty(text) && return true
    if isspace(first(text)) || isspace(last(text))
        return false
    end
    previous_space = false
    for char in text
        if isspace(char)
            if previous_space || char != ' '
                return false
            end
            previous_space = true
        else
            previous_space = false
        end
    end
    true
end

function collapse_plain(text)
    buffer = IOBuffer()
    pending_space = false
    started = false
    for char in text
        if isspace(char)
            if started
                pending_space = true
            end
        else
            if pending_space
                print(buffer, ' ')
                pending_space = false
            end
            print(buffer, char)
            started = true
        end
    end
    String(take!(buffer))
end

function collapsed_tokens(text)
    buffer = IOBuffer()
    pending_space = false
    started = false
    for token in JS.tokenize(text)
        kind = JS.kind(token)
        if kind == K"Comment"
            continue
        end
        if kind == K"Whitespace" || kind == K"NewlineWs"
            if started
                pending_space = true
            end
            continue
        end
        if pending_space
            print(buffer, ' ')
            pending_space = false
        end
        piece = JS.untokenize(token, text)
        print(buffer, piece)
        started = true
    end
    String(take!(buffer))
end

function collapse_source(text)::String
    if needs_token_collapse(text)
        return collapsed_tokens(text)
    end
    if already_collapsed(text)
        return String(text)
    end
    collapse_plain(text)
end

# The qualifier of a dotted name. False when the node is a dot of some other shape.
function walk_dot_base!(walk, node)
    children = child_nodes(node)
    (isnothing(children) || length(children) != 2) && return false
    walk(children[1])
    true
end

# A value child: the right-hand side of an assignment, otherwise the child itself.
function value_child(node)
    children = child_nodes(node)
    kind = JS.kind(node)
    if kind == K"=" && !isnothing(children) && length(children) == 2
        return children[2]
    end
    node
end

# The value each child carries: a keyword's right-hand side, otherwise the child.
function value_children(node)
    values = JS.SyntaxNode[]
    children = child_nodes(node)
    isnothing(children) && return values
    for child in children
        push!(values, value_child(child))
    end
    values
end

function walk_value_children!(walk, node)
    for child in value_children(node)
        walk(child)
    end
end

# Every symbol anywhere under a node, collected into `out`.
function all_symbols!(out, node)
    node.val isa Symbol && push!(out, node.val)
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        all_symbols!(out, child)
    end
end

# A 3-child call is infix only when the middle symbol is one of these operators.
# A 2-argument prefix call would otherwise read its second argument as the operator.
const INFIX_OPS = Set((:(<), :(>), :(<=), :(>=), :(==), :(!=), :+, :-, :*, :/))

function infix_op(node)
    JS.kind(node) == K"call" || return nothing
    children = child_nodes(node)
    (isnothing(children) || length(children) != 3) && return nothing
    children[2].val in INFIX_OPS ? children[2].val : nothing
end

# The body of a `function` form or a short-form definition: its second child.
function method_body(node)
    children = child_nodes(node)
    isnothing(children) && return nothing
    length(children) < 2 && return nothing
    children[2]
end

# A prefix call's own arguments, keyword block excluded.
function call_args(node)
    children = child_nodes(node)
    isnothing(children) && return Any[]
    found = Any[]
    for child in children[2:end]
        JS.kind(child) == K"parameters" && continue
        push!(found, child)
    end
    found
end

# Preorder over one subtree, leaving quote blocks out.
struct NodeWalk
    root::JS.SyntaxNode   # subtree the walk starts at
end

walk_nodes(root) = NodeWalk(root)

Base.IteratorSize(::Type{NodeWalk}) = Base.SizeUnknown()

Base.iterate(walk::NodeWalk) = iterate(walk, JS.SyntaxNode[walk.root])

# Children go on the stack last first, so the first child comes off next.
function Base.iterate(::NodeWalk, pending)
    while !isempty(pending)
        node = pop!(pending)
        JS.kind(node) == K"quote" && continue
        children = child_nodes(node)
        isnothing(children) || append!(pending, Iterators.reverse(children))
        return (node, pending)
    end
    nothing
end
