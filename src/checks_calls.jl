# Two calls in one method that ask one question.

const LOOP_HEADS = (K"for", K"while", K"comprehension", K"generator")
const LOOP_CALLS = (:map, :map!, :sum, :maximum, :minimum, :foreach, :reduce, :mapreduce,
                    :filter, :any, :all, :count, :findfirst, :findall, :extrema)
const LOOP_HOPS = 2   # callee distance at which a loop still makes the repeated call costly

"""Configured through `gate(...; checks)`, and the gate needs `entries`. Two calls on one path ask one question."""
struct OverlappingCalls <: Check end

kinds(::OverlappingCalls) = (:overlapping_call => :advisory,)

function call_text(call)
    name = string(call.callee)
    if !isempty(call.qualifier)
        name = call.qualifier * "." * name
    end
    opened = name * "(" * call.arguments
    isempty(call.keywords) && return opened * ")"
    opened * "; " * call.keywords * ")"
end

function method_before(left, right)
    left_name = string(left.name)
    right_name = string(right.name)
    left_line = Int(left.line)
    right_line = Int(right.line)
    left_file = string(left.file)
    right_file = string(right.file)
    left_order = (left_name, left_line, left_file)
    right_order = (right_name, right_line, right_file)
    left_order < right_order
end

function qualifier_matches(method, qualifier)
    isempty(qualifier) && return true
    path = join(fullname(method.module), ".")
    path == qualifier && return true
    suffix = "." * qualifier
    endswith(path, suffix)
end

function name_mutates(name)
    endswith(string(name), "!")
end

function is_loop_call(node)
    JS.kind(node) == K"call" || return false
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return false
    naming = name_of_head(kids[1])
    isnothing(naming) && return false
    isempty(naming.qualifier) || return false
    naming.callee in LOOP_CALLS
end

function node_holds_loop(node)
    for child in walk_nodes(node)
        kind = JS.kind(child)
        kind in LOOP_HEADS && return true
        is_loop_call(child) && return true
    end
    false
end

function body_loops(index, method)
    method.name in LOOP_CALLS && return true
    located = method_form(index, method)
    isnothing(located) && return false
    body = method_body(located.form)
    isnothing(body) && return false
    node_holds_loop(body)
end

function ordered_callees(graph)
    found = Dict{Method,Vector{Method}}()
    for (method, callees) in graph.edges
        ordered = collect(callees)
        sort!(ordered; lt = method_before)
        found[method] = ordered
    end
    found
end

function callees_of(ordered, method)
    get(ordered, method, Method[])
end

# A bang name on the repeated callee is a mutator. A loop in its body, or in a callee two hops away, is the work a repeat costs.
function costs_work(index, ordered, method)
    name_mutates(method.name) && return false
    frontier = Method[method]
    seen = Set{Method}()
    depth = 0
    while depth <= LOOP_HOPS && !isempty(frontier)
        next_methods = Method[]
        for current in frontier
            current in seen && continue
            push!(seen, current)
            body_loops(index, current) && return true
            depth == LOOP_HOPS && continue
            for callee in callees_of(ordered, current)
                push!(next_methods, callee)
            end
        end
        frontier = next_methods
        depth += 1
    end
    false
end

function resolved_targets(ordered, caller, call)
    found = Method[]
    for method in callees_of(ordered, caller)
        method.name === call.callee || continue
        qualifier_matches(method, call.qualifier) || continue
        push!(found, method)
    end
    found
end

function repeated_costs(index, ordered, caller, call)
    targets = resolved_targets(ordered, caller, call)
    for target in targets
        costs_work(index, ordered, target) && return true
    end
    isempty(targets) || return false
    call.callee in LOOP_CALLS || return false
    !name_mutates(call.callee)
end

# A method's body, the parameter name at each positional slot, and the loop elements each parameter yields. A name
# the body binds again holds another value there, so its slot carries nothing.
function method_flow(index, method)
    located = method_form(index, method)
    isnothing(located) && return nothing
    form = located.form
    body = method_body(form)
    isnothing(body) && return nothing
    signature = child_nodes(form)[1]
    declared = read_positionals(argname_of, signature)
    rebound = Symbol[]
    bound_names!(rebound, body)
    parameters = Union{Symbol,Nothing}[]
    for name in declared
        carried = name in rebound ? nothing : name
        push!(parameters, carried)
    end
    elements = loop_elements(body, parameters, rebound)
    (; body, parameters, elements)
end

# Each name a loop binds to the elements of a carried parameter, mapped to that parameter. A name bound anywhere
# else as well holds other values too.
function loop_elements(body, parameters, rebound)
    elements = Dict{Symbol,Symbol}()
    for node in walk_nodes(body)
        is_bound_clause(node) || continue
        parent = node.parent
        (isnothing(parent) || JS.kind(parent) != K"iteration") && continue
        children = child_nodes(node)
        element = children[1].val
        source = children[2].val
        (element isa Symbol && source isa Symbol) || continue
        source in parameters || continue
        count(isequal(element), rebound) == 1 || continue
        elements[element] = source
    end
    elements
end

# The parameter a positional argument carries: its bare name, or a loop element alone in a tuple, which asks the
# parameter's question of one part.
function carried_name(flow, argument)
    value = argument.val
    value isa Symbol && return value
    JS.kind(argument) == K"tuple" || return nothing
    items = child_nodes(argument)
    (isnothing(items) || length(items) != 1) && return nothing
    element = only(items).val
    element isa Symbol || return nothing
    get(flow.elements, element, nothing)
end

function carried_names(flow, call)
    names = Union{Symbol,Nothing}[]
    for argument in positional_arguments(call)
        named = carried_name(flow, argument)
        push!(names, named)
    end
    names
end

# Each carried value's slot in the callee: where the call passes an argument carrying its parameter.
function moved_slots(parameters, slots, passed)
    moved = Int[]
    for slot in slots
        name = get(parameters, slot, nothing)
        isnothing(name) && return nothing
        position = findfirst(isequal(name), passed)
        isnothing(position) && return nothing
        push!(moved, position)
    end
    moved
end

# A step is a method and, per argument of the caller's call, the parameter slot holding it there.
function carried_steps(index, ordered, step)
    method = step[1]
    slots = step[2]
    steps = Tuple{Method,Vector{Int}}[]
    flow = method_flow(index, method)
    isnothing(flow) && return steps
    for node in walk_nodes(flow.body)
        JS.kind(node) == K"call" || continue
        naming = called_name(node)
        isnothing(naming) && continue
        passed = carried_names(flow, node)
        moved = moved_slots(flow.parameters, slots, passed)
        isnothing(moved) && continue
        for callee in resolved_targets(ordered, method, naming)
            push!(steps, (callee, moved))
        end
    end
    steps
end

function arrives(step, goals)
    step[1] in goals || return false
    slots = step[2]
    slots == eachindex(slots)
end

function rebuild_methods(previous, start, goal)
    path = Method[]
    cursor = goal
    limit = length(previous) + 1
    for _step in 1:limit
        push!(path, cursor[1])
        cursor == start && break
        cursor = previous[cursor]
    end
    reverse!(path)
    path
end

# A path counts only when every argument the caller passed the helper reaches the inner method at its own slot.
function first_path(index, ordered, start, goals)
    opened = method_flow(index, start)
    isnothing(opened) && return nothing
    slots = collect(eachindex(opened.parameters))
    origin = (start, slots)
    previous = Dict{Tuple{Method,Vector{Int}},Tuple{Method,Vector{Int}}}()
    queue = [origin]
    seen = Set([origin])
    head = 1
    while head <= length(queue)
        current = queue[head]
        head += 1
        for step in carried_steps(index, ordered, current)
            step in seen && continue
            push!(seen, step)
            previous[step] = current
            arrives(step, goals) && return rebuild_methods(previous, origin, step)
            push!(queue, step)
        end
    end
    nothing
end

function reach_costing(index, ordered, helpers, inners)
    costing = Set{Method}()
    for method in inners
        costs_work(index, ordered, method) && push!(costing, method)
    end
    isempty(costing) && return nothing
    ordered_helpers = sort(collect(helpers); lt = method_before)
    for start in ordered_helpers
        path = first_path(index, ordered, start, costing)
        isnothing(path) || return path
    end
    nothing
end

function path_names(path)
    names = String[]
    for method in path
        push!(names, string(method.name))
    end
    join(names, " ")
end

function group_by(items, ::Type{K}, key_of) where K
    grouped = Dict{K,Vector{eltype(items)}}()
    for item in items
        key = key_of(item)::K
        bucket = get!(Vector{eltype(items)}, grouped, key)
        push!(bucket, item)
    end
    grouped
end

function argument_key(placed)
    call = placed.call
    (call.arguments, call.keywords)
end

function callee_key(placed)
    call = placed.call
    (call.callee, call.qualifier)
end

function earlier_line(found, pair)
    isnothing(found) && return pair
    pair < found && return pair
    found
end

# Equal argument text names one value only while no name in it is bound again between the two calls.
function asks_once(left, right)
    left.bindings == right.bindings || return false
    calls_join(left, right)
end

function joining_line(calls)
    found = nothing
    last_index = length(calls)
    for left_index in 1:(last_index - 1)
        left = calls[left_index]
        for right_index in (left_index + 1):last_index
            right = calls[right_index]
            asks_once(left, right) || continue
            pair = min(left.call.line, right.call.line)
            found = earlier_line(found, pair)
        end
    end
    found
end

function cross_line(helpers, inners)
    found = nothing
    for helper in helpers
        for inner in inners
            asks_once(helper, inner) || continue
            pair = min(helper.call.line, inner.call.line)
            found = earlier_line(found, pair)
        end
    end
    found
end

function twice_findings(file, caller, grouped, ordered, index)
    findings = Finding[]
    symbol = string(caller.name)
    detail = "the same call is written twice"
    for matched in values(grouped)
        line = joining_line(matched)
        isnothing(line) && continue
        sample = matched[1].call
        repeated_costs(index, ordered, caller, sample) || continue
        text = call_text(sample)
        reached = string(sample.callee)
        evidence = [:calls => text, :reaches => reached]
        finding = Finding(file.mod, :overlapping_call, file.path, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

function reach_findings(file, caller, grouped, ordered, index)
    findings = Finding[]
    symbol = string(caller.name)
    detail = "the caller asks a question a helper already asks"
    identities = collect(keys(grouped))
    for helper_id in identities
        for inner_id in identities
            helper_id == inner_id && continue
            helpers = grouped[helper_id]
            inners = grouped[inner_id]
            line = cross_line(helpers, inners)
            isnothing(line) && continue
            helper_call = helpers[1].call
            inner_call = inners[1].call
            helper_methods = resolved_targets(ordered, caller, helper_call)
            inner_methods = resolved_targets(ordered, caller, inner_call)
            path = reach_costing(index, ordered, helper_methods, inner_methods)
            isnothing(path) && continue
            helper_text = call_text(helper_call)
            inner_text = call_text(inner_call)
            calls_text = helper_text * " " * inner_text
            reached = path_names(path)
            evidence = [:calls => calls_text, :reaches => reached]
            finding = Finding(file.mod, :overlapping_call, file.path, symbol, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end

function method_overlap_findings(file, caller, placed, ordered, index)
    findings = Finding[]
    groups = group_by(placed, Tuple{String,String}, argument_key)
    for bucket in values(groups)
        grouped = group_by(bucket, Tuple{Symbol,String}, callee_key)
        twice = twice_findings(file, caller, grouped, ordered, index)
        append!(findings, twice)
        reached = reach_findings(file, caller, grouped, ordered, index)
        append!(findings, reached)
    end
    findings
end

function module_agrees(method, file_mod)
    key = module_key(method.module)
    key === file_mod && return true
    text = string(key)
    root = string(file_mod)
    prefix = root * "."
    startswith(text, prefix)
end

function run(::OverlappingCalls, ctx)
    isnothing(ctx.methods) && throw(ArgumentError("OverlappingCalls needs entries"))
    defined = project_methods(package_modules(ctx))
    ordered = ordered_callees(ctx.methods)
    seen = Set{Tuple{String,Symbol,Int}}()
    findings = Finding[]
    for method in defined
        located = method_form(ctx.index, method)
        isnothing(located) && continue
        module_agrees(method, located.file.mod) || continue
        site_key = (located.file.path, located.site.name, located.site.line)
        site_key in seen && continue
        push!(seen, site_key)
        calls = get(located.file.scan.callsites, located.site, CallSite[])
        isempty(calls) && continue
        placed = place_calls(located.form, calls)
        found = method_overlap_findings(located.file, method, placed, ordered, ctx.index)
        append!(findings, found)
    end
    findings
end
