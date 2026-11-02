# Holder allowlist: the struct types whose fields may hold a listed type

"""Configured through `gate(...; checks)` with pairs of a type and the struct types allowed to hold it. A field of a concrete struct the package defines is a finding when its stored type holds the type and the struct is not listed. A stored type holds it when it is the type, a subtype or an instance of it, a type variable bounded by one, a union with such a member, a Vararg of one, or a datatype with such a parameter at any depth, so `Vector{T}` and `Dict{Symbol,Vector{T}}` hold `T`. A listed holder stands for every instance of its struct, and a struct is judged once, under its own name. A listed holder with no field holding the type is a stale allowance"""
struct HolderAllowlist <: Check
    allowed::Vector{Pair{Type,Vector{Core.TypeName}}}   # each held type -> the structs whose fields may hold it
    function HolderAllowlist(pairs::Pair...)
        isempty(pairs) && throw(ArgumentError("HolderAllowlist needs one or more type => allowed holder pairs"))
        listed = Pair{Type,Vector{Core.TypeName}}[]
        for (held, holders) in pairs
            held isa Type || throw(ArgumentError("HolderAllowlist holds $held, which is no type"))
            names = Core.TypeName[holder_name(holder) for holder in holders]
            push!(listed, held => names)
        end
        new(listed)
    end
end

function holder_name(@nospecialize(holder))
    body = declared_datatype(holder)
    isnothing(body) && throw(ArgumentError("HolderAllowlist allows $holder, which names no struct"))
    body.name
end

kinds(::HolderAllowlist) = (:unlisted_holder => :advisory, :stale_allowance => :error)

holds_type(@nospecialize(stored::TypeVar), @nospecialize(held)) = holds_type(stored.ub, held)

holds_type(@nospecialize(stored::Core.TypeofVararg), @nospecialize(held)) = holds_type(stored.T, held)

function holds_type(@nospecialize(stored::Union), @nospecialize(held))
    members = union_members(stored)
    any(member -> holds_type(member, held), members)
end

function holds_type(@nospecialize(stored), @nospecialize(held))
    stored === Union{} && return false
    body = declared_datatype(stored)
    isnothing(body) && return false
    body <: held && return true
    any(parameter -> holds_type(parameter, held), body.parameters)
end

# Each concrete struct a module defines under its own name
function own_structs(mod::Module)
    found = Pair{Symbol,DataType}[]
    for (name, body) in struct_bindings(mod)
        isabstracttype(body) && continue
        is_own_struct_name(mod, name, body) && push!(found, name => body)
    end
    found
end

function unlisted_holder_finding(owner::Symbol, name::Symbol, field::Symbol, @nospecialize(stored), @nospecialize(held),
                                 sites)
    file, line = site_of(sites, owner, name, ("", 0))
    symbol = string(name, ".", field)
    held_text = type_text(held)
    stored_text = type_text(stored)
    evidence = [:holds => held_text, :declared => stored_text]
    detail = "the field holds $held_text outside the structs allowed to"
    Finding(owner, :unlisted_holder, file, symbol, line, detail, evidence)
end

# An allowed holder cited at its struct's definition; a struct outside the package has no site there
function stale_holder_finding(holder::Core.TypeName, @nospecialize(held), sites)
    owner = module_key(holder.module)
    file, line = site_of(sites, owner, holder.name, ("", 0))
    symbol = string(holder.name)
    held_text = type_text(held)
    evidence = [:holds => held_text]
    detail = "$symbol is allowed to hold $held_text and no field of it does"
    Finding(owner, :stale_allowance, file, symbol, line, detail, evidence)
end

function check_holders(mods, @nospecialize(held), allowed::Vector{Core.TypeName}, sites)
    holding = Set{Core.TypeName}()
    findings = Finding[]
    for mod in mods
        owner = module_key(mod)
        for (name, body) in own_structs(mod)
            is_allowed = body.name in allowed
            # By position: a zip over `fieldnames` and `fieldtypes` compiles once per struct shape
            for position in 1:fieldcount(body)
                stored = fieldtype(body, position)
                holds_type(stored, held) || continue
                push!(holding, body.name)
                is_allowed && continue
                field = fieldname(body, position)
                finding = unlisted_holder_finding(owner, name, field, stored, held, sites)
                push!(findings, finding)
            end
        end
    end
    for holder in allowed
        holder in holding && continue
        stale = stale_holder_finding(holder, held, sites)
        push!(findings, stale)
    end
    findings
end

function run(check::HolderAllowlist, ctx)
    modules = package_modules(ctx)
    findings = Finding[]
    for (held, allowed) in check.allowed
        found = check_holders(modules, held, allowed, ctx.sites)
        append!(findings, found)
    end
    findings
end
