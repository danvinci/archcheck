# Two calls in one method that ask one question, and a builder that drops the value it builds.

const LOOP_HEADS = (K"for", K"while", K"comprehension", K"generator")
const LOOP_CALLS = (:map, :map!, :sum, :maximum, :minimum, :foreach, :reduce, :mapreduce,
                    :filter, :any, :all, :count, :findfirst, :findall, :extrema)
const LOOP_HOPS = 2   # callee distance at which a loop still makes the repeated call costly

struct OverlappingCalls <: Check end

struct KeptBuilders{D<:NTuple{N,String} where N} <: Check
    builder::Symbol    # qualified function name, the dotted name as written
    exempt_dirs::D     # repo-relative directories whose methods are skipped
end

function KeptBuilders(builder::Symbol; exempt_dirs = ())
    dirs = Tuple(String(dir) for dir in exempt_dirs)
    KeptBuilders(builder, dirs)
end

function KeptBuilders(builder::Expr; exempt_dirs = ())
    name = Symbol(string(builder))
    KeptBuilders(name; exempt_dirs = exempt_dirs)
end

kinds(::OverlappingCalls) = (:overlapping_call => :advisory,)
kinds(::KeptBuilders) = (:kept_builder => :advisory,)

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
    left_name < right_name && return true
    right_name < left_name && return false
    left_line = Int(left.line)
    right_line = Int(right.line)
    left_line < right_line && return true
    right_line < left_line && return false
    left_file = string(left.file)
    right_file = string(right.file)
    left_file < right_file
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

function head_symbol(node)
    node.val isa Symbol && return node.val
    nothing
end

function node_holds_loop(node)
    kind = JS.kind(node)
    kind in LOOP_HEADS && return true
    if kind == K"call"
        name = head_symbol(first_child(node))
        !isnothing(name) && name in LOOP_CALLS && return true
    end
    children = child_nodes(node)
    isnothing(children) && return false
    for child in children
        node_holds_loop(child) && return true
    end
    false
end

function first_child(node)
    children = child_nodes(node)
    isnothing(children) && return node
    isempty(children) && return node
    children[1]
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
        nxt = Method[]
        for current in frontier
            current in seen && continue
            push!(seen, current)
            body_loops(index, current) && return true
            depth == LOOP_HOPS && continue
            for callee in callees_of(ordered, current)
                push!(nxt, callee)
            end
        end
        frontier = nxt
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

function rebuild_methods(previous, start, goal)
    path = Method[]
    cursor = goal
    limit = length(previous) + 1
    for _step in 1:limit
        push!(path, cursor)
        cursor === start && break
        cursor = previous[cursor]
    end
    reverse!(path)
    path
end

function first_path(ordered, start, goals)
    previous = Dict{Method,Method}()
    queue = Method[start]
    seen = Set{Method}([start])
    head = 1
    while head <= length(queue)
        current = queue[head]
        head += 1
        for callee in callees_of(ordered, current)
            callee in seen && continue
            push!(seen, callee)
            previous[callee] = current
            callee in goals && return rebuild_methods(previous, start, callee)
            push!(queue, callee)
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
        path = first_path(ordered, start, costing)
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

function group_calls(calls)
    groups = Dict{Tuple{String,String},Vector{CallSite}}()
    for call in calls
        key = (call.arguments, call.keywords)
        bucket = get!(Vector{CallSite}, groups, key)
        push!(bucket, call)
    end
    groups
end

function calls_by_identity(bucket)
    found = Dict{Tuple{Symbol,String},Vector{CallSite}}()
    for call in bucket
        identity = (call.callee, call.qualifier)
        group = get!(Vector{CallSite}, found, identity)
        push!(group, call)
    end
    found
end

function earliest_line(calls)
    line = calls[1].line
    for call in calls
        line = min(line, call.line)
    end
    line
end

function twice_findings(file, caller, grouped, ordered, index)
    findings = Finding[]
    symbol = string(caller.name)
    detail = "the same call is written twice"
    for (_, matched) in grouped
        length(matched) < 2 && continue
        sample = matched[1]
        repeated_costs(index, ordered, caller, sample) || continue
        text = call_text(sample)
        reached = string(sample.callee)
        evidence = [:calls => text, :reaches => reached]
        line = earliest_line(matched)
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
            helper_call = helpers[1]
            inner_call = inners[1]
            helper_methods = resolved_targets(ordered, caller, helper_call)
            inner_methods = resolved_targets(ordered, caller, inner_call)
            path = reach_costing(index, ordered, helper_methods, inner_methods)
            isnothing(path) && continue
            helper_text = call_text(helper_call)
            inner_text = call_text(inner_call)
            calls_text = helper_text * " " * inner_text
            reached = path_names(path)
            evidence = [:calls => calls_text, :reaches => reached]
            line = min(helper_call.line, inner_call.line)
            finding = Finding(file.mod, :overlapping_call, file.path, symbol, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end

function method_overlap_findings(file, caller, calls, ordered, index)
    findings = Finding[]
    groups = group_calls(calls)
    for bucket in values(groups)
        grouped = calls_by_identity(bucket)
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

function methods_by_site(methods, repo)
    found = Dict{Tuple{String,Int},Vector{Method}}()
    for method in methods
        path, line = method_site(method, repo)
        key = (path, line)
        bucket = get!(Vector{Method}, found, key)
        push!(bucket, method)
    end
    found
end

function caller_at(by_site, file, site)
    bucket = get(by_site, (file.path, site.line), Method[])
    for method in bucket
        site_names_method(site, method) || continue
        module_agrees(method, file.mod) || continue
        return method
    end
    nothing
end

function run(::OverlappingCalls, ctx)
    isnothing(ctx.methods) && throw(ArgumentError("OverlappingCalls needs entries"))
    repo = ctx.index.repo
    defined = project_methods(package_modules(ctx))
    by_site = methods_by_site(defined, repo)
    ordered = ordered_callees(ctx.methods)
    findings = Finding[]
    for file in ctx.index.files
        for (site, calls) in file.scan.callsites
            caller = caller_at(by_site, file, site)
            isnothing(caller) && continue
            found = method_overlap_findings(file, caller, calls, ordered, ctx.index)
            append!(findings, found)
        end
    end
    findings
end

function split_builder(builder)
    text = string(builder)
    parts = split(text, ".")
    name = Symbol(parts[end])
    prefix = parts[1:end-1]
    (name, prefix)
end

function tail_matches(mod, prefix)
    isempty(prefix) && return false
    names = fullname(mod)
    length(names) < 2 && return false
    below = names[2:end]
    length(below) < length(prefix) && return false
    start = length(below) - length(prefix) + 1
    for index in eachindex(prefix)
        piece = string(below[start + index - 1])
        piece == prefix[index] || return false
    end
    true
end

function owned_value(value::Union{Function,Type}, mod::Module)
    parentmodule(value) === mod || return nothing
    value
end

owned_value(::Any, ::Module) = nothing

function owned_callable(mod, name)
    isdefined(mod, name) || return nothing
    value = getfield(mod, name)
    owned_value(value, mod)
end

function find_builder(ctx, name, prefix)
    for mod in package_modules(ctx)
        tail_matches(mod, prefix) || continue
        func = owned_callable(mod, name)
        isnothing(func) || return func
    end
    nothing
end

function unwrap_return(node)
    JS.kind(node) == K"return" || return node
    children = child_nodes(node)
    isnothing(children) && return node
    length(children) == 1 || return node
    children[1]
end

function method_value(node)
    body = method_body(node)
    isnothing(body) && return nothing
    tail = last_body_expr(body)
    isnothing(tail) && return nothing
    unwrap_return(tail)
end

function is_get_call(node)
    JS.kind(node) == K"call" || return false
    head = first_child(node)
    head_symbol(head) === :get!
end

function has_do_child(node)
    children = child_nodes(node)
    isnothing(children) && return false
    for child in children
        JS.kind(child) == K"do" && return true
    end
    false
end

function is_get_keep(node)
    isnothing(node) && return false
    is_get_call(node) && has_do_child(node)
end

function names_builder(head, builder, bare)
    symbol = head_symbol(head)
    if !isnothing(symbol)
        return symbol === bare
    end
    JS.kind(head) == K"." || return false
    written = form_text(head)
    text = string(builder)
    written == text && return true
    suffix = "." * text
    endswith(written, suffix)
end

function is_builder_call(node, builder, bare)
    isnothing(node) && return false
    JS.kind(node) == K"call" || return false
    head = first_child(node)
    names_builder(head, builder, bare)
end

function path_is_exempt(path, dirs)
    for dir in dirs
        is_under(path, dir) && return true
    end
    false
end

function form_text(node)
    raw = JS.sourcetext(node)
    collapse_source(raw)
end

function has_keeper(index, methods_of)
    for method in methods_of
        located = method_form(index, method)
        isnothing(located) && continue
        value = method_value(located.form)
        is_get_keep(value) && return true
    end
    false
end

# A call of the builder is kept when some method of that function keeps its value, exempt directories included.
function run(check::KeptBuilders, ctx)
    parts = split_builder(check.builder)
    name = parts[1]
    prefix = parts[2]
    func = find_builder(ctx, name, prefix)
    isnothing(func) && return Finding[]
    methods_of = collect(methods(func))
    keeper = has_keeper(ctx.index, methods_of)
    findings = Finding[]
    detail = "the method builds a value and drops it"
    builder_text = string(check.builder)
    for method in methods_of
        located = method_form(ctx.index, method)
        isnothing(located) && continue
        path_is_exempt(located.file.path, check.exempt_dirs) && continue
        value = method_value(located.form)
        isnothing(value) && continue
        is_get_keep(value) && continue
        if keeper && is_builder_call(value, check.builder, name)
            continue
        end
        form = form_text(value)
        evidence = [:builder => builder_text, :form => form]
        symbol = string(method.name)
        line = source_line(located.form)
        finding = Finding(located.file.mod, :kept_builder, located.file.path, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
