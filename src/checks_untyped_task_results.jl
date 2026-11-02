# Untyped task results: a task's value read with no element type dispatches at run time

"""Configured through `gate(...; checks)`. A read of a task's result with no element type: a call `fetch(x)`, `fetch.(xs)`, `map(fetch, xs)` or `asyncmap(...)` whose value the code reads, where `fetch`, `map` and `asyncmap` resolve to Base's functions in the module the code sits in. `fetch` returns Any and `asyncmap` an abstract Vector, so everything built from the value dispatches at run time. The call as the operand of a type assertion (`fetch(t)::T`) or as the element of a typed comprehension (`T[fetch(t) for t in tasks]`) names its type and is no finding, and a discarded `fetch` is `UnreadWaits`' finding"""
struct UntypedTaskResults <: Check end

kinds(::UntypedTaskResults) = (:untyped_task_result => :advisory,)

run(::UntypedTaskResults, ctx) = check_untyped_task_results(ctx.index, ctx.root)

# Whether a call or broadcast reads a task's result: its callee is Base's `fetch` or `asyncmap`, or Base's `map` given
# Base's `fetch` as its function
function reads_task_result(scan::FileScan, home::Module, node)
    kind = JS.kind(node)
    is_call = kind == K"call" || kind == K"dotcall"
    is_call || return false
    is_operator_call(node) && return false
    head = first(child_nodes(node))
    callee = global_value(scan, home, head)
    callee === fetch && return true
    callee === asyncmap && return true
    kind == K"call" && callee === map || return false
    arguments = positional_arguments(node)
    isempty(arguments) && return false
    mapped = first(arguments)
    global_value(scan, home, mapped) === fetch
end

# Whether the code names the type of a call's value: the call is a type assertion's operand, or the element a typed
# comprehension builds
function is_typed_read(node)
    holder = node.parent
    holder_kind = JS.kind(holder)
    is_operand = holder_kind == K"::" && first(child_nodes(holder)) === node
    is_operand && return true
    holder_kind == K"generator" || return false
    first(child_nodes(holder)) === node || return false
    JS.kind(holder.parent) == K"typed_comprehension"
end

# Whether the scan proves the call's value unread, as `UnreadWaits` reads a discarded `fetch`
function is_dropped_read(usage::Dict{CallKey,Vector{Bool}}, node)
    naming = called_name(node)
    isnothing(naming) && return false
    is_dropped_call(usage, node, naming)
end

function check_untyped_task_results(index::SourceIndex, root::Module)
    findings = Finding[]
    for file in index.files
        home = loaded_module(root, file.mod)
        isnothing(home) && continue
        usage = call_usage(file.scan)
        for node in walk_nodes(file.tree)
            reads_task_result(file.scan, home, node) || continue
            is_quoted(node) && continue
            is_typed_read(node) && continue
            is_dropped_read(usage, node) && continue
            form = enclosing_form(node)
            owner = owner_name(form, "")
            line = source_line(node)
            text = JS.sourcetext(node)
            evidence = [:call => collapse_source(text)]
            detail = "reads a task's result with no element type, so the value stays abstract"
            finding = Finding(file.mod, :untyped_task_result, file.path, owner, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end
