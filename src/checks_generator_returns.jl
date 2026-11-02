# Generator returns: a function that hands back a generator, for its caller to nest in another

"""Configured through `gate(...; checks)`. A top-level function whose returned value is a generator expression, as its body's tail or through a `return`: a caller that sums or maps over it nests one generator in another, which inference gives up on. Returning a concrete collection, a tuple through `ntuple` for one, keeps the caller inferred. Each such function is reported once, at its definition"""
struct GeneratorReturns <: Check end

kinds(::GeneratorReturns) = (:generator_return => :advisory,)

run(::GeneratorReturns, ctx) = check_generator_returns(ctx.index)

# The expressions a body's value can be, followed through a block's or a `let`'s last statement, a `return`'s value,
# and each arm of an `if`, `elseif` or ternary
function value_tails!(found, node)
    kind = JS.kind(node)
    children = child_nodes(node)
    child_count(children) == 0 && return push!(found, node)
    if kind == K"block" || kind == K"let" || kind == K"return"
        return value_tails!(found, last(children))
    end
    is_branch_kind(kind) || return push!(found, node)
    for arm in children[2:end]
        value_tails!(found, arm)
    end
    found
end

# Every value a method hands back: its body's tail, and each `return` the method itself holds, outside the closures
# and local methods in it
function returned_values(form)
    body = method_body(form)
    isnothing(body) && return JS.SyntaxNode[]
    found = value_tails!(JS.SyntaxNode[], body)
    for node in walk_nodes(body)
        JS.kind(node) == K"return" || continue
        enclosing_form(node) === form || continue
        value_tails!(found, node)
    end
    found
end

# The methods the code defines outside every other method, macro and closure, in source order
function top_level_forms(scan::FileScan)
    forms = JS.SyntaxNode[]
    seen = Base.IdSet{JS.SyntaxNode}()
    for form in values(scan.forms)
        form in seen && continue
        push!(seen, form)
        isnothing(enclosing_form(form)) || continue
        push!(forms, form)
    end
    sort!(forms, by = JS.first_byte)
end

function check_generator_returns(index::SourceIndex)
    findings = Finding[]
    for file in index.files, form in top_level_forms(file.scan)
        returned = returned_values(form)
        generator = findfirst(value -> JS.kind(value) == K"generator", returned)
        isnothing(generator) && continue
        owner = owner_name(form, "")
        line = source_line(form)
        text = JS.sourcetext(returned[generator])
        written = collapse_source(text)
        detail = "returns a generator, which a caller iterating it nests in its own"
        evidence = [:returns => written]
        finding = Finding(file.mod, :generator_return, file.path, owner, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
