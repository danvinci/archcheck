# A runtime type test on a method's own parameter picks a path dispatch would pick.

const TYPE_COMPARISONS = (:(==), :(===), :(!=), :(!==), :(<:))

function check_type_branches(index::SourceIndex)
    findings = Finding[]
    for file in index.files
        walk = BranchWalk(findings, file)
        visit_type_branch!(walk, file.tree, false, "", Symbol[])
    end
    findings
end

# One file's walk: where findings go and the file they name.
struct BranchWalk
    findings::Vector{Finding}   # every type branch found, in walk order
    file::FileNode              # the code being walked
end

# `is_discarded` says the node's value is discarded, where && and || pick a path.
function visit_type_branch!(walk::BranchWalk, node, is_discarded::Bool, owner::String, params::Vector{Symbol})
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if kind == K"->" || kind == K"do"
        visit_cleared!(walk, node, 1:length(children), is_discarded)
    elseif kind == K"function"
        visit_method_scope!(walk, node, children, is_discarded)
    elseif kind == K"="
        visit_assign!(walk, node, children, is_discarded, owner, params)
    elseif kind == K"for"
        last_index = length(children)
        visit_loop!(walk, node, 1:(last_index - 1), last_index, is_discarded, owner, params)
    elseif kind == K"generator"
        visit_loop!(walk, node, 2:length(children), 1, is_discarded, owner, params)
    elseif kind == K"if" || kind == K"elseif" || kind == K"?"
        record_type_branch!(walk, children, owner, params)
        visit_children!(walk, node, 1:length(children), is_discarded, owner, params)
    elseif kind == K"&&" || kind == K"||"
        if is_discarded
            record_type_branch!(walk, children, owner, params)
        end
        visit_children!(walk, node, 1:length(children), is_discarded, owner, params)
    else
        visit_children!(walk, node, 1:length(children), is_discarded, owner, params)
    end
end

# The child at `index` of `node`, visited with its own discard flag.
function visit_child!(walk::BranchWalk, node, index, node_is_discarded, owner, params)
    children = child_nodes(node)
    child_is_discarded = child_discarded(node, index, node_is_discarded)
    visit_type_branch!(walk, children[index], child_is_discarded, owner, params)
end

function visit_children!(walk::BranchWalk, node, indices, is_discarded, owner, params)
    for index in indices
        visit_child!(walk, node, index, is_discarded, owner, params)
    end
end

# An anonymous function and a do-block bind their own parameters, hiding the method's.
function visit_cleared!(walk::BranchWalk, node, indices, is_discarded)
    for index in indices
        visit_child!(walk, node, index, is_discarded, "", Symbol[])
    end
end

function method_name(call)
    children = child_nodes(call)
    head = first(children)
    text = JS.sourcetext(head)
    String(text)
end

function unwrap_binding(item)
    bound = item
    while JS.kind(bound) in (K"=", K"...", K"::")
        children = child_nodes(bound)
        bound = first(children)
    end
    bound
end

# A tuple parameter binds the names inside the tuple, which the method does not test as its own.
function keep_parameter!(params, item)
    bound = unwrap_binding(item)
    JS.kind(bound) == K"tuple" && return
    _argname!(params, item)
end

function parameter_items(call)
    children = child_nodes(call)
    items = JS.SyntaxNode[]
    for argument in children[2:end]
        if JS.kind(argument) == K"parameters"
            nested = child_nodes(argument)
            append!(items, nested)
        else
            push!(items, argument)
        end
    end
    items
end

function method_parameters(call)
    params = Symbol[]
    for item in parameter_items(call)
        keep_parameter!(params, item)
    end
    params
end

function visit_method_body!(walk::BranchWalk, node, children, is_discarded, call)
    owner = method_name(call)
    params = method_parameters(call)
    visit_children!(walk, node, 2:length(children), is_discarded, owner, params)
end

function visit_method_scope!(walk::BranchWalk, node, children, is_discarded)
    signature = children[1]
    call = signature_call(signature)
    if isnothing(call)
        visit_cleared!(walk, node, 1:length(children), is_discarded)
        return
    end
    visit_method_body!(walk, node, children, is_discarded, call)
end

function visit_assign!(walk::BranchWalk, node, children, is_discarded, owner, params)
    if is_method_form(node)
        visit_method_scope!(walk, node, children, is_discarded)
        return
    end
    visit_children!(walk, node, 1:length(children), is_discarded, owner, params)
end

# A loop's specs bind names that hide the method's parameters inside its body.
function visit_loop!(walk::BranchWalk, node, spec_indices, body_index, is_discarded, owner, params)
    children = child_nodes(node)
    targets = Symbol[]
    for index in spec_indices
        bound_names!(targets, children[index])
    end
    visit_children!(walk, node, spec_indices, is_discarded, owner, params)
    kept = setdiff(params, targets)
    visit_child!(walk, node, body_index, is_discarded, owner, kept)
end

function branch_statements(branch)
    JS.kind(branch) == K"block" || return [branch]
    child_nodes(branch)
end

# The branch's single statement throws, so the test is checking input.
function is_throw_guard(branch)
    statements = branch_statements(branch)
    length(statements) == 1 || return false
    statement = only(statements)
    JS.kind(statement) == K"call" || return false
    children = child_nodes(statement)
    callee = first(children)
    callee.val === :throw
end

function typeof_subject(operand)
    JS.kind(operand) == K"call" || return nothing
    inner = child_nodes(operand)
    length(inner) == 2 || return nothing
    callee = first(inner)
    callee.val === :typeof || return nothing
    last(inner)
end

function comparison_subjects(operator, operands)
    subjects = JS.SyntaxNode[]
    if operator === :isa
        subject = first(operands)
        push!(subjects, subject)
        return subjects
    end
    operator in TYPE_COMPARISONS || return subjects
    for operand in operands
        subject = typeof_subject(operand)
        isnothing(subject) || push!(subjects, subject)
    end
    subjects
end

function call_subjects(test, parts)
    if JS.is_infix_op_call(test)
        operator = parts[2].val
        operands = [parts[1], parts[3]]
        return comparison_subjects(operator, operands)
    end
    operator = parts[1].val
    operands = parts[2:end]
    comparison_subjects(operator, operands)
end

function type_subjects(test)
    parts = child_nodes(test)
    kind = JS.kind(test)
    if kind == K"<:"
        return comparison_subjects(:(<:), parts)
    end
    kind == K"call" || return JS.SyntaxNode[]
    call_subjects(test, parts)
end

function tested_parameter(subjects, params)
    for subject in subjects
        subject.val in params && return subject.val
    end
    nothing
end

function record_type_branch!(walk::BranchWalk, children, owner, params)
    file = walk.file
    test = children[1]
    branch = children[2]
    is_throw_guard(branch) && return
    subjects = type_subjects(test)
    parameter = tested_parameter(subjects, params)
    isnothing(parameter) && return
    location = JS.source_location(test)
    line = Int(location[1])
    detail = "a runtime type test on the method's own parameter picks the path"
    symbol = string(owner, ":", parameter)
    finding = Finding(file.mod, :type_branch, file.path, symbol, line, detail)
    push!(walk.findings, finding)
end
