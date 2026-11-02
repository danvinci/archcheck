# String payloads: a record carried as a dictionary under string keys

"""Configured through `gate(...; checks)`, with `dirs` naming directories beyond src/ to read, relative to the package root as entry dirs are. A `Dict{String,V}` whose value type V is other than `String`, written as a type or constructed, carries a record no type names; a String-to-String map is a config file's own form"""
struct StringPayloads <: Check
    dirs::Vector{String}   # directories beyond src/ whose files the rule reads, relative to the package root
end
StringPayloads(; dirs::Vector{String} = String[]) = StringPayloads(dirs)

kinds(::StringPayloads) = (:string_payload => :advisory,)

function run(check::StringPayloads, ctx)
    roots = checked_roots(ctx.index, check.dirs)
    check_string_payloads(roots)
end

# `Dict{String,V}` with V other than `String`, the Dict bare or reached through a module
function is_string_payload(node)
    JS.kind(node) == K"curly" || return false
    children = child_nodes(node)
    child_count(children) == 3 || return false
    path = dotted_names(children[1])
    isnothing(path) && return false
    last(path) === :Dict || return false
    node_symbol(children[2]) === :String || return false
    node_symbol(children[3]) !== :String
end

function check_string_payloads(roots::Vector{CheckedRoot})
    findings = Finding[]
    for root in roots, node in walk_nodes(root.tree)
        is_string_payload(node) || continue
        form = enclosing_form(node)
        owner = owner_name(form, "")
        line = source_line(node)
        text = JS.sourcetext(node)
        written = collapse_source(text)
        detail = "a Dict keyed by String holds values other than String"
        evidence = [:type => written]
        finding = Finding(root.mod, :string_payload, root.path, owner, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
