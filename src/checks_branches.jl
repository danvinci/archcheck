# A runtime type test on a method's own parameter picks a path dispatch would pick.

const TYPE_COMPARISONS = (:(==), :(===), :(!=), :(!==), :(<:))

function check_type_branches(index::SourceIndex)
    findings = Finding[]
    discarded = IdSet{JS.SyntaxNode}()   # nodes whose value is discarded, where && and || pick a path
    for file in index.files
        visit_type_branch!(findings, discarded, file, file.tree, "", Symbol[])
    end
    findings
end

function visit_type_branch!(findings, discarded, file, node, owner, params)
    kids = child_nodes(node)
    isnothing(kids) && return
    mark_discarded!(discarded, node, kids)
    kind = JS.kind(node)
    label = branch_label(kind)
    marker = Val(label)
    visit_label!(marker, findings, discarded, file, node, kids, owner, params)
end

# Labels group the node kinds that share one walk.
# A signature on a syntax kind changes compilation of the parser the workload runs under.
function branch_label(kind)
    kind == K"->" && return :cleared
    kind == K"do" && return :cleared
    kind == K"function" && return :function_form
    kind == K"=" && return :assign
    kind == K"for" && return :for_loop
    kind == K"generator" && return :generator
    kind == K"if" && return :branch
    kind == K"elseif" && return :branch
    kind == K"?" && return :branch
    kind == K"&&" && return :short_circuit
    kind == K"||" && return :short_circuit
    :other
end

function mark_discarded!(discarded, node, kids)
    parent_discarded = node in discarded
    for index in eachindex(kids)
        is_discarded = child_discarded(node, index, parent_discarded)
        is_discarded || continue
        push!(discarded, kids[index])
    end
end

function visit_children!(findings, discarded, file, kids, owner, params)
    for child in kids
        visit_type_branch!(findings, discarded, file, child, owner, params)
    end
end

# An anonymous function and a do-block bind their own parameters, hiding the method's.
function visit_cleared!(findings, discarded, file, kids)
    for part in kids
        visit_type_branch!(findings, discarded, file, part, "", Symbol[])
    end
end

function visit_label!(::Val{:cleared}, findings, discarded, file, node, kids, owner, params)
    visit_cleared!(findings, discarded, file, kids)
end

function method_name(call)
    children = child_nodes(call)
    head = first(children)
    JS.sourcetext(head)
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

function visit_method_body!(findings, discarded, file, kids, call)
    owner = method_name(call)
    params = method_parameters(call)
    for part in kids[2:end]
        visit_type_branch!(findings, discarded, file, part, owner, params)
    end
end

function visit_method_scope!(findings, discarded, file, kids)
    signature = kids[1]
    call = signature_call(signature)
    if isnothing(call)
        visit_cleared!(findings, discarded, file, kids)
        return
    end
    visit_method_body!(findings, discarded, file, kids, call)
end

function visit_label!(::Val{:function_form}, findings, discarded, file, node, kids, owner, params)
    visit_method_scope!(findings, discarded, file, kids)
end

function visit_label!(::Val{:assign}, findings, discarded, file, node, kids, owner, params)
    if is_method_form(node)
        visit_method_scope!(findings, discarded, file, kids)
        return
    end
    visit_children!(findings, discarded, file, kids, owner, params)
end

function visit_loop!(findings, discarded, file, specs, body, owner, params)
    targets = Symbol[]
    for spec in specs
        bound_names!(targets, spec)
    end
    for spec in specs
        visit_type_branch!(findings, discarded, file, spec, owner, params)
    end
    kept = setdiff(params, targets)
    visit_type_branch!(findings, discarded, file, body, owner, kept)
end

function visit_label!(::Val{:for_loop}, findings, discarded, file, node, kids, owner, params)
    specs = kids[1:end-1]
    body = last(kids)
    visit_loop!(findings, discarded, file, specs, body, owner, params)
end

function visit_label!(::Val{:generator}, findings, discarded, file, node, kids, owner, params)
    body = first(kids)
    specs = kids[2:end]
    visit_loop!(findings, discarded, file, specs, body, owner, params)
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

function record_type_branch!(findings, file, kids, owner, params)
    test = kids[1]
    branch = kids[2]
    is_throw_guard(branch) && return
    subjects = type_subjects(test)
    parameter = tested_parameter(subjects, params)
    isnothing(parameter) && return
    location = JS.source_location(test)
    line = Int(location[1])
    detail = "a runtime type test on the method's own parameter picks the path"
    symbol = string(owner, ":", parameter)
    finding = Finding(file.mod, :type_branch, file.path, symbol, line, detail)
    push!(findings, finding)
end

function visit_label!(::Val{:branch}, findings, discarded, file, node, kids, owner, params)
    record_type_branch!(findings, file, kids, owner, params)
    visit_children!(findings, discarded, file, kids, owner, params)
end

function visit_label!(::Val{:short_circuit}, findings, discarded, file, node, kids, owner, params)
    if node in discarded
        record_type_branch!(findings, file, kids, owner, params)
    end
    visit_children!(findings, discarded, file, kids, owner, params)
end

function visit_label!(::Val{:other}, findings, discarded, file, node, kids, owner, params)
    visit_children!(findings, discarded, file, kids, owner, params)
end
