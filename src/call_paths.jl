# Which calls in one method can run on one path.
# An if, elseif, else, or ternary arm is exclusive of its siblings.
# A branch that returns is exclusive of every call after it.

struct WalkedCall
    callee::Symbol                    # called name
    qualifier::String                 # module path written before the name
    arguments::String                 # positional argument text
    keywords::String                  # keyword argument text
    line::Int                         # source line
    inside::Vector{Tuple{Int,Int}}    # (split, arm) pairs of the arms that hold the call
    exits::Vector{Tuple{Int,Int}}     # (split, arm) pairs of returning arms behind the call
    is_dead::Bool                     # a return on every path stands before the call
end

struct PlacedCall
    call::CallSite                    # scanned call, scanner order
    inside::Vector{Tuple{Int,Int}}    # (split, arm) pairs of the arms that hold the call
    exits::Vector{Tuple{Int,Int}}     # (split, arm) pairs of returning arms behind the call
    is_dead::Bool                     # a return on every path stands before the call
end

struct WalkFollow
    returns::Bool                      # every path through the node returns
    exits::Vector{Tuple{Int,Int}}      # returning arms a call after this node is past
end

struct CallWalk
    found::Vector{WalkedCall}          # calls in the order the scanner records them
    splits::Base.RefValue{Int}         # next id for an exclusive split
end

function CallWalk()
    found = WalkedCall[]
    splits = Ref(1)
    CallWalk(found, splits)
end

function fresh_split(walk)
    id = walk.splits[]
    walk.splits[] = id + 1
    id
end

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

function remember_call!(walk, callee, qualifier, arguments, keywords, line, inside, exits, is_dead)
    stored_inside = copy(inside)
    stored_exits = copy(exits)
    walked = WalkedCall(callee, qualifier, arguments, keywords, line, stored_inside, stored_exits, is_dead)
    push!(walk.found, walked)
    nothing
end

function note_operator!(walk, node, inside, exits, is_dead)
    callee = operator_callee(node)
    isnothing(callee) && return
    arguments = arguments_text(node)
    keywords = keywords_text(node)
    line = source_line(node)
    remember_call!(walk, callee, "", arguments, keywords, line, inside, exits, is_dead)
end

function note_named!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return
    naming = name_of_head(kids[1])
    isnothing(naming) && return
    arguments = arguments_text(node)
    keywords = keywords_text(node)
    line = source_line(node)
    remember_call!(walk, naming.callee, naming.qualifier, arguments, keywords, line, inside, exits, is_dead)
end

function note_call!(walk, node, inside, exits, is_dead)
    if is_operator_call(node)
        note_operator!(walk, node, inside, exits, is_dead)
    else
        note_named!(walk, node, inside, exits, is_dead)
    end
end

function visit_node!(walk, node, inside, exits, is_dead)
    kind = JS.kind(node)
    if kind == K"quote"
        return visit_quoted!(walk, node, inside, exits, is_dead)
    end
    if is_method_form(node)
        visit_nested!(walk, node, is_dead)
        return WalkFollow(false, exits)
    end
    if kind == K"->" || kind == K"do"
        return visit_closure!(walk, node, inside, exits, is_dead)
    end
    if kind == K"block"
        return visit_block!(walk, node, inside, exits, is_dead)
    end
    if kind == K"if" || kind == K"elseif" || kind == K"?"
        return visit_arms!(walk, node, inside, exits, is_dead)
    end
    if kind == K"&&" || kind == K"||"
        return visit_short!(walk, node, inside, exits, is_dead)
    end
    if kind == K"for" || kind == K"while"
        return visit_loop!(walk, node, inside, exits, is_dead)
    end
    if kind == K"comprehension"
        return visit_comprehension!(walk, node, inside, exits, is_dead)
    end
    if kind == K"generator"
        return visit_generator!(walk, node, inside, exits, is_dead)
    end
    if kind == K"try"
        return visit_try!(walk, node, inside, exits, is_dead)
    end
    if kind == K"return"
        return visit_return!(walk, node, inside, exits, is_dead)
    end
    if kind == K"."
        return visit_dot!(walk, node, inside, exits, is_dead)
    end
    if kind == K"global" || kind == K"local"
        return visit_declare!(walk, node, inside, exits, is_dead)
    end
    if kind == K"="
        return visit_assign!(walk, node, inside, exits, is_dead)
    end
    if kind == K"tuple" || kind == K"parameters"
        return visit_values!(walk, node, inside, exits, is_dead)
    end
    if kind == K"call" || kind == K"dotcall"
        return visit_call!(walk, node, inside, exits, is_dead)
    end
    visit_children!(walk, node, inside, exits, is_dead)
end

function visit_sequenced!(walk, nodes, inside, exits, is_dead)
    current = exits
    following_dead = is_dead
    hit_return = false
    for node in nodes
        walked = visit_node!(walk, node, inside, current, following_dead)
        if following_dead
            continue
        end
        if walked.returns
            following_dead = true
            hit_return = true
            continue
        end
        current = walked.exits
    end
    WalkFollow(hit_return, current)
end

function visit_children!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return WalkFollow(false, exits)
    visit_sequenced!(walk, kids, inside, exits, is_dead)
end

function visit_block!(walk, node, inside, exits, is_dead)
    visit_children!(walk, node, inside, exits, is_dead)
end

function visit_quoted!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    isnothing(kids) && return WalkFollow(false, exits)
    visit_sequenced!(walk, kids, inside, exits, is_dead)
    WalkFollow(false, exits)
end

function visit_dead_rest!(walk, nodes, inside, exits)
    for node in nodes
        visit_node!(walk, node, inside, exits, true)
    end
    nothing
end

function visit_arms!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return WalkFollow(false, exits)
    cond = visit_node!(walk, kids[1], inside, exits, is_dead)
    later = kids[2:end]
    if is_dead
        visit_dead_rest!(walk, later, inside, exits)
        return WalkFollow(false, exits)
    end
    if cond.returns
        visit_dead_rest!(walk, later, inside, cond.exits)
        return WalkFollow(true, cond.exits)
    end
    split = fresh_split(walk)
    then_inside = with_arm(inside, split, 1)
    then_walked = visit_node!(walk, kids[2], then_inside, cond.exits, false)
    has_else = length(kids) >= 3
    if !has_else
        if then_walked.returns
            follow = with_arm(cond.exits, split, 1)
            return WalkFollow(false, follow)
        end
        return WalkFollow(false, then_walked.exits)
    end
    else_inside = with_arm(inside, split, 2)
    else_walked = visit_node!(walk, kids[3], else_inside, cond.exits, false)
    if then_walked.returns && else_walked.returns
        return WalkFollow(true, cond.exits)
    end
    if then_walked.returns
        follow = with_arm(else_walked.exits, split, 1)
        return WalkFollow(false, follow)
    end
    if else_walked.returns
        follow = with_arm(then_walked.exits, split, 2)
        return WalkFollow(false, follow)
    end
    follow = merge_exits(then_walked.exits, else_walked.exits)
    WalkFollow(false, follow)
end

function visit_short!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return WalkFollow(false, exits)
    left = visit_node!(walk, kids[1], inside, exits, is_dead)
    if is_dead
        visit_node!(walk, kids[2], inside, exits, true)
        return WalkFollow(false, exits)
    end
    if left.returns
        visit_node!(walk, kids[2], inside, left.exits, true)
        return WalkFollow(true, left.exits)
    end
    split = fresh_split(walk)
    right_inside = with_arm(inside, split, 1)
    right = visit_node!(walk, kids[2], right_inside, left.exits, false)
    if right.returns
        follow = with_arm(left.exits, split, 1)
        return WalkFollow(false, follow)
    end
    WalkFollow(false, right.exits)
end

function visit_iteration!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    isnothing(kids) && return WalkFollow(false, exits)
    kind = JS.kind(node)
    if kind == K"in" || kind == K"="
        length(kids) < 2 && return WalkFollow(false, exits)
        rest = kids[2:end]
        return visit_sequenced!(walk, rest, inside, exits, is_dead)
    end
    visit_sequenced_iterations!(walk, kids, inside, exits, is_dead)
end

function visit_sequenced_iterations!(walk, nodes, inside, exits, is_dead)
    current = exits
    following_dead = is_dead
    hit_return = false
    for node in nodes
        walked = visit_iteration!(walk, node, inside, current, following_dead)
        if following_dead
            continue
        end
        if walked.returns
            following_dead = true
            hit_return = true
            continue
        end
        current = walked.exits
    end
    WalkFollow(hit_return, current)
end

function visit_loop!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return WalkFollow(false, exits)
    last_index = length(kids)
    last_index == 1 && return visit_node!(walk, kids[1], inside, exits, is_dead)
    headers = kids[1:last_index - 1]
    if JS.kind(node) == K"for"
        header = visit_sequenced_iterations!(walk, headers, inside, exits, is_dead)
    else
        header = visit_sequenced!(walk, headers, inside, exits, is_dead)
    end
    body = kids[last_index]
    if is_dead || header.returns
        visit_node!(walk, body, inside, header.exits, true)
        if is_dead
            return WalkFollow(false, exits)
        end
        return WalkFollow(true, header.exits)
    end
    split = fresh_split(walk)
    body_inside = with_arm(inside, split, 1)
    walked = visit_node!(walk, body, body_inside, header.exits, false)
    if walked.returns
        follow = with_arm(header.exits, split, 1)
        return WalkFollow(false, follow)
    end
    WalkFollow(false, walked.exits)
end

function visit_gen_spec!(walk, node, inside, exits, is_dead)
    if JS.kind(node) != K"filter"
        visit_iteration!(walk, node, inside, exits, is_dead)
        return
    end
    kids = child_nodes(node)
    isnothing(kids) && return
    for child in kids
        if is_iteration_clause(child)
            visit_iteration!(walk, child, inside, exits, is_dead)
        else
            visit_node!(walk, child, inside, exits, is_dead)
        end
    end
    nothing
end

function visit_generator!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return WalkFollow(false, exits)
    if length(kids) >= 2
        for index in 2:length(kids)
            visit_gen_spec!(walk, kids[index], inside, exits, is_dead)
        end
    end
    if is_dead
        visit_node!(walk, kids[1], inside, exits, true)
        return WalkFollow(false, exits)
    end
    split = fresh_split(walk)
    element_inside = with_arm(inside, split, 1)
    element = visit_node!(walk, kids[1], element_inside, exits, false)
    if element.returns
        follow = with_arm(exits, split, 1)
        return WalkFollow(false, follow)
    end
    WalkFollow(false, element.exits)
end

function visit_comprehension!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return WalkFollow(false, exits)
    visit_node!(walk, kids[1], inside, exits, is_dead)
end

function visit_try!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    isnothing(kids) && return WalkFollow(false, exits)
    for child in kids
        visit_node!(walk, child, inside, exits, is_dead)
    end
    WalkFollow(false, exits)
end

function visit_return!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    isnothing(kids) || visit_sequenced!(walk, kids, inside, exits, is_dead)
    if is_dead
        return WalkFollow(false, exits)
    end
    WalkFollow(true, exits)
end

function visit_dot!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) != 2) && return visit_children!(walk, node, inside, exits, is_dead)
    visit_node!(walk, kids[1], inside, exits, is_dead)
end

function visit_lhs!(walk, node, inside, exits, is_dead)
    targets = JS.SyntaxNode[]
    collect_lhs!(targets, node)
    for target in targets
        visit_node!(walk, target, inside, exits, is_dead)
    end
    WalkFollow(false, exits)
end

function visit_assign!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return WalkFollow(false, exits)
    left = visit_lhs!(walk, kids[1], inside, exits, is_dead)
    if is_dead || left.returns
        visit_node!(walk, kids[2], inside, left.exits, true)
        if is_dead
            return WalkFollow(false, exits)
        end
        return WalkFollow(true, left.exits)
    end
    visit_node!(walk, kids[2], inside, left.exits, false)
end

function visit_declare!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    isnothing(kids) && return WalkFollow(false, exits)
    for declaration in kids
        if JS.kind(declaration) == K"="
            visit_node!(walk, declaration, inside, exits, is_dead)
        else
            visit_lhs!(walk, declaration, inside, exits, is_dead)
        end
    end
    WalkFollow(false, exits)
end

function visit_values!(walk, node, inside, exits, is_dead)
    values = value_children(node)
    isempty(values) && return WalkFollow(false, exits)
    visit_sequenced!(walk, values, inside, exits, is_dead)
end

function visit_call!(walk, node, inside, exits, is_dead)
    note_call!(walk, node, inside, exits, is_dead)
    visit_values!(walk, node, inside, exits, is_dead)
end

function visit_closure!(walk, node, inside, exits, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return WalkFollow(false, exits)
    visit_node!(walk, kids[2], inside, exits, is_dead)
    WalkFollow(false, exits)
end

function visit_default_value!(walk, arg, inside, exits, is_dead)
    JS.kind(arg) == K"=" || return
    kids = child_nodes(arg)
    (isnothing(kids) || length(kids) < 2) && return
    visit_node!(walk, kids[2], inside, exits, is_dead)
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

function visit_defaults!(walk, sig, inside, exits, is_dead)
    node = sig
    kind = JS.kind(node)
    while kind == K"where" || kind == K"::"
        kids = child_nodes(node)
        (isnothing(kids) || isempty(kids)) && return
        node = kids[1]
        kind = JS.kind(node)
    end
    kind == K"call" || return
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return
    for index in 2:length(kids)
        visit_default_arg!(walk, kids[index], inside, exits, is_dead)
    end
    nothing
end

function visit_nested!(walk, node, is_dead)
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return
    inside = Vector{Tuple{Int,Int}}()
    exits = Vector{Tuple{Int,Int}}()
    visit_defaults!(walk, kids[1], inside, exits, is_dead)
    visit_node!(walk, kids[2], inside, exits, is_dead)
    nothing
end

function walked_calls(form)
    walk = CallWalk()
    kids = child_nodes(form)
    (isnothing(kids) || length(kids) < 2) && return walk.found
    inside = Vector{Tuple{Int,Int}}()
    exits = Vector{Tuple{Int,Int}}()
    visit_defaults!(walk, kids[1], inside, exits, false)
    visit_node!(walk, kids[2], inside, exits, false)
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
    for call in calls
        push!(placed, PlacedCall(call, inside, exits, false))
    end
    placed
end

function place_calls(form, calls)
    walked = walked_calls(form)
    walks_match(walked, calls) || return fallback_places(calls)
    placed = PlacedCall[]
    for index in eachindex(calls)
        item = walked[index]
        push!(placed, PlacedCall(calls[index], item.inside, item.exits, item.is_dead))
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
