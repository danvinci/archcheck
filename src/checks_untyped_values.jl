# Untyped values: a container built on Any, or Any written as a type, leaves a value's type open

"""Configured through `gate(...; checks)`, with `dirs` naming directories beyond src/ to read, relative to the package root as entry dirs are. An empty `[]`, or a `Dict()`, `Set()` or `IdDict()` with no element type, builds its container on Any; `Any` written as a type, in an annotation, a type parameter or the element type of a typed array literal or comprehension, leaves the type open too. A `<:` or `>:` bound, and `Any` passed or compared as a value, store nothing"""
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

# What leaves a node's value type open: an empty `[]`, a bare `Dict()`, `Set()` or `IdDict()`, or `Any` outside a
# bound. Nothing for any other node
function untyped_detail(node)
    kind = JS.kind(node)
    if kind == K"vect"
        children = child_nodes(node)
        child_count(children) == 0 || return nothing
        return "[] builds a Vector{Any}"
    end
    if kind == K"call"
        children = child_nodes(node)
        child_count(children) == 1 || return nothing
        callee = node_symbol(only(children))
        callee in UNTYPED_CONTAINERS || return nothing
        return "$callee() builds its container on Any"
    end
    kind == K"Identifier" || return nothing
    node.val === :Any || return nothing
    is_written_type(node) || return nothing
    "Any written as a type"
end

# Whether a name sits where code states a type: the type of an annotation, a parameter of a type application, or the
# element type of a typed array literal or comprehension. A type passed as a value or compared is none of these
function is_written_type(node)
    holder = node.parent
    isnothing(holder) && return false
    kind = JS.kind(holder)
    children = child_nodes(holder)
    if kind == K"::"
        return last(children) === node
    end
    if kind == K"curly"
        return first(children) !== node
    end
    is_typed_literal = kind == K"ref" || kind == K"typed_comprehension" || kind == K"typed_vcat" || kind == K"typed_hcat"
    is_typed_literal || return false
    first(children) === node
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
