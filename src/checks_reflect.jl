# Reflection checks (duplicate-owner, sinkable): the method table is dispatch-aware, so these
# read the loaded modules, not source text.

# Names M defines itself (function/type whose parentmodule is M), skipping imports and internals.
function owned_defs(M::Module)
    out = Symbol[]
    for n in names(M; all = true)
        (n === nameof(M) || n in (:eval, :include) || startswith(string(n), "#")) && continue
        isdefined(M, n) || continue
        v = getproperty(M, n)
        (v isa Function || v isa Type) && parentmodule(v) === M && push!(out, n)
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

# duplicate-owner: a name exported by >=2 modules bound to DIFFERENT objects (same object = shared generic, ok).
function check_dup_owners(mods, rank)
    byname = Dict{Symbol,Vector{Module}}()
    for M in mods, n in names(M; all = false)
        isdefined(M, n) && push!(get!(byname, n, Module[]), M)
    end
    findings = Finding[]
    for (n, ms) in byname
        (length(ms) < 2 || length(unique(getproperty(M, n) for M in ms)) < 2) && continue
        owners = sort([nameof(M) for M in ms], by = m -> get(rank, m, 0))
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
    proj = Dict(M => nameof(M) for M in mods)
    findings = Finding[]
    for M in mods
        rM = get(rank, nameof(M), 0); rM == 0 && continue
        dc = get(body_calls, nameof(M), Dict{Symbol,Set{Symbol}}())
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
            (nameof(M) in foot || !all(fm -> rank[fm] < rM, foot)) && continue
            site = first(owned)
            declared = string(site.file)
            reflected = (relpath(declared, repo), site.line)   # same form as an indexed site, not a basename
            file, line = site_of(sites, nameof(M), n, reflected)
            ranked = sort(collect(foot), by = x -> rank[x])
            evidence = [:touches => join(ranked, " ")]
            # One module in the footprint names the destination; a wider one does not, since the def may
            # belong to a shared module that does not exist yet.
            if length(foot) == 1
                destination = string(only(foot))
                push!(evidence, :sinks_to => destination)
            end
            push!(findings, Finding(nameof(M), :sinkable, file, string(n), line,
                  "every module it touches ranks below its own", evidence))
        end
    end
    findings
end
