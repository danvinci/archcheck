# Tuple iteration: a flatten over a Tuple or NamedTuple compiles one `iterate` method per inner state type.

"""Runs in `CHECKS`. An `Iterators.flatten` call, or a generator with a second `for`, whose outer iterated source is a Tuple or NamedTuple: a tuple literal, or a method argument annotated `Tuple` or `NamedTuple`, bare or read through `values` or `pairs`."""
struct TupleIterations <: Check end

kinds(::TupleIterations) = (:tuple_iteration => :error,)

run(::TupleIterations, ctx) = check_tuple_iterations(ctx.index)

# Types whose slots may each hold a different type. `NTuple` holds one, so its flatten compiles one `iterate`.
const TUPLE_TYPES = (:Tuple, :NamedTuple)

# Calls whose result iterates the slots of the collection they are given.
const SLOT_ITERATORS = (:values, :pairs)

# The collection a generator's first `for` iterates, read through a filter on that `for`.
function outer_source(generator)
    spec = child_nodes(generator)[2]
    if JS.kind(spec) == K"filter"
        spec = first(child_nodes(spec))
    end
    clause = first(child_nodes(spec))
    last(child_nodes(clause))
end

# `Iterators.flatten(...)`, the module bare or reached through `Base`.
function is_flatten_call(call)
    head = first(child_nodes(call))
    path = dotted_names(head)
    isnothing(path) && return false
    length(path) >= 2 || return false
    path[end] === :flatten && path[end - 1] === :Iterators
end

# The outer source a flatten iterates: a generator's when a second `for` nests in it, or the argument of
# `Iterators.flatten`, read through a generator. Nothing for any other node.
function flattened_source(node)
    kind = JS.kind(node)
    if kind == K"generator"
        specs = child_count(child_nodes(node)) - 1
        specs >= 2 || return nothing
        return outer_source(node)
    end
    kind == K"call" || return nothing
    is_flatten_call(node) || return nothing
    arguments = call_args(node)
    length(arguments) == 1 || return nothing
    argument = only(arguments)
    JS.kind(argument) == K"generator" || return argument
    outer_source(argument)
end

# Whether the code states a source is a Tuple or NamedTuple: a tuple literal, a read of an argument annotated with one,
# or `values` or `pairs` of either.
function is_tuple_source(scan::FileScan, source)
    kind = JS.kind(source)
    kind == K"tuple" && return true
    if kind == K"call"
        arguments = call_args(source)
        length(arguments) == 1 || return false
        callee = node_symbol(first(child_nodes(source)))
        callee in SLOT_ITERATORS || return false
        return is_tuple_source(scan, only(arguments))
    end
    binding = local_binding(scan, source)
    isnothing(binding) && return false
    binding_kind(binding) === :argument || return false
    annotation = binding.parent
    JS.kind(annotation) == K"::" || return false
    declared = last(child_nodes(annotation))
    type_name(declared) in TUPLE_TYPES
end

function check_tuple_iterations(index::SourceIndex)
    findings = Finding[]
    for file in index.files, node in walk_nodes(file.tree)
        source = flattened_source(node)
        isnothing(source) && continue
        is_tuple_source(file.scan, source) || continue
        line = source_line(node)
        text = JS.sourcetext(source)
        iterated = collapse_source(text)
        form = enclosing_form(node)
        owner = owner_name(form, "")
        detail = "flattens iteration over a Tuple or NamedTuple"
        evidence = [:iterates => iterated]
        finding = Finding(file.mod, :tuple_iteration, file.path, owner, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
