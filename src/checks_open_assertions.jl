# Open assertions: a type assertion that names a parametric concrete type without its parameters leaves the asserted
# value abstract, so every read of it dispatches at run time

"""Configured through `gate(...; checks)`. A type assertion `x::T` in a method body where `T` names, in the module the code sits in, a parametric concrete type written without its parameters (a `UnionAll` over a type that is not abstract), as `fetch(task)::Wrapper` does for `struct Wrapper{M}`, or `::Vector`: the asserted value stays abstract though a concrete type was meant. An abstract type, `::AbstractVector` or `::Type`, is a deliberate choice and no finding. An argument, a field, a `local` or `global` line and an assignment's typed target declare a type rather than assert one, and a name that resolves to no type, or to a local, is no finding"""
struct OpenAssertions <: Check end

kinds(::OpenAssertions) = (:open_assertion => :advisory,)

run(::OpenAssertions, ctx) = check_open_assertions(ctx.index, ctx.root)

# Whether a `::` node declares the type of what it names: a `local`, `global` or `const` line's entry, an assignment's
# or a loop's target, or a binding the scoped walk opened at its identifier, as an argument is
function is_type_declaration(scan::FileScan, node)
    holder = node.parent
    holder_kind = JS.kind(holder)
    is_declared = holder_kind == K"local" || holder_kind == K"global" || holder_kind == K"const"
    is_declared && return true
    is_target = (holder_kind == K"=" || holder_kind == K"in") && first(child_nodes(holder)) === node
    is_target && return true
    named = first(child_nodes(node))
    local_binding(scan, named) === named
end

# Whether a type expression names a local: a `where` parameter, an argument or an assigned local of that name
function names_local(scan::FileScan, written)
    for inner in walk_nodes(written)
        isnothing(local_binding(scan, inner)) || return true
    end
    false
end

# The type an assertion in a method body writes; nothing for any other node, a declaration, a signature's annotation
# or a type that names a local
function asserted_type(scan::FileScan, node)
    JS.kind(node) == K"::" || return nothing
    parts = child_nodes(node)
    child_count(parts) == 2 || return nothing
    form = enclosing_form(node)
    isnothing(form) && return nothing
    signature = first(child_nodes(form))
    node_inside(node, signature) && return nothing
    is_type_declaration(scan, node) && return nothing
    written = last(parts)
    names_local(scan, written) && return nothing
    written
end

# A parametric concrete type with its parameters left open: a `UnionAll` whose datatype is no abstract type
function is_open_concrete(@nospecialize(resolved))
    resolved isa UnionAll || return false
    body = declared_datatype(resolved)
    isnothing(body) && return false
    !isabstracttype(body)
end

function check_open_assertions(index::SourceIndex, root::Module)
    findings = Finding[]
    for file in index.files
        home = loaded_module(root, file.mod)
        isnothing(home) && continue
        for node in walk_nodes(file.tree)
            written = asserted_type(file.scan, node)
            isnothing(written) && continue
            resolved = written_type(home, written)
            is_open_concrete(resolved) || continue
            form = enclosing_form(node)
            owner = owner_name(form, "")
            line = source_line(node)
            text = JS.sourcetext(written)
            evidence = [:type => collapse_source(text)]
            detail = "asserts a parametric type without its parameters, so the value stays abstract"
            finding = Finding(file.mod, :open_assertion, file.path, owner, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end
