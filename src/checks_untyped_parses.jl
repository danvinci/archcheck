# Untyped parses: a JSON.jl parse with no target type builds its value on Any

"""Configured through `gate(...; checks)`. A call to JSON.jl's `parse` or `parsefile`, bare or qualified, as the name resolves in the module the code sits in, given no target type: `JSON.parse(text)` rather than `JSON.parse(text, T)`. The value is a `JSON.Object` or a `Dict{String,Any}`, so every read of it by key dispatches at run time. A call with a splatted argument may pass a type and is no finding, and a package that loads no JSON.jl has none"""
struct UntypedParses <: Check end

kinds(::UntypedParses) = (:untyped_parse => :advisory,)

run(::UntypedParses, ctx) = check_untyped_parses(ctx.index, ctx.root)

# JSON.jl's readers, as this package loads them: a session loads one JSON.jl, so a package's binding is the same object
const JSON_READERS = (JSON.parse, JSON.parsefile)

# Whether a call or broadcast reads JSON with no target type: its callee resolves to one of JSON.jl's readers and it
# passes one positional argument, the source, which no splat widens
function is_untyped_parse(scan::FileScan, home::Module, node)
    kind = JS.kind(node)
    is_call = kind == K"call" || kind == K"dotcall"
    is_call || return false
    is_operator_call(node) && return false
    head = first(child_nodes(node))
    callee = global_value(scan, home, head)
    any(reader -> reader === callee, JSON_READERS) || return false
    arguments = positional_arguments(node)
    length(arguments) == 1 || return false
    JS.kind(only(arguments)) != K"..."
end

function check_untyped_parses(index::SourceIndex, root::Module)
    findings = Finding[]
    for file in index.files
        home = loaded_module(root, file.mod)
        isnothing(home) && continue
        for node in walk_nodes(file.tree)
            is_untyped_parse(file.scan, home, node) || continue
            is_quoted(node) && continue
            form = enclosing_form(node)
            owner = owner_name(form, "")
            line = source_line(node)
            text = JS.sourcetext(node)
            evidence = [:call => collapse_source(text)]
            detail = "parses JSON with no target type, so every read of the value dispatches at run time"
            finding = Finding(file.mod, :untyped_parse, file.path, owner, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end
