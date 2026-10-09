# Reflection checks (duplicate-owner, sinkable): the method table is dispatch-aware, so these
# read the loaded modules, not source text.

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

# unranked-module: a loaded submodule no wrapper declares by the spine rule, so the index files it under its
# parent and no rank rule reaches it.
function check_module_corpus(mods, rank; repo)
    findings = Finding[]
    for mod in mods
        owner = module_key(mod)
        for child in submodules(mod)
            haskey(rank, module_key(child)) && continue
            name = string(nameof(child))
            file, line = module_site(child, repo)
            detail = "a submodule its wrapper does not declare as an include followed by a using"
            push!(findings, Finding(owner, :unranked_module, file, name, line, detail))
        end
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
        is_generated = startswith(string(name), "#")
        (is_self || is_builtin || is_generated) && continue
        isdefined(mod, name) || continue
        value = getproperty(mod, name)
        is_owned_binding(value, mod) && push!(found, name)
    end
    found
end

# The module a (possibly parametric) type is defined in; resolves Type{X}, skips TypeVar/Union.
function type_module(@nospecialize(declared))
    declared isa TypeVar && return nothing
    unwrapped = Base.unwrap_unionall(declared)
    unwrapped isa DataType || return nothing
    if Base.isType(unwrapped)
        held = only(unwrapped.parameters)
        return type_module(held)
    end
    parentmodule(unwrapped)
end

# Project modules a method signature's argument types touch.
function sig_modules!(found, @nospecialize(sig), project_keys)
    _, arguments = split_signature(sig)
    for argument in arguments
        home = type_module(argument)
        haskey(project_keys, home) && push!(found, project_keys[home])
    end
    found
end

# A keyword-argument body is its own generic named #f#N; the written name is the first segment.
function written_name(name::Symbol)
    text = string(name)
    startswith(text, "#") || return text
    parts = split(text, "#"; keepempty = false)
    isempty(parts) ? text : String(first(parts))
end

# A keyword method is a method of kwcall. Its third slot holds the function it wraps.
is_kwcall_signature(@nospecialize(sig)) = sig <: Tuple{typeof(Core.kwcall),Any,Any,Vararg}

# A method signature's function slot and its argument types. A keyword method is a method of Core.kwcall whose
# third slot holds the function it wraps: (kwcall, kwargs, f, args...).
function split_signature(@nospecialize(sig))
    params = Base.unwrap_unionall(sig).parameters
    slot = is_kwcall_signature(sig) ? 3 : 1
    (params[slot], params[slot + 1:end])
end

# A path loaded code recorded, repo-relative like an indexed site. A system image records a stdlib's files at the
# build machine's path; the fixup maps them to this installation.
function recorded_path(file, repo)
    local_path = Base.fixup_stdlib_path(string(file))
    relpath(local_path, repo)
end

method_site(method::Method, repo) = (recorded_path(method.file, repo), Int(method.line))

# Where a module's `module` line sits.
function module_site(mod::Module, repo)
    location = Base.moduleloc(mod)
    (recorded_path(location.file, repo), location.line)
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
    for (site, form) in file.scan.forms
        site.line == line || continue
        site_names_method(site, method) || continue
        return (file = file, site = site, form = form)
    end
    nothing
end

# duplicate-owner: a name exported by >=2 modules bound to DIFFERENT objects (same object = shared generic, ok).
function check_dup_owners(mods, rank)
    by_name = Dict{Symbol,Vector{Module}}()
    for mod in mods
        for name in names(mod; all = false)
            isdefined(mod, name) || continue
            owners = get!(by_name, name, Module[])
            push!(owners, mod)
        end
    end
    findings = Finding[]
    for (name, owners) in by_name
        length(owners) < 2 && continue
        bound = [getproperty(mod, name) for mod in owners]
        length(unique(bound)) < 2 && continue
        keys = [module_key(mod) for mod in owners]
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

function methods_owned_by(mod, name)
    value = getproperty(mod, name)
    value isa Function || return Method[]
    owned = Method[]
    for method in methods(value)
        method.module === mod || continue
        push!(owned, method)
    end
    owned
end

function add_signature_modules!(footprint, owned, project_keys)
    for method in owned
        sig_modules!(footprint, method.sig, project_keys)
    end
    footprint
end

owned_subject(value::Function) = value
owned_subject(@nospecialize(value::Type)) = value
owned_subject(@nospecialize(value)) = typeof(value)

# A Union has no parent module. The module that owns the alias binding stands for it.
function binding_owner(home, name, value)
    unwrapped = Base.unwrap_unionall(value)
    if unwrapped isa Union
        return Base.binding_module(home, name)
    end
    subject = owned_subject(value)
    parentmodule(subject)
end

function add_call_modules!(footprint, home, called_names, project_keys)
    for called_name in called_names
        isdefined(home, called_name) || continue
        value = getproperty(home, called_name)
        value isa Module && continue
        owner = binding_owner(home, called_name, value)
        haskey(project_keys, owner) || continue
        push!(footprint, project_keys[owner])
    end
    footprint
end

function footprint_of(home, owned, called_names, project_keys)
    footprint = Set{Symbol}()
    add_signature_modules!(footprint, owned, project_keys)
    add_call_modules!(footprint, home, called_names, project_keys)
    footprint
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

function append_sink_findings!(findings, mod, key, own_rank, rank, calls_by_def, called_at_home, project_keys, sites, repo)
    for name in owned_defs(mod)
        name in called_at_home && continue
        owned = methods_owned_by(mod, name)
        isempty(owned) && continue
        called_names = get(calls_by_def, name, ())
        footprint = footprint_of(mod, owned, called_names, project_keys)
        isempty(footprint) && continue
        ranks_below_home(footprint, key, own_rank, rank) || continue
        finding = sink_finding(key, name, owned, footprint, rank, sites, repo)
        push!(findings, finding)
    end
    findings
end

function check_sinkable(mods, rank, body_calls, sites; repo)
    project_keys = Dict(mod => module_key(mod) for mod in mods)
    findings = Finding[]
    empty_calls = Dict{Symbol,Set{Symbol}}()
    for mod in mods
        key = project_keys[mod]
        haskey(rank, key) || continue
        own_rank = rank[key]
        calls_by_def = get(body_calls, key, empty_calls)
        called_at_home = names_called_at_home(calls_by_def)
        append_sink_findings!(findings, mod, key, own_rank, rank, calls_by_def, called_at_home, project_keys, sites, repo)
    end
    findings
end
