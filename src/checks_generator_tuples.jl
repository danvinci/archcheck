# Generator tuples: a Tuple built from a generator has a length only the run knows

"""Configured through `gate(...; checks)`. `Tuple(x)` where `x` is a generator or a comprehension: inference cannot know the tuple's length, so every read of it dispatches at run time. `ntuple(f, n)` builds the same tuple at a length inference reads"""
struct GeneratorTuples <: Check end

kinds(::GeneratorTuples) = (:generator_tuple => :advisory,)

run(::GeneratorTuples, ctx) = check_generator_tuples(ctx.index)

# Forms whose length is known only once they run: a generator, a comprehension, a typed comprehension
function is_generated_sequence(node)
    kind = JS.kind(node)
    kind == K"generator" || kind == K"comprehension" || kind == K"typed_comprehension"
end

# The generated sequence a bare `Tuple(...)` call is given; nothing for any other node
function generated_tuple_argument(node)
    JS.kind(node) == K"call" || return nothing
    children = child_nodes(node)
    callee = node_symbol(first(children))
    callee === :Tuple || return nothing
    arguments = call_args(node)
    length(arguments) == 1 || return nothing
    argument = only(arguments)
    is_generated_sequence(argument) || return nothing
    argument
end

function check_generator_tuples(index::SourceIndex)
    findings = Finding[]
    for file in index.files, node in walk_nodes(file.tree)
        argument = generated_tuple_argument(node)
        isnothing(argument) && continue
        form = enclosing_form(node)
        owner = owner_name(form, "")
        line = source_line(node)
        text = JS.sourcetext(argument)
        written = collapse_source(text)
        detail = "builds a Tuple from a generated sequence, whose length inference cannot know"
        evidence = [:argument => written]
        finding = Finding(file.mod, :generator_tuple, file.path, owner, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
