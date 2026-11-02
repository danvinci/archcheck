# Own-type methods: a module's own functions take only the types that module defines

"""Configured through `gate(...; checks)` with one or more of the package's modules. A method a listed module defines on a function it owns is a finding when it takes no argument, or an argument type the module does not own. An argument type is owned when it is a datatype the module itself defines, a union of such types, or a type variable bounded by one; no Base or Core type is admitted, so `Type{T}`, a container of owned types and a Vararg count as outside. The methods default arguments split at one source line are judged by the longest. Constructors, keyword bodies, closures and the methods another module adds stay unjudged"""
struct OwnTypeMethods{N} <: Check
    modules::NTuple{N,Module}   # modules whose own functions take only the types each defines
    function OwnTypeMethods(modules::Module...)
        isempty(modules) && throw(ArgumentError("OwnTypeMethods needs one or more modules"))
        allunique(modules) || throw(ArgumentError("OwnTypeMethods names a module twice: $modules"))
        new{length(modules)}(modules)
    end
end

kinds(::OwnTypeMethods) = (:foreign_argument => :advisory,)

is_owned_argument(@nospecialize(argument::TypeVar), home::Module) = is_owned_argument(argument.ub, home)

function is_owned_argument(@nospecialize(argument::Union), home::Module)
    members = union_members(argument)
    all(member -> is_owned_argument(member, home), members)
end

function is_owned_argument(@nospecialize(argument), home::Module)
    body = declared_datatype(argument)
    isnothing(body) && return false
    parentmodule(body) === home
end

# Each method `home` defines on a function it owns, the longest at each source line of each function
function own_function_methods(defined, home::Module, recorded::RecordedPaths)
    project = Set{Module}((home,))
    longest = Dict{Tuple{String,Int,Symbol},Method}()
    for method in defined
        method.module === home || continue
        owned = package_owned_function(method, project)
        isnothing(owned) && continue
        path, line = method_site(method, recorded)
        site = (path, line, method.name)
        held = get(longest, site, nothing)
        is_longer = isnothing(held) || method.nargs >= held.nargs
        is_longer && (longest[site] = method)
    end
    kept = collect(values(longest))
    sort!(kept, by = method_place)
end

function foreign_argument_finding(method::Method, outside::Vector{String}, recorded::RecordedPaths)
    file, line = method_site(method, recorded)
    owner = module_key(method.module)
    name = string(method.name)
    taken = join(outside, ", ")
    detail = isempty(outside) ? "takes no argument" : "takes a type its module does not own"
    evidence = [:takes => taken]
    Finding(owner, :foreign_argument, file, name, line, detail, evidence)
end

function check_own_type_methods(defined, home::Module, recorded::RecordedPaths)
    findings = Finding[]
    for method in own_function_methods(defined, home, recorded)
        _, arguments = split_signature(method.sig)
        outside = String[type_text(argument) for argument in arguments if !is_owned_argument(argument, home)]
        has_arguments = !isempty(arguments)
        has_arguments && isempty(outside) && continue
        finding = foreign_argument_finding(method, outside, recorded)
        push!(findings, finding)
    end
    findings
end

# One compiled run for every count of modules
function run(@nospecialize(check::OwnTypeMethods), ctx)
    modules = package_modules(ctx)
    findings = Finding[]
    for home in check.modules
        home in modules || throw(ArgumentError("OwnTypeMethods names $home, which is not one of the package's modules"))
        found = check_own_type_methods(ctx.defined, home, ctx.recorded)
        append!(findings, found)
    end
    findings
end
