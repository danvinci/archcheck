# Methods the workload left uncompiled. A resolved call, or a name left to runtime dispatch, accounts for one the run skipped.

struct UnreachedMethods <: Check end

kinds(::UnreachedMethods) = (:unreached_method => :advisory,)

phase(::UnreachedMethods) = :workload

function run(::UnreachedMethods, ctx)
    reached = ctx.observed.reached
    graph = ctx.methods
    repo = ctx.index.repo
    modules = package_modules(ctx)
    named = named_methods(graph)
    unresolved = unresolved_names(graph)
    findings = Finding[]
    defined = project_methods(modules)
    for method in defined
        is_unreached(method, reached, named, unresolved) || continue
        finding = unreached_finding(method, repo, graph)
        push!(findings, finding)
    end
    findings
end

function is_unreached(method, reached, named, unresolved)
    is_live_method(method) || return false
    is_generated(method) && return false
    method in reached && return false
    graph_names(method, named, unresolved) && return false
    true
end

# An unresolved call is stored under the callee's name, and every live method of that name stays out.
function graph_names(method, named, unresolved)
    method in named && return true
    method.name in unresolved
end

function named_methods(graph::MethodGraph)
    named = Set{Method}()
    for callees in values(graph.edges)
        union!(named, callees)
    end
    named
end

named_methods(::Nothing) = Set{Method}()

function unresolved_names(graph::MethodGraph)
    unresolved = Set{Symbol}()
    for called in values(graph.unresolved)
        union!(unresolved, called)
    end
    unresolved
end

unresolved_names(::Nothing) = Set{Symbol}()

function unreached_detail(::MethodGraph)
    "the workload compiled no specialization of this method, and no resolved call names it"
end

function unreached_detail(::Nothing)
    "the workload compiled no specialization of this method"
end

function unreached_finding(method, repo, graph)
    file, line = method_site(method, repo)
    owner = module_key(method.module)
    name = string(method.name)
    signature = string(method.sig)
    module_name = string(owner)
    detail = unreached_detail(graph)
    evidence = Pair{Symbol,String}[
        :module => module_name,
        :signature => signature,
    ]
    Finding(owner, :unreached_method, file, name, line, detail, evidence)
end
