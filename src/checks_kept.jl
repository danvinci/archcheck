# A builder that drops the value it builds.

"""Configured through `gate(...; checks)` with the builder. A method calls that builder and drops the value, while another method keeps it with `get!`."""
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

kinds(::KeptBuilders) = (:kept_builder => :advisory,)

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
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return false
    naming = name_of_head(kids[1])
    isnothing(naming) && return false
    isempty(naming.qualifier) || return false
    naming.callee === :get!
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
    if head.val isa Symbol
        return head.val === bare
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
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return false
    names_builder(kids[1], builder, bare)
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
    name, _ = path_parts(check.builder)
    func = package_callable(ctx, check.builder)
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
