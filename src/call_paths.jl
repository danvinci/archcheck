# Which calls in one method can run on one path.
# An if, elseif, else, or ternary arm is exclusive of its siblings.
# A branch that returns is exclusive of every call after it.
# The kind test builds one concrete marker and calls its method.
# A marker returned as a union would dispatch at runtime inside the gate.

struct WalkedCall
    callee::Symbol                    # called name
    qualifier::String                 # module path written before the name
    arguments::String                 # positional argument text
    keywords::String                  # keyword argument text
    line::Int                         # source line
    inside::Vector{Tuple{Int,Int}}    # (split, arm) pairs of the arms that hold the call
    exits::Vector{Tuple{Int,Int}}     # (split, arm) pairs of returning arms behind the call
    is_dead::Bool                     # a return on every path stands before the call
    bindings::Vector{Int}             # per name the call passes, in source order: the id of its last binding
end

struct PlacedCall
    call::CallSite                    # scanned call, scanner order
    inside::Vector{Tuple{Int,Int}}    # (split, arm) pairs of the arms that hold the call
    exits::Vector{Tuple{Int,Int}}     # (split, arm) pairs of returning arms behind the call
    is_dead::Bool                     # a return on every path stands before the call
    bindings::Vector{Int}             # per name the call passes, in source order: the id of its last binding
end

struct WalkFollow
    returns::Bool                      # every path through the node returns
    exits::Vector{Tuple{Int,Int}}      # returning arms a call after this node is past
end

struct CallWalk
    found::Vector{WalkedCall}          # calls in the order the scanner records them
    splits::Base.RefValue{Int}         # next id for an exclusive split
    marks::Base.RefValue{Int}          # next id for a binding
    bindings::Dict{Symbol,Int}         # name -> id of the loop or assignment that last bound it; 0 for none
    loops::Dict{Tuple{String,Vector{Int}},Int}   # a loop clause's text and its collection's binding ids -> its id
end

# `K` names the walk for one node kind.
struct WalkOf{K} end

struct NodeStep end
struct IterationStep end

function CallWalk()
    found = WalkedCall[]
    splits = Ref(1)
    marks = Ref(1)
    bindings = Dict{Symbol,Int}()
    loops = Dict{Tuple{String,Vector{Int}},Int}()
    CallWalk(found, splits, marks, bindings, loops)
end

function next_id!(counter::Base.RefValue{Int})
    id = counter[]
    counter[] = id + 1
    id
end

fresh_split(walk) = next_id!(walk.splits)

fresh_mark(walk) = next_id!(walk.marks)

function with_arm(tags, split, arm)
    extended = copy(tags)
    push!(extended, (split, arm))
    extended
end

function merge_exits(left, right)
    found = copy(left)
    for tag in right
        tag in found && continue
        push!(found, tag)
    end
    found
end

function record_binding!(walk, target, mark)
    names = Symbol[]
    _argname!(names, target)
    for name in names
        walk.bindings[name] = mark
    end
    nothing
end

function marks_of(walk, nodes)
    names = Symbol[]
    for node in nodes
        all_symbols!(names, node)
    end
    marks = Int[]
    for name in names
        mark = get(walk.bindings, name, 0)
        push!(marks, mark)
    end
    marks
end

# Two loops bind the same values when their clauses read alike and the collection's names are bound alike.
function loop_mark(walk, clause, collection)
    raw = JS.sourcetext(clause)
    text = collapse_source(raw)
    marks = marks_of(walk, collection)
    key = (text, marks)
    get!(() -> fresh_mark(walk), walk.loops, key)
end

function note_call!(walk, node, inside, exits, is_dead)
    naming = called_name(node)
    isnothing(naming) && return
    callee = naming.callee
    qualifier = naming.qualifier
    arguments = arguments_text(node)
    keywords = keywords_text(node)
    line = source_line(node)
    stored_inside = copy(inside)
    stored_exits = copy(exits)
    passed = passed_values(node)
    bindings = marks_of(walk, passed)
    walked = WalkedCall(callee, qualifier, arguments, keywords, line, stored_inside, stored_exits, is_dead, bindings)
    push!(walk.found, walked)
    nothing
end

# A return already on this path ends the nodes that follow. Otherwise the follow stays open.
function halt_follow(is_dead, prior, exits)
    is_dead && return WalkFollow(false, exits)
    prior.returns && return WalkFollow(true, prior.exits)
    nothing
end

function walk_dead!(walk, nodes, inside, exits)
    for node in nodes
        visit_node!(walk, node, inside, exits, true)
    end
    nothing
end

function visit_on_arm!(walk, node, inside, prior_exits, split, arm)
    armed = with_arm(inside, split, arm)
    visit_node!(walk, node, armed, prior_exits, false)
end

function follow_returned_arm(prior_exits, split, arm)
    tagged = with_arm(prior_exits, split, arm)
    WalkFollow(false, tagged)
end

function follow_one_arm(walked, prior_exits, split, arm)
    walked.returns || return WalkFollow(false, walked.exits)
    follow_returned_arm(prior_exits, split, arm)
end

function visit_exclusive!(walk, node, inside, prior_exits)
    split = fresh_split(walk)
    walked = visit_on_arm!(walk, node, inside, prior_exits, split, 1)
    follow_one_arm(walked, prior_exits, split, 1)
end

# The node runs only on one arm. A return there puts every later call past that arm.
function continue_after!(walk, node, inside, exits, is_dead, prior)
    halted = halt_follow(is_dead, prior, exits)
    if !isnothing(halted)
        visit_node!(walk, node, inside, halted.exits, true)
        return halted
    end
    visit_exclusive!(walk, node, inside, prior.exits)
end

function step_walk!(walk, node, ::NodeStep, inside, exits, is_dead)
    visit_node!(walk, node, inside, exits, is_dead)
end

function step_walk!(walk, node, ::IterationStep, inside, exits, is_dead)
    visit_iteration!(walk, node, inside, exits, is_dead)
end

function visit_sequence!(walk, nodes, step, inside, exits, is_dead)
    current = exits
    following_dead = is_dead
    saw_return = false
    for node in nodes
        walked = step_walk!(walk, node, step, inside, current, following_dead)
        if following_dead
            continue
        end
        if walked.returns
            following_dead = true
            saw_return = true
            continue
        end
        current = walked.exits
    end
    WalkFollow(saw_return, current)
end

function visit_children!(walk, node, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return WalkFollow(false, exits)
    visit_sequence!(walk, children, NodeStep(), inside, exits, is_dead)
end

function visit_node!(walk, node, inside, exits, is_dead)::WalkFollow
    kind = JS.kind(node)
    kind == K"quote" && return visit_kind!(walk, node, WalkOf{:quote}(), inside, exits, is_dead)
    if is_method_form(node)
        return visit_kind!(walk, node, WalkOf{:nested}(), inside, exits, is_dead)
    end
    if kind == K"->" || kind == K"do"
        return visit_kind!(walk, node, WalkOf{:closure}(), inside, exits, is_dead)
    end
    if kind == K"if" || kind == K"elseif" || kind == K"?"
        return visit_kind!(walk, node, WalkOf{:arms}(), inside, exits, is_dead)
    end
    if kind == K"&&" || kind == K"||"
        return visit_kind!(walk, node, WalkOf{:short}(), inside, exits, is_dead)
    end
    if kind == K"for" || kind == K"while"
        return visit_kind!(walk, node, WalkOf{:loop}(), inside, exits, is_dead)
    end
    kind == K"comprehension" && return visit_kind!(walk, node, WalkOf{:comprehension}(), inside, exits, is_dead)
    kind == K"generator" && return visit_kind!(walk, node, WalkOf{:generator}(), inside, exits, is_dead)
    kind == K"try" && return visit_kind!(walk, node, WalkOf{:try}(), inside, exits, is_dead)
    kind == K"return" && return visit_kind!(walk, node, WalkOf{:return}(), inside, exits, is_dead)
    kind == K"." && return visit_kind!(walk, node, WalkOf{:dot}(), inside, exits, is_dead)
    if kind == K"global" || kind == K"local"
        return visit_kind!(walk, node, WalkOf{:declare}(), inside, exits, is_dead)
    end
    kind == K"=" && return visit_kind!(walk, node, WalkOf{:assign}(), inside, exits, is_dead)
    if kind == K"tuple" || kind == K"parameters"
        return visit_kind!(walk, node, WalkOf{:values}(), inside, exits, is_dead)
    end
    if kind == K"call" || kind == K"dotcall"
        return visit_kind!(walk, node, WalkOf{:called}(), inside, exits, is_dead)
    end
    visit_kind!(walk, node, WalkOf{:child}(), inside, exits, is_dead)
end

function join_arm_follows(then_walked, else_walked, prior_exits, split)
    if then_walked.returns && else_walked.returns
        return WalkFollow(true, prior_exits)
    end
    if then_walked.returns
        return follow_returned_arm(else_walked.exits, split, 1)
    end
    if else_walked.returns
        return follow_returned_arm(then_walked.exits, split, 2)
    end
    merged = merge_exits(then_walked.exits, else_walked.exits)
    WalkFollow(false, merged)
end

function join_opened_arms!(walk, children, inside, prior_exits)
    split = fresh_split(walk)
    then_walked = visit_on_arm!(walk, children[2], inside, prior_exits, split, 1)
    if length(children) < 3
        return follow_one_arm(then_walked, prior_exits, split, 1)
    end
    else_walked = visit_on_arm!(walk, children[3], inside, prior_exits, split, 2)
    join_arm_follows(then_walked, else_walked, prior_exits, split)
end

function visit_kind!(walk, node, ::WalkOf{:arms}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || length(children) < 2
    missing && return WalkFollow(false, exits)
    condition = visit_node!(walk, children[1], inside, exits, is_dead)
    later = children[2:end]
    halted = halt_follow(is_dead, condition, exits)
    if !isnothing(halted)
        walk_dead!(walk, later, inside, halted.exits)
        return halted
    end
    join_opened_arms!(walk, children, inside, condition.exits)
end

function visit_kind!(walk, node, ::WalkOf{:short}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || length(children) < 2
    missing && return WalkFollow(false, exits)
    left = visit_node!(walk, children[1], inside, exits, is_dead)
    continue_after!(walk, children[2], inside, exits, is_dead, left)
end

function is_bound_clause(node)
    kind = JS.kind(node)
    kind == K"in" && return true
    kind == K"="
end

function visit_iteration!(walk, node, inside, exits, is_dead)
    children = child_nodes(node)
    isnothing(children) && return WalkFollow(false, exits)
    if is_bound_clause(node)
        length(children) < 2 && return WalkFollow(false, exits)
        rest = children[2:end]
        followed = visit_sequence!(walk, rest, NodeStep(), inside, exits, is_dead)
        mark = loop_mark(walk, node, rest)
        record_binding!(walk, children[1], mark)
        return followed
    end
    visit_sequence!(walk, children, IterationStep(), inside, exits, is_dead)
end

function visit_loop_header!(walk, node, headers, inside, exits, is_dead)
    if JS.kind(node) == K"for"
        return visit_sequence!(walk, headers, IterationStep(), inside, exits, is_dead)
    end
    visit_sequence!(walk, headers, NodeStep(), inside, exits, is_dead)
end

function visit_kind!(walk, node, ::WalkOf{:loop}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return WalkFollow(false, exits)
    last_index = length(children)
    if last_index == 1
        return visit_node!(walk, children[1], inside, exits, is_dead)
    end
    headers = children[1:last_index - 1]
    header = visit_loop_header!(walk, node, headers, inside, exits, is_dead)
    body = children[last_index]
    continue_after!(walk, body, inside, exits, is_dead, header)
end

function visit_filter!(walk, node, inside, exits, is_dead)
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        if is_iteration_clause(child)
            visit_iteration!(walk, child, inside, exits, is_dead)
        else
            visit_node!(walk, child, inside, exits, is_dead)
        end
    end
    nothing
end

function visit_gen_spec!(walk, node, inside, exits, is_dead)
    if JS.kind(node) == K"filter"
        visit_filter!(walk, node, inside, exits, is_dead)
        return
    end
    visit_iteration!(walk, node, inside, exits, is_dead)
    nothing
end

function visit_kind!(walk, node, ::WalkOf{:generator}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return WalkFollow(false, exits)
    last_index = length(children)
    for index in 2:last_index
        visit_gen_spec!(walk, children[index], inside, exits, is_dead)
    end
    prior = WalkFollow(false, exits)
    element = children[1]
    continue_after!(walk, element, inside, exits, is_dead, prior)
end

function visit_kind!(walk, node, ::WalkOf{:comprehension}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return WalkFollow(false, exits)
    visit_node!(walk, children[1], inside, exits, is_dead)
end

function visit_kind!(walk, node, ::WalkOf{:try}, inside, exits, is_dead)
    children = child_nodes(node)
    isnothing(children) && return WalkFollow(false, exits)
    for child in children
        visit_node!(walk, child, inside, exits, is_dead)
    end
    WalkFollow(false, exits)
end

function visit_kind!(walk, node, ::WalkOf{:return}, inside, exits, is_dead)
    children = child_nodes(node)
    if !isnothing(children)
        visit_sequence!(walk, children, NodeStep(), inside, exits, is_dead)
    end
    is_dead && return WalkFollow(false, exits)
    WalkFollow(true, exits)
end

function visit_kind!(walk, node, ::WalkOf{:quote}, inside, exits, is_dead)
    children = child_nodes(node)
    isnothing(children) && return WalkFollow(false, exits)
    visit_sequence!(walk, children, NodeStep(), inside, exits, is_dead)
    WalkFollow(false, exits)
end

function visit_kind!(walk, node, ::WalkOf{:closure}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || length(children) < 2
    missing && return WalkFollow(false, exits)
    visit_node!(walk, children[2], inside, exits, is_dead)
    WalkFollow(false, exits)
end

function visit_kind!(walk, node, ::WalkOf{:dot}, inside, exits, is_dead)
    children = child_nodes(node)
    has_pair = !isnothing(children) && length(children) == 2
    has_pair && return visit_node!(walk, children[1], inside, exits, is_dead)
    visit_children!(walk, node, inside, exits, is_dead)
end

function visit_lhs!(walk, node, inside, exits, is_dead)
    targets = JS.SyntaxNode[]
    collect_lhs!(targets, node)
    for target in targets
        visit_node!(walk, target, inside, exits, is_dead)
    end
    WalkFollow(false, exits)
end

function visit_declared!(walk, node, inside, exits, is_dead)
    if JS.kind(node) == K"="
        return visit_node!(walk, node, inside, exits, is_dead)
    end
    visit_lhs!(walk, node, inside, exits, is_dead)
end

function visit_kind!(walk, node, ::WalkOf{:declare}, inside, exits, is_dead)
    children = child_nodes(node)
    isnothing(children) && return WalkFollow(false, exits)
    for declaration in children
        visit_declared!(walk, declaration, inside, exits, is_dead)
    end
    WalkFollow(false, exits)
end

function visit_kind!(walk, node, ::WalkOf{:assign}, inside, exits, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || length(children) < 2
    missing && return WalkFollow(false, exits)
    visit_lhs!(walk, children[1], inside, exits, is_dead)
    followed = visit_node!(walk, children[2], inside, exits, is_dead)
    mark = fresh_mark(walk)
    record_binding!(walk, children[1], mark)
    followed
end

function visit_values!(walk, node, inside, exits, is_dead)
    values = value_children(node)
    isempty(values) && return WalkFollow(false, exits)
    visit_sequence!(walk, values, NodeStep(), inside, exits, is_dead)
end

visit_kind!(walk, node, ::WalkOf{:values}, inside, exits, is_dead) =
    visit_values!(walk, node, inside, exits, is_dead)

function visit_kind!(walk, node, ::WalkOf{:called}, inside, exits, is_dead)
    note_call!(walk, node, inside, exits, is_dead)
    visit_values!(walk, node, inside, exits, is_dead)
end

visit_kind!(walk, node, ::WalkOf{:child}, inside, exits, is_dead) =
    visit_children!(walk, node, inside, exits, is_dead)

function visit_default_value!(walk, arg, inside, exits, is_dead)
    JS.kind(arg) == K"=" || return
    children = child_nodes(arg)
    missing = isnothing(children) || length(children) < 2
    missing && return
    visit_node!(walk, children[2], inside, exits, is_dead)
    nothing
end

function visit_default_arg!(walk, arg, inside, exits, is_dead)
    if JS.kind(arg) == K"parameters"
        params = child_nodes(arg)
        isnothing(params) && return
        for param in params
            visit_default_value!(walk, param, inside, exits, is_dead)
        end
        return
    end
    visit_default_value!(walk, arg, inside, exits, is_dead)
    nothing
end

function visit_defaults!(walk, signature, inside, exits, is_dead)
    parts = call_parts(signature)
    isnothing(parts) && return
    for argument in parts.arguments
        visit_default_arg!(walk, argument, inside, exits, is_dead)
    end
    nothing
end

function visit_nested!(walk, node, is_dead)
    children = child_nodes(node)
    missing = isnothing(children) || length(children) < 2
    missing && return
    inside = Vector{Tuple{Int,Int}}()
    exits = Vector{Tuple{Int,Int}}()
    visit_defaults!(walk, children[1], inside, exits, is_dead)
    visit_node!(walk, children[2], inside, exits, is_dead)
    nothing
end

function visit_kind!(walk, node, ::WalkOf{:nested}, inside, exits, is_dead)
    visit_nested!(walk, node, is_dead)
    WalkFollow(false, exits)
end

function walked_calls(form)
    walk = CallWalk()
    children = child_nodes(form)
    missing = isnothing(children) || length(children) < 2
    missing && return walk.found
    inside = Vector{Tuple{Int,Int}}()
    exits = Vector{Tuple{Int,Int}}()
    visit_defaults!(walk, children[1], inside, exits, false)
    visit_node!(walk, children[2], inside, exits, false)
    walk.found
end

function same_walk(walked, call)
    walked.callee === call.callee || return false
    walked.qualifier == call.qualifier || return false
    walked.arguments == call.arguments || return false
    walked.keywords == call.keywords || return false
    walked.line == call.line
end

function walks_match(walked, calls)
    length(walked) == length(calls) || return false
    for index in eachindex(calls)
        same_walk(walked[index], calls[index]) || return false
    end
    true
end

function fallback_places(calls)
    placed = PlacedCall[]
    inside = Vector{Tuple{Int,Int}}()
    exits = Vector{Tuple{Int,Int}}()
    bindings = Int[]
    for call in calls
        push!(placed, PlacedCall(call, inside, exits, false, bindings))
    end
    placed
end

function place_calls(form, calls)
    walked = walked_calls(form)
    walks_match(walked, calls) || return fallback_places(calls)
    placed = PlacedCall[]
    for index in eachindex(calls)
        item = walked[index]
        push!(placed, PlacedCall(calls[index], item.inside, item.exits, item.is_dead, item.bindings))
    end
    placed
end

function tags_conflict(left, right)
    for (split, arm) in left
        for (other_split, other_arm) in right
            split == other_split || continue
            arm == other_arm && continue
            return true
        end
    end
    false
end

function exits_cover(exits, inside)
    for (split, arm) in inside
        for (exit_split, exit_arm) in exits
            split == exit_split || continue
            arm == exit_arm && return true
        end
    end
    false
end

function calls_join(left, right)
    left.is_dead && return false
    right.is_dead && return false
    tags_conflict(left.inside, right.inside) && return false
    exits_cover(left.exits, right.inside) && return false
    exits_cover(right.exits, left.inside) && return false
    true
end
