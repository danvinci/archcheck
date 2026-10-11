# Joins whose result the method drops: a discarded fetch, a wait on a task, a join passed onward, an @sync block.

"""Configured through `gate(...; checks)`. A package names functions whose joins wait on a file or a device. Any other discarded `fetch`, `wait` whose call the method graph's inference resolves to the task's `wait` alone, `fetch` or `wait` passed by name to `foreach` or to a call whose value goes unread, or `@sync` block is a finding. A `wait` in a method the graph did not walk stays unjudged, so the gate needs `entries` for it."""
struct UnreadWaits{A<:NTuple{N,Symbol} where N} <: Check
    allowed::A   # function names whose joins wait on a file or a device queue
end

UnreadWaits(; allowed = ()) = UnreadWaits(Tuple(Symbol(name) for name in allowed))

kinds(::UnreadWaits) = (:unread_wait => :advisory,)

phase(::UnreadWaits) = :graph

const UNREAD_DETAIL = (
    fetch = "fetch joins a task and drops the result",
    wait = "wait joins a task and returns nothing",
    passed = "the call passes fetch or wait by name, so each result is dropped",
    sync = "@sync joins the tasks written in its block",
)

# A recorded call by its line, callee, qualifier, argument text and keyword text.
const CallKey = Tuple{Int,Symbol,String,String,String}

# One file's methods as the walk for passed joins and `@sync` blocks reads them.
struct JoinWalk
    file::FileNode                      # file holding the methods
    known::Base.IdSet{JS.SyntaxNode}    # forms walked from their own sites
    usage::Dict{CallKey,Vector{Bool}}   # whether each recorded call's value is read, calls written alike together
end

function unread_finding(file, site, form, text, line)
    detail = UNREAD_DETAIL[form]
    label = string(form)
    evidence = Pair{Symbol,String}[:form => label, :call => text]
    symbol = string(site.name)
    Finding(file.mod, :unread_wait, file.path, symbol, line, detail, evidence)
end

# The methods a statement's `wait` call can take at the argument types inference holds there; nothing for a statement
# that calls no `wait`, and none when inference holds no type for an argument. `kwcall` names its callee in argument 3.
function waited_methods(code, statement)
    call = call_expression(statement)
    isnothing(call) && return nothing
    args = call.args
    isempty(args) && return nothing
    head = held_type(code, first(args))
    first_argument = 2
    if head === typeof(Core.kwcall)
        length(args) < 3 && return nothing
        head = held_type(code, args[3])
        first_argument = 4
    end
    head === typeof(wait) || return nothing
    types = Any[head]
    found = Method[]
    for arg in args[first_argument:end]
        held = held_type(code, arg)
        isnothing(held) && return found
        push!(types, held)
    end
    signature = Tuple{types...}
    for match in matching_methods(signature)
        push!(found, match.method)
    end
    found
end

# Each line of one typed body that calls `wait`: whether every such call there takes the task's `wait` alone.
function note_wait_lines!(lines, code, method, recorded, task_wait)
    for (position, statement) in pairs(code.code)
        resolved = waited_methods(code, statement)
        isnothing(resolved) && continue
        file, line = statement_location(code.debuginfo, method, position)
        path = site_path(recorded, file)
        is_join = !isempty(resolved) && all(landed -> landed === task_wait, resolved)
        key = (path, line)
        held = get(lines, key, true)
        lines[key] = held && is_join
    end
end

# The `wait` lines of every method the graph walked, read off the code its inference typed. A line no walked method's
# code holds stays out, and so does every line when no graph was walked.
function task_join_lines(graph::MethodGraph, recorded)
    task_wait = which(wait, Tuple{Task})
    lines = Dict{Tuple{String,Int},Bool}()
    for (method, codes) in graph.typed
        for code in codes
            note_wait_lines!(lines, code, method, recorded, task_wait)
        end
    end
    lines
end

task_join_lines(::Nothing, _recorded) = Dict{Tuple{String,Int},Bool}()

function direct_form(call, path, joins)
    if call.callee === :fetch && !call.is_used
        return :fetch
    end
    call.callee === :wait || return nothing
    key = (path, call.line)
    get(joins, key, false) ? :wait : nothing
end

# Whether each recorded call's value is read, keyed by what the call writes.
function call_usage(scan)
    usage = Dict{CallKey,Vector{Bool}}()
    for calls in values(scan.callsites)
        for call in calls
            key = (call.line, call.callee, call.qualifier, call.arguments, call.keywords)
            flags = get!(Vector{Bool}, usage, key)
            push!(flags, call.is_used)
        end
    end
    usage
end

# Whether the scan proves a call's value unread: every call written alike on its line drops its value.
function is_dropped_call(walk::JoinWalk, node, naming)
    arguments = arguments_text(node)
    keywords = keywords_text(node)
    line = source_line(node)
    key = (line, naming.callee, naming.qualifier, arguments, keywords)
    flags = get(walk.usage, key, nothing)
    isnothing(flags) && return false
    !any(flags)
end

# Base's join by its bare name, naming no local; a parameter named `wait` is the caller's value.
is_free_join(node, scan) = node.val in (:fetch, :wait) && isnothing(local_binding(scan, node))

function passes_join(call, scan)
    passed = passed_values(call)
    any(value -> is_free_join(value, scan), passed)
end

# A passed join drops each result when the receiving call's value goes unread or the receiver is `foreach`, which
# keeps none. A receiver whose value is read can keep each result, or hold the join as a value it reads.
function drops_passed(walk::JoinWalk, call)
    scan = walk.file.scan
    passes_join(call, scan) || return false
    naming = called_name(call)
    isnothing(naming) && return false
    naming.callee === :foreach && return true
    is_dropped_call(walk, call, naming)
end

function emit_node!(findings, file, site, form, node)
    raw = JS.sourcetext(node)
    text = collapse_source(raw)
    line = source_line(node)
    finding = unread_finding(file, site, form, text, line)
    push!(findings, finding)
end

# A form recorded on its own site is walked from that site; a local method contributes its body. Code a quote holds
# is what the method returns, so it joins nothing.
function walk_unread!(findings, walk::JoinWalk, site, node)
    if is_method_form(node)
        node in walk.known && return
        body = method_body(node)
        isnothing(body) && return
        walk_unread!(findings, walk, site, body)
        return
    end
    kind = JS.kind(node)
    is_call = kind == K"call" || kind == K"dotcall"
    if is_call && !is_quoted(node) && drops_passed(walk, node)
        emit_node!(findings, walk.file, site, :passed, node)
    elseif is_sync_macro(node) && !is_quoted(node)
        emit_node!(findings, walk.file, site, :sync, node)
    end
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        walk_unread!(findings, walk, site, child)
    end
end

function run(check::UnreadWaits, ctx)
    joins = task_join_lines(ctx.methods, ctx.recorded)
    findings = Finding[]
    for file in ctx.index.files
        for (site, calls) in file.scan.callsites
            site.name in check.allowed && continue
            for call in calls
                direct = direct_form(call, file.path, joins)
                isnothing(direct) && continue
                text = call_text(call)
                finding = unread_finding(file, site, direct, text, call.line)
                push!(findings, finding)
            end
        end
        forms = values(file.scan.forms)
        known = Base.IdSet{JS.SyntaxNode}(forms)
        usage = call_usage(file.scan)
        walk = JoinWalk(file, known, usage)
        for (site, node) in file.scan.forms
            site.name in check.allowed && continue
            body = method_body(node)
            isnothing(body) && continue
            walk_unread!(findings, walk, site, body)
        end
    end
    findings
end
