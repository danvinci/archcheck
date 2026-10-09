# Methods the workload left uncompiled. A resolved call, or a name left to runtime dispatch, accounts for one the run skipped.

"""Configured through `gate(...; checks)` beside a workload. A method the workload left uncompiled, and that no resolved call names, is a finding. `public_is_entry` counts an exported or public name as reached."""
struct UnreachedMethods <: Check
    public_is_entry::Bool   # an exported or public name counts as an entry point
end

UnreachedMethods(; public_is_entry::Bool = false) = UnreachedMethods(public_is_entry)

kinds(::UnreachedMethods) = (:unreached_method => :advisory,)

phase(::UnreachedMethods) = :workload

function is_public_entry(check::UnreachedMethods, method::Method)
    check.public_is_entry || return false
    Base.ispublic(method.module, method.name)
end

function run(check::UnreachedMethods, ctx)
    reached = ctx.observed.reached
    graph = ctx.methods
    repo = ctx.index.repo
    modules = package_modules(ctx)
    named = named_methods(graph)
    unresolved = unresolved_names(graph)
    sites = compiled_any_sites(modules)
    findings = Finding[]
    defined = project_methods(modules)
    for method in defined
        is_public_entry(check, method) && continue
        is_unreached(method, reached, named, unresolved, sites) || continue
        finding = unreached_finding(method, repo, graph)
        push!(findings, finding)
    end
    findings
end

function argument_is_any(@nospecialize(param))
    param === Any && return true
    param isa Core.TypeofVararg || return false
    param.T === Any
end

function all_arguments_any(method::Method)
    signature = Base.unwrap_unionall(method.sig)
    signature isa DataType || return false
    params = signature.parameters
    length(params) < 2 && return false
    last_index = length(params)
    for index in 2:last_index
        argument_is_any(params[index]) || return false
    end
    true
end

function is_type_constructor(method::Method)
    signature = Base.unwrap_unionall(method.sig)
    signature isa DataType || return false
    params = signature.parameters
    isempty(params) && return false
    head = Base.unwrap_unionall(params[1])
    Base.isType(head)
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

function record_any_site!(sites, method::Method, modules)
    method.module in modules || return
    is_type_constructor(method) || return
    all_arguments_any(method) || return
    is_compiled(method) || return
    site = (method.name, method.file, method.line, method.nargs)
    push!(sites, site)
end

function compiled_any_sites(modules)
    sites = Set{Tuple{Symbol,Symbol,Int,Int}}()
    module_set = Set(modules)
    Base.visit(Core.methodtable) do method
        record_any_site!(sites, method, module_set)
    end
    sites
end

# A call written as Type{Params}(...) records its specialization on that all-Any constructor.
function constructor_recorded(method, sites)
    is_type_constructor(method) || return false
    all_arguments_any(method) && return false
    site = (method.name, method.file, method.line, method.nargs)
    site in sites
end

function is_unreached(method, reached, named, unresolved, sites)
    is_live_method(method) || return false
    is_generated(method) && return false
    is_constructor_twin(method) && return false
    method in reached && return false
    constructor_recorded(method, sites) && return false
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
