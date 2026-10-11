# Joins whose result the method drops: a discarded fetch, any wait, a bare fetch or wait passed onward, an @sync block.

"""Configured through `gate(...; checks)`. A package names functions whose joins wait on a file or a device. Any other discarded `fetch`, bare `wait`, passed join, or `@sync` block is a finding."""
struct UnreadWaits{A<:NTuple{N,Symbol} where N} <: Check
    allowed::A   # function names whose joins wait on a file or a device queue
end

UnreadWaits(; allowed = ()) = UnreadWaits(Tuple(Symbol(name) for name in allowed))

kinds(::UnreadWaits) = (:unread_wait => :advisory,)

phase(::UnreadWaits) = :static

const UNREAD_DETAIL = (
    fetch = "fetch joins a task and drops the result",
    wait = "wait joins a task and returns nothing",
    passed = "the call passes fetch or wait by name, so each result is dropped",
    sync = "@sync joins the tasks written in its block",
)

function unread_finding(file, site, form, text, line)
    detail = UNREAD_DETAIL[form]
    label = string(form)
    evidence = Pair{Symbol,String}[:form => label, :call => text]
    symbol = string(site.name)
    Finding(file.mod, :unread_wait, file.path, symbol, line, detail, evidence)
end

function direct_form(call)
    if call.callee === :fetch && !call.is_used
        return :fetch
    end
    if call.callee === :wait
        return :wait
    end
    nothing
end

# The bare name of Base's join, naming no local; a parameter named `wait` is the caller's value.
is_free_join(node, scan) = node.val in (:fetch, :wait) && isnothing(local_binding(scan, node))

function passes_join(call, scan)
    passed = passed_values(call)
    any(value -> is_free_join(value, scan), passed)
end

function emit_node!(findings, file, site, form, node)
    raw = JS.sourcetext(node)
    text = collapse_source(raw)
    line = source_line(node)
    finding = unread_finding(file, site, form, text, line)
    push!(findings, finding)
end

# A form recorded on its own site is walked from that site; a local method contributes its body.
function walk_unread!(findings, file, site, node, known)
    if is_method_form(node)
        node in known && return
        body = method_body(node)
        isnothing(body) && return
        walk_unread!(findings, file, site, body, known)
        return
    end
    kind = JS.kind(node)
    if (kind == K"call" || kind == K"dotcall") && passes_join(node, file.scan)
        emit_node!(findings, file, site, :passed, node)
    elseif is_sync_macro(node)
        emit_node!(findings, file, site, :sync, node)
    end
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        walk_unread!(findings, file, site, child, known)
    end
end

function run(check::UnreadWaits, ctx)
    findings = Finding[]
    for file in ctx.index.files
        for (site, calls) in file.scan.callsites
            site.name in check.allowed && continue
            for call in calls
                direct = direct_form(call)
                isnothing(direct) && continue
                text = call_text(call)
                finding = unread_finding(file, site, direct, text, call.line)
                push!(findings, finding)
            end
        end
        forms = values(file.scan.forms)
        known = Base.IdSet{JS.SyntaxNode}(forms)
        for (site, node) in file.scan.forms
            site.name in check.allowed && continue
            body = method_body(node)
            isnothing(body) && continue
            walk_unread!(findings, file, site, body, known)
        end
    end
    findings
end
