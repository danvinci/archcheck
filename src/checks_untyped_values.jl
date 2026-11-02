# Untyped values: an empty container with no element type is built on Any

"""Configured through `gate(...; checks)`, with `dirs` naming directories beyond src/ to read, relative to the package root as entry dirs are. An empty `[]`, or a `Dict()`, `Set()` or `IdDict()` with no element type, builds its container on Any, so every read of it dispatches at run time"""
struct UntypedValues <: Check
    dirs::Vector{String}   # directories beyond src/ whose files the rule reads, relative to the package root
end
UntypedValues(; dirs::Vector{String} = String[]) = UntypedValues(dirs)

kinds(::UntypedValues) = (:untyped_value => :advisory,)

function run(check::UntypedValues, ctx)
    roots = checked_roots(ctx.index, check.dirs)
    check_untyped_values(roots)
end

# Containers whose constructor with no argument builds them on Any
const UNTYPED_CONTAINERS = (:Dict, :Set, :IdDict)

# What builds an empty container on Any: `[]`, or a bare `Dict()`, `Set()` or `IdDict()`; nothing for any other node
function untyped_detail(node)
    kind = JS.kind(node)
    children = child_nodes(node)
    if kind == K"vect"
        child_count(children) == 0 || return nothing
        return "[] builds a Vector{Any}"
    end
    kind == K"call" || return nothing
    child_count(children) == 1 || return nothing
    callee = node_symbol(only(children))
    callee in UNTYPED_CONTAINERS || return nothing
    "$callee() builds its container on Any"
end

function check_untyped_values(roots::Vector{CheckedRoot})
    findings = Finding[]
    for root in roots, node in walk_nodes(root.tree)
        detail = untyped_detail(node)
        isnothing(detail) && continue
        form = enclosing_form(node)
        owner = owner_name(form, "")
        line = source_line(node)
        text = JS.sourcetext(node)
        written = collapse_source(text)
        evidence = [:form => written]
        finding = Finding(root.mod, :untyped_value, root.path, owner, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
