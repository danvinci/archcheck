# The branches this Julia decides while it loads, and what the code it runs includes and opens.

# A `v"..."` literal's version; nothing for any other node.
function version_literal(node)
    JS.kind(node) == K"macrocall" || return nothing
    children = child_nodes(node)
    child_count(children) == 2 || return nothing
    children[1].val === :v || return nothing
    text = static_string(children[2])
    isnothing(text) && return nothing
    tryparse(VersionNumber, text)
end

# The version a comparison operand stands for: the running Julia's `VERSION`, or a literal's.
function operand_version(node)
    node.val === :VERSION && return VERSION
    path = dotted_names(node)
    path == [:Base, :VERSION] && return VERSION
    version_literal(node)
end

function compare_versions(operator::Symbol, left::VersionNumber, right::VersionNumber)::Union{Nothing,Bool}
    operator === :< && return left < right
    operator === :<= && return left <= right
    operator === :> && return left > right
    operator === :>= && return left >= right
    operator === :(==) && return left == right
    operator === :!= && return left != right
    nothing
end

function version_comparison(node)::Union{Nothing,Bool}
    JS.is_infix_op_call(node) || return nothing
    children = child_nodes(node)
    child_count(children) == 3 || return nothing
    left = operand_version(children[1])
    right = operand_version(children[3])
    isnothing(left) && return nothing
    isnothing(right) && return nothing
    operator = node_symbol(children[2])
    isnothing(operator) && return nothing
    compare_versions(operator, left, right)
end

# `isdefined(Base, :name)` or `isdefined(Core, :name)`, answered by the running Julia.
function base_isdefined(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    child_count(children) == 3 || return nothing
    children[1].val === :isdefined || return nothing
    holder = children[2].val
    holder === :Base || holder === :Core || return nothing
    JS.kind(children[3]) == K"quote" || return nothing
    quoted = child_nodes(children[3])
    child_count(quoted) == 1 || return nothing
    name = node_symbol(quoted[1])
    isnothing(name) && return nothing
    loaded = holder === :Base ? Base : Core
    isdefined(loaded, name)
end

function static_and(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    left = static_condition(children[1])
    right = static_condition(children[2])
    left === false && return false
    right === false && return false
    left === true && return right
    nothing
end

function static_or(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    left = static_condition(children[1])
    right = static_condition(children[2])
    left === true && return true
    right === true && return true
    left === false && return right
    nothing
end

function static_not(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    child_count(children) == 2 || return nothing
    children[1].val === :! || return nothing
    operand = static_condition(children[2])
    isnothing(operand) && return nothing
    !operand
end

# The value an `if` condition takes on this Julia when a literal, a `VERSION` comparison or `isdefined` on Base or
# Core decides it; nothing when only the load can.
function static_condition(node)::Union{Nothing,Bool}
    value = node.val
    value isa Bool && return value
    kind = JS.kind(node)
    kind == K"&&" && return static_and(node)
    kind == K"||" && return static_or(node)
    kind == K"call" || return nothing
    JS.is_prefix_op_call(node) && return static_not(node)
    compared = version_comparison(node)
    isnothing(compared) || return compared
    base_isdefined(node)
end

# The parts of an `if` or `elseif` the load runs: the taken branch when this Julia decides the condition, else all.
function live_branches(node::JS.SyntaxNode)
    children = child_nodes(node)
    condition = static_condition(children[1])
    branches = children[2:end]
    isnothing(condition) && return branches
    condition && return branches[1:1]
    length(branches) < 2 && return JS.SyntaxNode[]
    rest = branches[2]
    JS.kind(rest) == K"elseif" && return live_branches(rest)
    [rest]
end

# The children the load runs: the live branches of a conditional, every child of anything else.
function live_children(node)
    kind = JS.kind(node)
    kind == K"if" && return live_branches(node)
    kind == K"elseif" && return live_branches(node)
    children = child_nodes(node)
    isnothing(children) && return JS.SyntaxNode[]
    children
end

# Whether a child of an `if` or `elseif` runs when this Julia loads it: the condition does, an `elseif` does unless an
# earlier condition is decided true, and a branch does when the load takes it.
function is_live_child(conditional, child)
    children = child_nodes(conditional)
    child === first(children) && return true
    if JS.kind(child) == K"elseif"
        condition = static_condition(first(children))
        return condition !== true
    end
    any(branch -> branch === child, live_branches(conditional))
end

# Whether `node` sits, below `root`, in a branch this Julia skips while it loads, judged by the load's own rule.
function in_skipped_branch(node, root)
    child = node
    current = node.parent
    while !isnothing(current) && child !== root
        kind = JS.kind(current)
        is_conditional = kind == K"if" || kind == K"elseif"
        is_conditional && !is_live_child(current, child) && return true
        child = current
        current = current.parent
    end
    false
end

# What loaded code includes and opens, in source order, past branches this Julia skips and method bodies, which
# include only when called.
function collect_live_events!(events, node)
    JS.kind(node) == K"quote" && return events
    is_method_form(node) && return events
    for child in live_children(node)
        if is_module_block(child) || is_include_call(child)
            push!(events, child)
        end
        collect_live_events!(events, child)
    end
    events
end

live_load_events(root) = collect_live_events!(JS.SyntaxNode[], root)
