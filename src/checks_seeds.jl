# Uniform integer grids: colon stops, divisors, and range lengths with a fixed count.

# `:(=)` parses as an equals head with no children: the operator used as a value.
function assignment_pair(node)
    children = child_nodes(node)
    isnothing(children) && return nothing
    length(children) < 2 && return nothing
    children
end

function scan_integer(node, bindings)
    literal = node.val
    if literal isa Int
        return literal
    end
    if literal isa Symbol
        return get(bindings, literal, nothing)
    end
    operation = infix_op(node)
    operation in (:+, :-) || return nothing
    children = child_nodes(node)
    left_node = children[1]
    right_node = children[3]
    left = scan_integer(left_node, bindings)
    right = scan_integer(right_node, bindings)
    isnothing(left) && return nothing
    isnothing(right) && return nothing
    if operation === :+
        return left + right
    end
    left - right
end

function is_index_colon(children)
    length(children) == 3 || return false
    operator = children[2]
    operator.val === :(:) || return false
    start = children[1]
    start.val in (0, 1)
end

function is_division(children)
    length(children) == 3 || return false
    operator = children[2]
    operator.val === :/
end

function record_stop!(stops, children, bindings, line)
    value = children[3]
    count = scan_integer(value, bindings)
    isnothing(count) && return
    haskey(stops, count) && return
    stops[count] = line
end

function record_divisor!(divisors, children, bindings)
    value = children[3]
    count = scan_integer(value, bindings)
    isnothing(count) && return
    push!(divisors, count)
end

function parameter_nodes(child)
    kind = JS.kind(child)
    kind == K"parameters" && return child_nodes(child)
    (child,)
end

function keyword_length(count, child, bindings)
    options = parameter_nodes(child)
    isnothing(options) && return count
    for option in options
        kind = JS.kind(option)
        kind == K"=" || continue
        pair = assignment_pair(option)
        isnothing(pair) && continue
        name = pair[1]
        name.val === :length || continue
        value = pair[2]
        count = scan_integer(value, bindings)
    end
    count
end

function range_length(node, children, bindings)
    positional = positional_arguments(node)
    length(positional) >= 2 || return nothing
    count = nothing
    if length(positional) == 3
        third = positional[3]
        count = scan_integer(third, bindings)
    end
    for child in children
        count = keyword_length(count, child, bindings)
    end
    count
end

function record_range!(lengths, node, children, bindings, line)
    isempty(children) && return
    head = children[1]
    head.val in (:range, :LinRange) || return
    count = range_length(node, children, bindings)
    isnothing(count) && return
    lengths[count] = line
end

function record_grid!(stops, divisors, lengths, node, bindings)
    kind = JS.kind(node)
    is_call = kind == K"call" || kind == K"dotcall"
    is_call || return
    children = child_nodes(node)
    isnothing(children) && return
    line = source_line(node)
    if is_index_colon(children)
        record_stop!(stops, children, bindings, line)
        return
    end
    if is_division(children)
        record_divisor!(divisors, children, bindings)
        return
    end
    record_range!(lengths, node, children, bindings, line)
end

function fold_divisors!(lengths, stops, divisors)
    for count in divisors
        if haskey(stops, count)
            lengths[count] = stops[count]
        elseif haskey(stops, count - 1)
            adjacent = count - 1
            lengths[count] = stops[adjacent]
        end
    end
end

function scan_grids(nodes, bindings)
    stops = Dict{Int,Int}()
    divisors = Set{Int}()
    lengths = Dict{Int,Int}()
    for node in nodes
        record_grid!(stops, divisors, lengths, node, bindings)
    end
    fold_divisors!(lengths, stops, divisors)
    lengths
end

function is_seed_file(index, file, directories)
    path = joinpath(index.repo, file.path)
    for directory in directories
        directory_path = joinpath(index.repo, directory)
        is_within(path, directory_path) && return true
    end
    false
end

function seed_files(index, directories)
    files = FileNode[]
    for file in index.files
        is_seed_file(index, file, directories) || continue
        push!(files, file)
    end
    files
end

function record_module_constant!(constants, node, owner)
    owner === Symbol("") || return
    kind = JS.kind(node)
    kind == K"const" || return
    children = child_nodes(node)
    isnothing(children) && return
    for assignment in children
        assignment_kind = JS.kind(assignment)
        assignment_kind == K"=" || continue
        pair = assignment_pair(assignment)
        isnothing(pair) && continue
        name = pair[1].val
        value = pair[2].val
        name isa Symbol || continue
        value isa Int || continue
        constants[name] = value
    end
end

function record_seed_node!(owners, constants, node, owner)
    nodes = get!(Vector{JS.SyntaxNode}, owners, owner)
    push!(nodes, node)
    record_module_constant!(constants, node, owner)
end

function collect_file_seeds!(groups, constants, file)
    owners = Dict{Symbol,Vector{JS.SyntaxNode}}()
    module_constants = get!(Dict{Symbol,Int}, constants, file.mod)
    walk_with_enclosing(file.tree) do node, owner
        record_seed_node!(owners, module_constants, node, owner)
    end
    groups[file.path] = owners
end

function seed_tables(files)
    groups = Dict{String,Dict{Symbol,Vector{JS.SyntaxNode}}}()
    constants = Dict{Symbol,Dict{Symbol,Int}}()
    for file in files
        collect_file_seeds!(groups, constants, file)
    end
    groups, constants
end

# A second assignment, or a non-integer one, removes the name from the integer bindings.
function record_assignment!(bindings, assigned, blocked, node)
    pair = assignment_pair(node)
    isnothing(pair) && return
    name = pair[1].val
    name isa Symbol || return
    value = pair[2].val
    is_single_integer = !(name in assigned) && value isa Int
    if is_single_integer
        bindings[name] = value
    else
        push!(blocked, name)
    end
    push!(assigned, name)
end

function record_binding!(bindings, assigned, blocked, node, owner)
    kind = JS.kind(node)
    if kind == K"call" && sig_name(node) === owner
        names = sig_argnames(node)
        union!(blocked, names)
        return
    end
    kind == K"=" || return
    record_assignment!(bindings, assigned, blocked, node)
end

function method_bindings(nodes, owner, module_constants)
    bindings = copy(module_constants)
    assigned = Set{Symbol}()
    blocked = Set{Symbol}()
    for node in nodes
        record_binding!(bindings, assigned, blocked, node, owner)
    end
    for name in blocked
        delete!(bindings, name)
    end
    bindings
end

function grid_finding(file, owner, nodes, module_constants)
    owner === Symbol("") && return nothing
    bindings = method_bindings(nodes, owner, module_constants)
    grids = scan_grids(nodes, bindings)
    isempty(grids) && return nothing
    raw_counts = keys(grids)
    counts = collect(raw_counts)
    sort!(counts)
    samples = join(counts, ", ")
    evidence = [:samples => samples]
    detail = "fixed integer counts form a uniform parameter grid"
    lines = values(grids)
    line = minimum(lines)
    owner_name = string(owner)
    Finding(file.mod, :scan_seed, file.path, owner_name, line, detail, evidence)
end

function seed_findings(file, groups, constants)
    findings = Finding[]
    haskey(groups, file.path) || return findings
    owners = groups[file.path]
    module_constants = constants[file.mod]
    for (owner, nodes) in owners
        finding = grid_finding(file, owner, nodes, module_constants)
        isnothing(finding) && continue
        push!(findings, finding)
    end
    findings
end

function finding_before(left, right)
    if left.file != right.file
        return left.file < right.file
    end
    if left.line != right.line
        return left.line < right.line
    end
    left.symbol < right.symbol
end

function check_scan_seeds(index::SourceIndex; directories)
    files = seed_files(index, directories)
    groups, constants = seed_tables(files)
    findings = Finding[]
    for file in files
        found = seed_findings(file, groups, constants)
        append!(findings, found)
    end
    sort!(findings; lt = finding_before)
    findings
end
