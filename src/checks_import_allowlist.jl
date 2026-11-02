# Import allowlist: the package modules a module's code may reach

"""Configured through `gate(...; checks)` with pairs of one of the package's modules and the package modules it may reach. A reference from code in the module, or in a module nested in it, to a package module that neither it nor a listed module encloses is a finding: a `using` or `import` clause, a qualified read, or a method on that module's function. A reference to a module outside the package, Base and Core included, stays unjudged, and so does every module the pairs leave out"""
struct ImportAllowlist <: Check
    allowed::Vector{Pair{Module,Vector{Module}}}   # each judged module -> the package modules its code may reach
    function ImportAllowlist(pairs::Pair...)
        isempty(pairs) && throw(ArgumentError("ImportAllowlist needs one or more module => allowed pairs"))
        listed = Pair{Module,Vector{Module}}[]
        for (home, reachable) in pairs
            modules = allowed_modules(reachable)
            push!(listed, home => modules)
        end
        homes = first.(listed)
        allunique(homes) || throw(ArgumentError("ImportAllowlist names a module twice: $homes"))
        new(listed)
    end
end

allowed_modules(reachable::Module) = Module[reachable]
allowed_modules(reachable) = collect(Module, reachable)

kinds(::ImportAllowlist) = (:unlisted_import => :advisory,)

# A listed module must be one the module graph ranks
function require_ranked(index::SourceIndex, mod::Module)
    key = module_key(mod)
    haskey(index.rank, key) && return key
    throw(ArgumentError("ImportAllowlist names $mod, which the module graph does not rank"))
end

# Whether one of `outers` encloses the module keyed `inner`
function any_encloses(loaded, outers::Vector{Symbol}, inner::Symbol)
    for outer in outers
        key_encloses(loaded, outer, inner) && return true
    end
    false
end

function unlisted_import_finding(ref::ModRef, home::Symbol)
    module_text = string(home)
    via = string(ref.via)
    evidence = [:module => module_text, :via => via]
    reached = string(ref.to)
    detail = "reaches a package module outside the list $module_text may reach"
    Finding(ref.from, :unlisted_import, ref.file, reached, ref.line, detail, evidence)
end

function run(check::ImportAllowlist, ctx)
    loaded = ranked_modules(ctx.index, ctx.root)
    findings = Finding[]
    for (home, reachable) in check.allowed
        home_key = require_ranked(ctx.index, home)
        reachable_keys = Symbol[require_ranked(ctx.index, mod) for mod in reachable]
        push!(reachable_keys, home_key)
        for ref in ctx.index.refs
            key_encloses(loaded, home_key, ref.from) || continue
            any_encloses(loaded, reachable_keys, ref.to) && continue
            finding = unlisted_import_finding(ref, home_key)
            push!(findings, finding)
        end
    end
    findings
end
