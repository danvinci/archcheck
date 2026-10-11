# Methods the workload left uncompiled. A call in the method graph that can land on one accounts for it.

"""Configured through `gate(...; checks)` beside a workload. A method the workload left uncompiled, and that no call in the method graph can land on, is a finding. The gate reads what the workload compiled before it walks the graph, since the walk makes a specialization of every method it walks. A method a macro builds where the source writes no definition of it stays quiet. `public_is_entry`, on by default as for `DeadCode`, counts an exported or public name as reached; an application turns it off."""
struct UnreachedMethods <: Check
    public_is_entry::Bool   # an exported or public name counts as an entry point
end

UnreachedMethods(; public_is_entry::Bool = true) = UnreachedMethods(public_is_entry)

kinds(::UnreachedMethods) = (:unreached_method => :advisory,)

phase(::UnreachedMethods) = :workload

function is_public_entry(check::UnreachedMethods, method::Method)
    check.public_is_entry || return false
    Base.ispublic(method.module, method.name)
end

function run(check::UnreachedMethods, ctx)
    reached = ctx.observed.reached
    graph = ctx.methods
    recorded = ctx.recorded
    landed = landed_methods(graph)
    findings = Finding[]
    for method in ctx.defined
        is_public_entry(check, method) && continue
        is_unreached(method, reached, landed) || continue
        has_source_site(method, ctx.index, recorded) || continue
        finding = unreached_finding(method, recorded, graph)
        push!(findings, finding)
    end
    findings
end

function specific_sibling(method::Method)
    owner = defined_callable(method)
    owner isa Type || return nothing
    for other in methods(owner)
        other === method && continue
        other.file === method.file || continue
        other.line == method.line || continue
        other.nargs == method.nargs || continue
        all_arguments_any(other) && continue
        return other
    end
    nothing
end

# Julia installs an all-Any constructor beside each typed one.
function is_constructor_twin(method::Method)
    is_type_constructor(method) || return false
    all_arguments_any(method) || return false
    sibling = specific_sibling(method)
    !isnothing(sibling)
end

function is_unreached(method, reached, landed)
    is_live_method(method) || return false
    is_generated(method) && return false
    is_constructor_twin(method) && return false
    method in reached && return false
    !(method in landed)
end

# The statement of `code` that holds `line`, looking into blocks and past a docstring to what it documents.
function statement_at(code, line)
    statements = child_nodes(code)
    isnothing(statements) && return nothing
    for statement in statements
        span = line_span(statement)
        line in span || continue
        kind = JS.kind(statement)
        kind == K"block" && return statement_at(statement, line)
        kind == K"doc" || return statement
        documented = child_nodes(statement)
        return last(documented)
    end
    nothing
end

function writes_definition(call)
    for node in walk_nodes(call)
        is_method_form(node) && return true
        kind = JS.kind(node)
        is_type_form(kind) && return true
    end
    false
end

# A macro can build a method where the source writes no definition of it: `@enum` files its methods at the call, a
# macro from outside the package in its own file. Such a method has no source line to act on.
function has_source_site(method::Method, index::SourceIndex, recorded::RecordedPaths)
    path, line = method_site(method, recorded)
    file = indexed_file(index, path, line)
    isnothing(file) && return false
    statement = statement_at(file.tree, line)
    isnothing(statement) && return true
    JS.kind(statement) == K"macrocall" || return true
    writes_definition(statement)
end

function landed_methods(graph::MethodGraph)
    landed = Set{Method}()
    for callees in values(graph.edges)
        union!(landed, callees)
    end
    landed
end

landed_methods(::Nothing) = Set{Method}()

function unreached_detail(::MethodGraph)
    "the workload compiled no specialization of this method, and no call in the method graph can land on it"
end

function unreached_detail(::Nothing)
    "the workload compiled no specialization of this method"
end

function unreached_finding(method, recorded, graph)
    file, line = method_site(method, recorded)
    owner = module_key(method.module)
    name = string(method.name)
    signature = type_text(method.sig)
    module_name = string(owner)
    detail = unreached_detail(graph)
    evidence = Pair{Symbol,String}[
        :module => module_name,
        :signature => signature,
    ]
    Finding(owner, :unreached_method, file, name, line, detail, evidence)
end
