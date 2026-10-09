# Reflection checks (duplicate-owner, sinkable): the method table is dispatch-aware, so these
# read the loaded modules, not source text.

# A loaded module's key, as the source index names it: its path below the package root, `Geometry.Meshes`.
# The root has no path below it, so it is keyed by its own name.
function module_key(M::Module)
    below = fullname(M)[2:end]
    isempty(below) && return nameof(M)
    Symbol(join(below, "."))
end

# The module's wrapper path by layout convention, for a finding with no single source line:
# `Geometry.Meshes` -> src/geometry/meshes/Meshes.jl.
function module_file(M::Module)
    key = string(module_key(M))
    segments = split(key, '.')
    dirs = lowercase(join(segments, "/"))
    "src/" * dirs * "/" * last(segments) * ".jl"
end

# The modules defined directly inside M.
function submodules(M::Module)
    found = Module[]
    for name in names(M; all = true)
        isdefined(M, name) || continue
        value = getfield(M, name)
        value isa Module || continue
        value !== M && parentmodule(value) === M && push!(found, value)
    end
    found
end

# unranked-module: a loaded submodule no wrapper declares by the spine rule, so the index files it under its
# parent and no rank rule reaches it.
function check_module_corpus(mods, rank)
    findings = Finding[]
    for M in mods, child in submodules(M)
        haskey(rank, module_key(child)) && continue
        name = string(nameof(child))
        detail = "a submodule its wrapper does not declare as an include followed by a using"
        push!(findings, Finding(module_key(M), :unranked_module, module_file(M), name, 0, detail))
    end
    findings
end

# Names M defines itself (function/type owned by M), skipping non-owned names and internals.
function owned_defs(mod::Module)
    out = Symbol[]
    for name in names(mod; all = true)
        is_module = name === nameof(mod)
        is_builtin = name in (:eval, :include)
        is_internal = startswith(string(name), "#")
        (is_module || is_builtin || is_internal) && continue
        isdefined(mod, name) || continue
        value = getproperty(mod, name)
        if value isa Function
            parentmodule(value) === mod && push!(out, name)
        elseif value isa Type
            type_module(value) === mod && push!(out, name)
        end
    end
    out
end

# The module a (possibly parametric) type is defined in; resolves Type{X}, skips TypeVar/Union.
function type_module(@nospecialize(T))
    T isa TypeVar && return nothing
    T = Base.unwrap_unionall(T)
    T isa DataType || return nothing
    if Base.isType(T)
        held = only(T.parameters)
        return type_module(held)
    end
    parentmodule(T)
end

# Project modules a method signature's argument types touch.
function sig_modules!(out, @nospecialize(sig), proj)
    _, arguments = split_signature(sig)
    for T in arguments
        pm = type_module(T)
        haskey(proj, pm) && push!(out, proj[pm])
    end
    out
end

# A Core.Box reference anywhere under a lowered statement.
function has_box(@nospecialize(stmt))
    stmt isa GlobalRef && return stmt.mod === Core && stmt.name === :Box
    stmt isa Expr && return any(has_box, stmt.args)
    false
end

# Core.Box allocations in a method's lowered IR - lowering emits one per boxed capture.
function count_boxes(m::Method)
    lowered = try
        Base.uncompressed_ast(m)
    catch
        return 0
    end
    lowered isa Core.CodeInfo || return 0
    count(has_box, lowered.code)
end

# A keyword-argument body is its own generic named #f#N; the written name is the first segment.
function written_name(n::Symbol)
    text = string(n)
    startswith(text, "#") || return text
    parts = split(text, "#"; keepempty = false)
    isempty(parts) ? text : String(first(parts))
end

# boxed-capture: a local a closure captures and something assigns in more than one place. Lowering boxes
# it, which erases its type and the type of every value read from it.
function check_boxed_captures(mods; repo)
    findings = Finding[]
    seen = Set{Tuple{String,Int}}()
    for M in mods, n in names(M; all = true)
        (n === nameof(M) || n in (:eval, :include)) && continue
        isdefined(M, n) || continue
        value = getproperty(M, n)
        value isa Function || continue
        for m in methods(value)
            m.module === M || continue
            boxes = count_boxes(m)
            boxes == 0 && continue
            key = method_site(m, repo)
            key in seen && continue
            push!(seen, key)
            file, line = key
            push!(findings, Finding(module_key(M), :boxed_capture, file, written_name(n), line,
                  "a captured local is assigned in more than one place, so lowering boxes it",
                  [:boxes => string(boxes)]))
        end
    end
    findings
end

# Every method a checked module defines, on any function, in source order.
function project_methods(mods)
    project = Set(mods)
    defined = Method[]
    Base.visit(Core.methodtable) do method
        method.module in project && push!(defined, method)
    end
    sort!(defined, by = method -> (string(method.file), method.line))
end

# module-piracy: a method a module defines on a function it does not own, where neither it nor a module nested
# in it owns any argument type. The orphan rule at module grain, so Base, stdlib and dependency functions fall
# under it too: `Base.show(io, ::T)` belongs in the module that owns T.
function check_module_piracy(mods; repo)
    findings = Finding[]
    for method in project_methods(mods)
        # Aqua's `is_pirate` (Aqua.jl src/piracies.jl) at module grain: the function is foreign to the defining
        # module, and every argument type is foreign to its subtree, the modules whose full name starts with its own.
        home = method.module
        home_name = fullname(home)
        depth = length(home_name)
        owns_argument = mod -> fullname(mod)[1:min(end, depth)] == home_name
        function_type, arguments = split_signature(method.sig)
        # A Union in the function slot is foreign only when every member is.
        members = Base.uniontypes(function_type)
        all(T -> is_foreign(T, ==(home)), members) || continue
        all(T -> is_foreign(T, owns_argument), arguments) || continue
        file, line = method_site(method, repo)
        owner = type_module(function_type)
        owner_path = isnothing(owner) ? string(function_type) : join(fullname(owner), ".")
        signature = string(method.sig)
        evidence = [:owner => owner_path, :signature => signature]
        key = module_key(home)
        name = string(method.name)
        detail = "extends a function another module owns on no type its own subtree owns"
        push!(findings, Finding(key, :module_piracy, file, name, line, detail, evidence))
    end
    findings
end

# A method signature's function slot and its argument types. A keyword method is a method of Core.kwcall whose
# third slot holds the function it wraps: (kwcall, kwargs, f, args...).
function split_signature(@nospecialize(sig))
    params = Base.unwrap_unionall(sig).parameters
    is_kwcall = sig <: Tuple{typeof(Core.kwcall),Any,Any,Vararg}
    slot = is_kwcall ? 3 : 1
    (params[slot], params[slot+1:end])
end

# Aqua's foreign-type walk (Aqua.jl src/piracies.jl), where `owns(module)` decides ownership. A value parameter
# (the 1 in Array{T,1}) stands for its type; a Symbol parameter belongs to nobody, so it counts as owned.
is_foreign(@nospecialize(x), owns) = is_foreign(typeof(x), owns)
is_foreign(::Symbol, owns) = false
is_foreign(@nospecialize(T::TypeVar), owns) = is_foreign(T.ub, owns)
is_foreign(@nospecialize(T::Core.TypeofVararg), owns) = is_foreign(T.T, owns)
# Set{T} over an owned T is owned: both the body and the bound must be foreign.
is_foreign(@nospecialize(U::UnionAll), owns) = is_foreign(U.body, owns) && is_foreign(U.var, owns)
# One foreign member makes a Union foreign: Union{Owned,Int} claims Int as well.
function is_foreign(@nospecialize(U::Union), owns)
    members = Base.uniontypes(U)
    any(T -> is_foreign(T, owns), members)
end

# Type{T} belongs where T does; any other type is foreign when its module and all its parameters are.
function is_foreign(@nospecialize(T::DataType), owns)
    if Base.isType(T)
        held = only(T.parameters)
        return is_foreign(held, owns)
    end
    owns(parentmodule(T)) && return false
    all(param -> is_foreign(param, owns), T.parameters)
end

# A method's definition site, repo-relative like an indexed site.
method_site(method::Method, repo) = (relpath(string(method.file), repo), Int(method.line))

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
    found = indexed_file(index, path)
    isnothing(found) && return nothing
    file = found::FileNode
    for (site, form) in file.scan.forms
        site.line == line || continue
        site_names_method(site, method) || continue
        return (file = file, site = site, form = form)
    end
    nothing
end

# TypeVars bound by a UnionAll struct (Foo{T} -> T). A field type's own parameters (Vector's eltype) are separate.
function struct_typevars(@nospecialize(T))
    vars = TypeVar[]
    while T isa UnionAll
        push!(vars, T.var)
        T = T.body
    end
    vars
end

function uses_struct_params(@nospecialize(F), vars)
    F isa TypeVar && return F in vars
    F isa Union && return uses_struct_params(F.a, vars) || uses_struct_params(F.b, vars)
    F isa UnionAll && return uses_struct_params(F.body, vars)
    if F isa Core.TypeofVararg
        element_uses = uses_struct_params(F.T, vars)
        element_uses && return true
        isdefined(F, :N) || return false
        return uses_struct_params(F.N, vars)
    end
    F isa DataType && return any(p -> uses_struct_params(p, vars), F.parameters)
    false
end

# Type{Float64} holds that one type object; Type{<:T} holds any subtype, so dispatch stays open.
function is_closed_type_object(@nospecialize(T))
    U = Base.unwrap_unionall(T)
    Base.isType(U) || return false
    p = only(U.parameters)
    p isa Type && isconcretetype(p)
end

# A vararg with no length parameter, or whose element stays open, stays open.
function vararg_is_open(@nospecialize(position), vars)
    held = position.T
    is_open_position(held, vars) && return true
    isdefined(position, :N) || return true
    length_param = position.N
    length_param isa Int && return false
    length_param isa TypeVar || return true
    !(length_param in vars)
end

# Type{T} and NTuple{N,T} name one type on each instance when T and N are this struct's parameters.
# A free variable, an abstract parameter, or a family over some other variable stays open.
function is_open_position(@nospecialize(position), vars)
    position isa Core.TypeofVararg && return vararg_is_open(position, vars)
    position isa UnionAll && return true
    position isa Union && return false
    position isa TypeVar && return !(position in vars)
    position isa DataType || return false
    if Base.isType(position)
        held = only(position.parameters)
        return is_open_position(held, vars)
    end
    for param in position.parameters
        is_open_position(param, vars) && return true
    end
    isabstracttype(position)
end

# Open when the stored type, the container wrapper, or a Dict/Set payload is not concrete; a struct's own parameter
# is fixed per instance. A Union stays: lowering splits a small one. Dict eltype is Pair, so its parts are read apart.
function is_open_field(@nospecialize(declared), vars = TypeVar[])
    declared isa TypeVar && return !(declared in vars)
    declared isa Union && return false
    is_closed_type_object(declared) && return false
    if uses_struct_params(declared, vars)
        return is_open_position(declared, vars)
    end
    if declared <: AbstractDict || declared <: AbstractArray || declared <: AbstractSet
        U = Base.unwrap_unionall(declared)
        isconcretetype(U) || return true
        if U <: AbstractDict && length(U.parameters) >= 2
            return is_open_field(U.parameters[1]) || is_open_field(U.parameters[2])
        end
        return is_open_field(eltype(declared))
    end
    !isconcretetype(Base.unwrap_unionall(declared))
end

# abstract-field: a field whose type leaves dispatch open. A field naming a type parameter closes on use only where
# nothing around the parameter stays abstract; Vector / Real / an unparametrized UnionAll are open on every instance.
function check_abstract_fields(mods, sites)
    findings = Finding[]
    for M in mods, n in names(M; all = true)
        (n === nameof(M) || startswith(string(n), "#")) && continue
        isdefined(M, n) || continue
        T = getproperty(M, n)
        T isa Type || continue
        vars = struct_typevars(T)
        S = Base.unwrap_unionall(T)
        S isa DataType || continue
        (isstructtype(S) && parentmodule(S) === M) || continue
        for (field, declared) in zip(fieldnames(S), fieldtypes(S))
            is_open_field(declared, vars) || continue
            owner = module_key(M)
            file, line = site_of(sites, owner, n, ("", 0))
            push!(findings, Finding(owner, :abstract_field, file, "$n.$field", line,
                  "the field's type leaves dispatch open",
                  [:declared => string(declared)]))
        end
    end
    findings
end

# duplicate-owner: a name exported by >=2 modules bound to DIFFERENT objects (same object = shared generic, ok).
function check_dup_owners(mods, rank)
    byname = Dict{Symbol,Vector{Module}}()
    for M in mods, n in names(M; all = false)
        isdefined(M, n) && push!(get!(byname, n, Module[]), M)
    end
    findings = Finding[]
    for (n, ms) in byname
        (length(ms) < 2 || length(unique(getproperty(M, n) for M in ms)) < 2) && continue
        owners = sort([module_key(M) for M in ms], by = m -> rank[m])
        push!(findings, Finding(first(owners), :duplicate_owner, "", string(n), 0,
                                "exported by more than one module, bound to different objects",
                                [:owners => join(owners, " ")]))
    end
    findings
end

# sinkable: every project module a def touches - through its signature types and its body calls - ranks
# below the def's own. Signature types come from reflection; body calls come from the static scan.
# Callers place a def: one its own module calls belongs there, and one touching no project module at
# all says nothing about where it belongs.
function check_sinkable(mods, rank, body_calls, sites; repo)
    proj = Dict(M => module_key(M) for M in mods)
    findings = Finding[]
    for M in mods
        key = module_key(M)
        haskey(rank, key) || continue
        own_rank = rank[key]
        dc = get(body_calls, key, Dict{Symbol,Set{Symbol}}())
        called_at_home = Set{Symbol}()
        for (_, names) in dc, name in names
            push!(called_at_home, name)
        end
        for n in owned_defs(M)
            n in called_at_home && continue
            v = getproperty(M, n)
            v isa Function || continue
            owned = [m for m in methods(v) if m.module === M]
            isempty(owned) && continue
            foot = Set{Symbol}()
            for m in owned; sig_modules!(foot, m.sig, proj); end
            for cn in get(dc, n, ())
                isdefined(M, cn) || continue
                o = getproperty(M, cn); o isa Module && continue
                if Base.unwrap_unionall(o) isa Union
                    # A Union has no parentmodule; the module owning the alias binding stands for it.
                    owner = Base.binding_module(M, cn)
                else
                    owner = parentmodule(o isa Function || o isa Type ? o : typeof(o))
                end
                haskey(proj, owner) && push!(foot, proj[owner])
            end
            isempty(foot) && continue
            (key in foot || !all(fm -> completes_before(rank[fm], own_rank), foot)) && continue
            reflected = method_site(first(owned), repo)
            file, line = site_of(sites, key, n, reflected)
            ranked = sort(collect(foot), by = x -> rank[x])
            evidence = [:touches => join(ranked, " ")]
            # One module in the footprint names the destination; a wider one does not, since the def may
            # belong to a shared module that does not exist yet.
            if length(foot) == 1
                destination = string(only(foot))
                push!(evidence, :sinks_to => destination)
            end
            push!(findings, Finding(key, :sinkable, file, string(n), line,
                  "every module it touches ranks below its own", evidence))
        end
    end
    findings
end
