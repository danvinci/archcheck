# Reflection checks (duplicate-owner, sinkable): the method table is dispatch-aware, so these
# read the loaded modules, not source text.

# The function a method belongs to; nothing for a keyword method, a callable struct, or an abstract callee.
function method_function(method::Method)
    params = signature_types(method.sig)
    isempty(params) && return nothing
    callee = params[1]
    callee isa DataType || return nothing
    isdefined(callee, :instance) || return nothing
    value = callee.instance
    value isa Function || return nothing
    value === Core.kwcall && return nothing
    value
end

# The defined methods grouped by their function, each group in source order.
function methods_by_function(defined)
    grouped = IdDict{Function,Vector{Method}}()
    for method in defined
        value = method_function(method)
        isnothing(value) && continue
        group = get!(Vector{Method}, grouped, value)
        push!(group, method)
    end
    grouped
end

# A loaded module's key, as the source index names it: its path below the package root, `Geometry.Meshes`.
# The root has no path below it, so it is keyed by its own name.
function module_key(mod::Module)
    parts = fullname(mod)
    texts = String[]
    for part in parts
        piece = string(part)
        push!(texts, piece)
    end
    length(texts) < 2 && return nameof(mod)
    rest = texts[2:end]
    text = join(rest, ".")
    Symbol(text)
end

# A dotted path's last name, and the module names written before it.
function path_parts(path::Symbol)
    text = string(path)
    parts = split(text, ".")
    name = Symbol(parts[end])
    prefix = parts[1:end-1]
    (name, prefix)
end

# A bare path names the root module. A written prefix matches a module whose path below the root ends in it.
function module_path_ends(mod, root, prefix)
    isempty(prefix) && return mod === root
    names = fullname(mod)
    length(names) < 2 && return false
    below = names[2:end]
    length(below) < length(prefix) && return false
    start = length(below) - length(prefix) + 1
    for index in eachindex(prefix)
        piece = string(below[start + index - 1])
        piece == prefix[index] || return false
    end
    true
end

function owned_value(value::Union{Function,Type}, mod::Module)
    parentmodule(value) === mod || return nothing
    value
end

owned_value(::Any, ::Module) = nothing

function owned_callable(mod, name)
    isdefined(mod, name) || return nothing
    value = getfield(mod, name)
    owned_value(value, mod)
end

"""The function or type a path names inside the package: `name` in the root module, `Sub.name` in a module whose
path below the root ends in `Sub`. Nothing when no package module owns a callable at that path."""
function package_callable(ctx, path::Symbol)
    name, prefix = path_parts(path)
    for mod in package_modules(ctx)
        module_path_ends(mod, ctx.root, prefix) || continue
        found = owned_callable(mod, name)
        isnothing(found) || return found
    end
    nothing
end

# The modules defined directly inside a module.
function submodules(mod::Module)
    found = Module[]
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        value = getfield(mod, name)
        value isa Module || continue
        value !== mod && parentmodule(value) === mod && push!(found, value)
    end
    found
end

# The names a module exports. `names` lists the names it declares public as well.
function exported_names(mod::Module)
    listed = names(mod)
    filter(name -> Base.isexported(mod, name), listed)
end

# stale-export: Julia accepts `export foo` with no `foo`, so a deleted definition leaves the name exported
# forever and no load ever complains.
function check_stale_exports(mods; repo)
    findings = Finding[]
    for M in mods
        owner = module_key(M)
        path, line = module_site(M, repo)
        for n in exported_names(M)
            n === nameof(M) && continue
            isdefined(M, n) && continue
            found = Finding(owner, :stale_export, path, string(n), line, "exported name is never defined")
            push!(findings, found)
        end
    end
    findings
end

# A recorded repo-relative site, when its file lies inside the repository; nothing for another package's file or for
# code evaluated with no file.
function site_in_repository(site, repo)
    path, _ = site
    full = joinpath(repo, path)
    is_inside = is_within(full, repo) && isfile(full)
    is_inside ? site : nothing
end

# The first site in the repository holding a module's source: its `module` line, else a method it defines. Nothing
# when Julia records all of it in other files, as for a module another package's macro fills with its own code.
function source_site(child::Module, defined, repo)
    module_line = module_site(child, repo)
    found = site_in_repository(module_line, repo)
    isnothing(found) || return found
    for method in defined
        method.module === child || continue
        site = method_site(method, repo)
        found = site_in_repository(site, repo)
        isnothing(found) || return found
    end
    nothing
end

# unranked-module: a loaded submodule the index does not rank though the repository holds its source, so the index
# files that source under its parent and no rank rule reaches it.
function check_module_corpus(mods, rank, nested; repo)
    unranked = Pair{Module,Module}[]
    for mod in mods, child in submodules(mod)
        key = module_key(child)
        haskey(rank, key) || push!(unranked, mod => child)
    end
    findings = Finding[]
    for (mod, child) in unranked
        site = source_site(child, nested, repo)
        isnothing(site) && continue
        file, line = site
        owner = module_key(mod)
        name = string(nameof(child))
        detail = "a submodule holding package source that its wrapper does not declare as an include and a using"
        push!(findings, Finding(owner, :unranked_module, file, name, line, detail))
    end
    findings
end

function is_owned_binding(value::Function, mod)
    parentmodule(value) === mod
end

function is_owned_binding(@nospecialize(value::Type), mod)
    type_module(value) === mod
end

is_owned_binding(@nospecialize(::Any), ::Any) = false

# Names the module defines, skipping generated names and names it does not own.
function owned_defs(mod::Module)
    found = Symbol[]
    for name in names(mod; all = true)
        is_self = name === nameof(mod)
        is_builtin = name in (:eval, :include)
        is_generated = is_generated_name(name)
        (is_self || is_builtin || is_generated) && continue
        isdefined(mod, name) || continue
        value = getproperty(mod, name)
        is_owned_binding(value, mod) && push!(found, name)
    end
    found
end

# The module a (possibly parametric) type is defined in; resolves Type{X}, skips TypeVar/Union.
function type_module(@nospecialize(declared))
    held = type_object_held(declared)
    isnothing(held) || return type_module(held)
    body = declared_datatype(declared)
    isnothing(body) && return nothing
    parentmodule(body)
end

# A keyword method is a method of kwcall. Its third slot holds the function it wraps.
is_kwcall_signature(@nospecialize(sig)) = sig <: Tuple{typeof(Core.kwcall),Any,Any,Vararg}

# A method signature's function slot and its argument types. A keyword method is a method of Core.kwcall whose
# third slot holds the function it wraps: (kwcall, kwargs, f, args...).
function split_signature(@nospecialize(sig))
    params = signature_types(sig)
    slot = is_kwcall_signature(sig) ? 3 : 1
    (params[slot], params[slot + 1:end])
end

method_site(method::Method, repo) = (recorded_path(method.file, repo), Int(method.line))

# Each source site -> the names of the package's own functions that the loaded methods there add to.
function owned_functions_by_site(defined, modules, repo)
    project = Set{Module}(modules)
    by_site = Dict{Tuple{String,Int},Set{Symbol}}()
    for method in defined
        added_to = method_function(method)
        isnothing(added_to) && continue
        parentmodule(added_to) in project || continue
        site = method_site(method, repo)
        owned = get!(Set{Symbol}, by_site, site)
        push!(owned, nameof(added_to))
    end
    by_site
end

# A scan site names a method by its own name, or by a qualified name ending in it (`Base.show`).
function site_names_method(site::MethodSite, method::Method)
    site.name === method.name && return true
    text = string(site.name)
    suffix = "." * string(method.name)
    endswith(text, suffix)
end

"""The indexed file, scanner site and parsed definition form of a loaded method; nothing when the index holds no
form at its definition site (a method generated by a macro, or one defined outside the indexed files)."""
function method_form(index::SourceIndex, method::Method)
    path, line = method_site(method, index.repo)
    found = indexed_file(index, path, line)
    isnothing(found) && return nothing
    file = found::FileNode
    key = (path, line)
    held = get(index.forms, key, NO_PLACED_FORMS)
    for placed in held
        placed.file === file || continue
        site_names_method(placed.site, method) || continue
        return (file = file, site = placed.site, form = placed.form)
    end
    nothing
end

# Whether `outer` is `inner` or a module `inner` sits inside, by the loaded parent chain.
function encloses(outer::Module, inner::Module)
    current = inner
    while true
        current === outer && return true
        parent = parentmodule(current)
        parent === current && return false
        current = parent
    end
end

# The owners that bind `name` to an object another owner does not share. Without `strict` a module and one it
# encloses act as one owner, as a package lets its modules use what encloses them.
function colliding_owners(owners, name, strict)
    colliding = Module[]
    for left in owners, right in owners
        left === right && continue
        left_value = getproperty(left, name)
        right_value = getproperty(right, name)
        isequal(left_value, right_value) && continue
        is_nested = encloses(left, right) || encloses(right, left)
        is_nested && !strict && continue
        left in colliding || push!(colliding, left)
    end
    colliding
end

# duplicate-owner: a name exported by >=2 modules bound to DIFFERENT objects (same object = shared generic, ok).
function check_dup_owners(mods, rank; strict::Bool)
    by_name = Dict{Symbol,Vector{Module}}()
    for mod in mods
        for name in exported_names(mod)
            isdefined(mod, name) || continue
            owners = get!(by_name, name, Module[])
            push!(owners, mod)
        end
    end
    findings = Finding[]
    for (name, owners) in by_name
        colliding = colliding_owners(owners, name, strict)
        length(colliding) < 2 && continue
        keys = [module_key(mod) for mod in colliding]
        ranked = sort(keys, by = key -> rank[key])
        detail = "exported by more than one module, bound to different objects"
        evidence = [:owners => join(ranked, " ")]
        first_owner = first(ranked)
        symbol = string(name)
        finding = Finding(first_owner, :duplicate_owner, "", symbol, 0, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# A definition is sinkable when every project module it touches ranks below its own module.
# A definition its own module calls stays, and one that touches no project module says nothing about place.

function names_called_at_home(calls_by_def)
    called = Set{Symbol}()
    for (_, names) in calls_by_def
        for name in names
            push!(called, name)
        end
    end
    called
end

function methods_owned_by(mod, name, grouped)
    value = getproperty(mod, name)
    value isa Function || return Method[]
    defined = get(grouped, value, Method[])
    filter(method -> method.module === mod, defined)
end

function add_argument_owners!(owners, owned)
    for method in owned
        _, arguments = split_signature(method.sig)
        for argument in arguments
            home = type_module(argument)
            isnothing(home) || push!(owners, home)
        end
    end
    owners
end

owned_subject(value::Function) = value
owned_subject(@nospecialize(value::Type)) = value
owned_subject(@nospecialize(value)) = typeof(value)

# A union names no parent module. The module that owns the alias binding stands for it, and the caller's
# module stands for an alias imported from more than one module.
function value_owner(home::Module, name::Symbol, value)
    if is_union_type(value)
        owner = binding_owner(home, name)
        isnothing(owner) && return home
        return owner
    end
    subject = owned_subject(value)
    parentmodule(subject)
end

function add_call_owners!(owners, home, called_names)
    for called_name in called_names
        isdefined(home, called_name) || continue
        value = getproperty(home, called_name)
        value isa Module && continue
        owner = value_owner(home, called_name, value)
        push!(owners, owner)
    end
    owners
end

# The modules owning the argument types a definition's methods take and the names its body calls.
function touched_owners(home, owned, called_names)
    owners = Set{Module}()
    add_argument_owners!(owners, owned)
    add_call_owners!(owners, home, called_names)
    owners
end

# The project modules among the owners a definition touches, by key.
function footprint_of(owners, project_keys)
    footprint = Set{Symbol}()
    for owner in owners
        haskey(project_keys, owner) && push!(footprint, project_keys[owner])
    end
    footprint
end

# Whether the root can load the package a module belongs to: the language, the package itself, or a dependency.
function root_loads(mod::Module, root::Module, dependencies)
    package = Base.moduleroot(mod)
    package === Base.moduleroot(root) && return true
    uuid = package_uuid(package)
    isnothing(uuid) && return true
    uuid in dependencies
end

# Each module a body writes a path through, `Dep` in `Dep.f(x)`.
function written_modules(home, called_names)
    written = Module[]
    for called_name in called_names
        isdefined(home, called_name) || continue
        value = getproperty(home, called_name)
        value isa Module && push!(written, value)
    end
    written
end

# An extension also loads its trigger packages, which the project leaves out of its dependencies. A definition
# touching one stays in the extension.
function touches_trigger(home, owners, called_names, root, dependencies)
    Base.moduleroot(home) === Base.moduleroot(root) && return false
    for owner in owners
        root_loads(owner, root, dependencies) || return true
    end
    for written in written_modules(home, called_names)
        root_loads(written, root, dependencies) || return true
    end
    false
end

function ranks_below_home(footprint, key, own_rank, rank)
    key in footprint && return false
    for touched in footprint
        completes_before(rank[touched], own_rank) || return false
    end
    true
end

# One module in the footprint names the destination. A wider one names none:
# the definition may belong to a shared module that does not exist yet.
function sink_evidence(footprint, rank)
    ranked = sort(collect(footprint), by = touched -> rank[touched])
    joined = join(ranked, " ")
    evidence = Pair[:touches => joined]
    if length(footprint) == 1
        destination = string(only(footprint))
        push!(evidence, :sinks_to => destination)
    end
    evidence
end

function sink_finding(key, name, owned, footprint, rank, sites, repo)
    reflected = method_site(first(owned), repo)
    file, line = site_of(sites, key, name, reflected)
    evidence = sink_evidence(footprint, rank)
    detail = "every module it touches ranks below its own"
    symbol = string(name)
    Finding(key, :sinkable, file, symbol, line, detail, evidence)
end

function append_sink_findings!(findings, mod, key, own_rank, rank, calls_by_def, called_at_home, project_keys, sites,
                               grouped, repo, root, dependencies)
    for name in owned_defs(mod)
        name in called_at_home && continue
        owned = methods_owned_by(mod, name, grouped)
        isempty(owned) && continue
        called_names = get(calls_by_def, name, ())
        owners = touched_owners(mod, owned, called_names)
        footprint = footprint_of(owners, project_keys)
        isempty(footprint) && continue
        ranks_below_home(footprint, key, own_rank, rank) || continue
        touches_trigger(mod, owners, called_names, root, dependencies) && continue
        finding = sink_finding(key, name, owned, footprint, rank, sites, repo)
        push!(findings, finding)
    end
    findings
end

function check_sinkable(mods, rank, body_calls, sites, grouped, root; repo)
    project_keys = Dict(mod => module_key(mod) for mod in mods)
    dependencies = project_dependencies(repo)
    findings = Finding[]
    empty_calls = Dict{Symbol,Set{Symbol}}()
    for mod in mods
        key = project_keys[mod]
        haskey(rank, key) || continue
        own_rank = rank[key]
        calls_by_def = get(body_calls, key, empty_calls)
        called_at_home = names_called_at_home(calls_by_def)
        append_sink_findings!(findings, mod, key, own_rank, rank, calls_by_def, called_at_home, project_keys, sites,
                              grouped, repo, root, dependencies)
    end
    findings
end
