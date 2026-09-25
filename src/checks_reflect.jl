# Reflection checks (duplicate-owner, sinkable): the method table is dispatch-aware, so these
# read the loaded modules, not source text.

# A loaded module's key, as the source index names it: its path below the package root, `Geometry.Meshes`.
module_key(M::Module) = Symbol(join(fullname(M)[2:end], "."))

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
    (T <: Type && length(T.parameters) == 1) && return type_module(T.parameters[1])
    parentmodule(T)
end

# Project modules a method signature's argument types touch.
function sig_modules!(out, @nospecialize(sig), proj)
    tt = Base.unwrap_unionall(sig)
    (tt isa DataType && tt <: Tuple) || return out
    for T in tt.parameters[2:end]
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
            file = relpath(string(m.file), repo)
            key = (file, Int(m.line))
            key in seen && continue
            push!(seen, key)
            push!(findings, Finding(module_key(M), :boxed_capture, file, written_name(n), Int(m.line),
                  "a captured local is assigned in more than one place, so lowering boxes it",
                  [:boxes => string(boxes)]))
        end
    end
    findings
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
    F isa DataType && return any(p -> uses_struct_params(p, vars), F.parameters)
    false
end

# Type{Float64} holds that one type object; Type{<:T} holds any subtype, so dispatch stays open.
function is_closed_type_object(@nospecialize(T))
    U = Base.unwrap_unionall(T)
    U isa DataType || return false
    U <: Type || return false
    length(U.parameters) == 1 || return false
    p = U.parameters[1]
    p isa Type && isconcretetype(p)
end

# Open when the stored type, the container wrapper, or a Dict/Set payload is not concrete.
# A Union stays: lowering splits a small one into branches. Dict eltype is Pair, so Dict{Int,Any} would look closed.
function is_open_field(@nospecialize(declared))
    declared isa TypeVar && return true
    declared isa Union && return false
    is_closed_type_object(declared) && return false
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

# abstract-field: a field whose type leaves dispatch open. A field naming a type parameter closes on use.
# Vector / Real / an unparametrized UnionAll spec is open on every instantiation.
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
            uses_struct_params(declared, vars) && continue
            is_open_field(declared) || continue
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
                owner = parentmodule(o isa Function || o isa Type ? o : typeof(o))
                haskey(proj, owner) && push!(foot, proj[owner])
            end
            isempty(foot) && continue
            (key in foot || !all(fm -> completes_before(rank[fm], own_rank), foot)) && continue
            site = first(owned)
            declared = string(site.file)
            reflected = (relpath(declared, repo), site.line)   # same form as an indexed site, not a basename
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
