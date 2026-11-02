# Taker allowlist: the definitions that may take a value of a closed type

"""Configured through `gate(...; checks)` with pairs of a type and the definitions allowed to take it, each a (repo-relative path, definition name) pair as `CallerAllowlist` names them. A method the package defines with an argument that can hold a value of the type is a finding when its definition is not listed, cited at its first such method. An argument holds the type when its declared type is the type, a subtype or an instance of it, a type variable bounded by one, a union with such a member, or a Vararg of one; a container of the type, a `Type{T}` and an untyped argument hold none. Constructors count as definitions named by their type, and a method on another module's function, `Base.show` included, by its own name. Keyword sorters, keyword bodies and closures stay unjudged, as their written method carries the same arguments"""
struct TakerAllowlist <: Check
    allowed::Vector{Pair{Type,Vector{Tuple{String,Symbol}}}}   # each closed type -> (repo-relative path, def name) pairs that may take it
    function TakerAllowlist(pairs::Pair...)
        isempty(pairs) && throw(ArgumentError("TakerAllowlist needs one or more type => allowed pairs"))
        listed = Pair{Type,Vector{Tuple{String,Symbol}}}[]
        for (closed, sites) in pairs
            closed isa Type || throw(ArgumentError("TakerAllowlist closes $closed, which is no type"))
            named = Tuple{String,Symbol}[(String(site[1]), Symbol(site[2])) for site in sites]
            push!(listed, closed => named)
        end
        new(listed)
    end
end

kinds(::TakerAllowlist) = (:unlisted_taker => :advisory,)

takes_type(@nospecialize(argument::TypeVar), @nospecialize(closed)) = takes_type(argument.ub, closed)

takes_type(@nospecialize(argument::Core.TypeofVararg), @nospecialize(closed)) = takes_type(argument.T, closed)

function takes_type(@nospecialize(argument::Union), @nospecialize(closed))
    members = union_members(argument)
    any(member -> takes_type(member, closed), members)
end

function takes_type(@nospecialize(argument), @nospecialize(closed))
    argument isa Type || return false
    argument === Union{} && return false
    argument <: closed
end

# A method the source writes with its own arguments; a keyword sorter or a lowered body repeats a written one
function is_written_method(method::Method)
    is_generated_name(method.name) && return false
    !is_kwcall_signature(method.sig)
end

function takes_any(arguments, @nospecialize(closed))
    for argument in arguments
        takes_type(argument, closed) && return true
    end
    false
end

function unlisted_taker_finding(method::Method, @nospecialize(closed), recorded::RecordedPaths)
    file, line = method_site(method, recorded)
    owner = module_key(method.module)
    name = string(method.name)
    taken = type_text(closed)
    evidence = [:takes => taken]
    detail = "takes $taken outside the definitions allowed to"
    Finding(owner, :unlisted_taker, file, name, line, detail, evidence)
end

# The first method of each unlisted definition that takes the closed type, in source order
function check_takers(defined, @nospecialize(closed), allowed::Vector{Tuple{String,Symbol}}, recorded::RecordedPaths)
    listed = Set(allowed)
    cited = Set{Tuple{String,Symbol}}()
    findings = Finding[]
    for method in defined
        is_written_method(method) || continue
        _, arguments = split_signature(method.sig)
        takes_any(arguments, closed) || continue
        path, _ = method_site(method, recorded)
        definition = (path, method.name)
        definition in listed && continue
        definition in cited && continue
        push!(cited, definition)
        finding = unlisted_taker_finding(method, closed, recorded)
        push!(findings, finding)
    end
    findings
end

function run(check::TakerAllowlist, ctx)
    findings = Finding[]
    for (closed, allowed) in check.allowed
        found = check_takers(ctx.defined, closed, allowed, ctx.recorded)
        append!(findings, found)
    end
    findings
end
