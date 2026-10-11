# A runtime type test on a method's own parameter picks a path dispatch would pick.

const TYPE_COMPARISONS = (:(==), :(===), :(!=), :(!==), :(<:))

# The arguments each loaded method leaves unspecialized, by repo-relative file, line and name.
function unspecialized_arguments(defined, repo)
    found = Set{Tuple{String,Int,Symbol}}()
    for method in defined
        names = unspecialized_names(method)
        isempty(names) && continue
        file = recorded_path(method.file, repo)
        for name in names
            push!(found, (file, method.line, name))
        end
    end
    found
end

# The declaring identifiers of every argument a piece of code binds.
function argument_identifiers(scan::FileScan)
    found = Base.IdSet{JS.SyntaxNode}()
    for binding in scan.bindings
        binding.kind === :argument && push!(found, binding.node)
    end
    found
end

function check_type_branches(index::SourceIndex, defined, repo)
    findings = Finding[]
    unspecialized = unspecialized_arguments(defined, repo)
    for file in index.files
        arguments = argument_identifiers(file.scan)
        walk = BranchWalk(findings, file, arguments, unspecialized)
        visit_type_branch!(walk, file.tree, false)
    end
    findings
end

# One file's walk: where findings go, the file they name, and the arguments a test may judge.
struct BranchWalk
    findings::Vector{Finding}                       # every type branch found, in walk order
    file::FileNode                                  # the code being walked
    arguments::Base.IdSet{JS.SyntaxNode}            # declaring identifiers of the code's arguments
    unspecialized::Set{Tuple{String,Int,Symbol}}    # file, method line and name of each unspecialized argument
end

# A named method's signature holds no branch the method takes.
function has_signature_call(node)
    is_method_form(node) || return false
    signature = first(child_nodes(node))
    !isnothing(signature_call(signature))
end

# `is_discarded` says the node's value is discarded, where && and || pick a path.
function visit_type_branch!(walk::BranchWalk, node, is_discarded::Bool)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    is_condition = kind == K"&&" || kind == K"||"
    if is_branch_kind(kind) || (is_discarded && is_condition)
        record_type_branch!(walk, children)
    end
    first_index = has_signature_call(node) ? 2 : 1
    for index in first_index:length(children)
        child_is_discarded = child_discarded(node, index, is_discarded)
        visit_type_branch!(walk, children[index], child_is_discarded)
    end
end

function method_name(call)
    children = child_nodes(call)
    head = first(children)
    text = JS.sourcetext(head)
    String(text)
end

# The method, macro or closure whose arguments are the locals around `node`.
function argument_form(node)
    current = node.parent
    while !isnothing(current)
        is_argument_form(current) && return current
        current = current.parent
    end
    nothing
end

# An argument identifier the call binds whole, outside its callee slot and any destructured tuple.
function is_whole_argument(identifier, call)
    head = call_parts(call).head
    current = identifier
    parent = current.parent
    while !isnothing(parent)
        JS.kind(parent) == K"tuple" && return false
        parent === call && return current !== head
        current = parent
        parent = current.parent
    end
    false
end

# The signature call of the named method whose own specialized argument `subject` names, when the test sits in that
# method's body and in no form nested in it; nothing for any other subject.
function tested_method(walk::BranchWalk, subject, test)
    binding = local_binding(walk.file.scan, subject)
    isnothing(binding) && return nothing
    binding in walk.arguments || return nothing
    form = argument_form(binding)
    isnothing(form) && return nothing
    has_signature_call(form) || return nothing
    argument_form(test) === form || return nothing
    call = signature_call(first(child_nodes(form)))
    is_whole_argument(binding, call) || return nothing
    site = (walk.file.path, source_line(form), binding.val)
    site in walk.unspecialized && return nothing
    call
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

function record_type_branch!(walk::BranchWalk, children)
    file = walk.file
    test = children[1]
    branch = children[2]
    is_throw_guard(branch) && return
    for subject in type_subjects(test)
        call = tested_method(walk, subject, test)
        isnothing(call) && continue
        location = JS.source_location(test)
        line = Int(location[1])
        detail = "a runtime type test on the method's own parameter picks the path"
        owner = method_name(call)
        symbol = string(owner, ":", subject.val)
        finding = Finding(file.mod, :type_branch, file.path, symbol, line, detail)
        push!(walk.findings, finding)
        return
    end
end
