# Interface checks: does a module declare what it publishes, and does anything reach past that declaration.
# A module that exports its whole namespace has no interface to hold, so nothing behind it can move.

const BLANKET_EXPORT = "names(@__MODULE__; all=true)"

# The module's own wrapper path, for a finding that has no single source line.
function module_file(M)
    name = string(nameof(M))
    "src/" * lowercase(name) * "/" * name * ".jl"
end

# blanket-export: the wrapper re-exports every name the module defines, internals included.
function check_blanket_exports(index::SourceIndex)
    findings = Finding[]
    for f in index.files
        is_wrapper(f) || continue
        isfile(f.path) || continue
        for (i, line) in enumerate(eachline(f.path))
            occursin(BLANKET_EXPORT, line) || continue
            detail = "module exports its whole namespace, so it declares no interface"
            found = Finding(f.mod, :blanket_export, f.path, "", i, detail)
            push!(findings, found)
            break
        end
    end
    findings
end

# stale-export: Julia accepts `export foo` with no `foo`, so a deleted definition leaves the name in
# names(M) forever and no load ever complains.
function check_stale_exports(mods)
    findings = Finding[]
    for M in mods
        owner = nameof(M)
        path = module_file(M)
        for n in names(M)
            n === owner && continue
            isdefined(M, n) && continue
            found = Finding(owner, :stale_export, path, string(n), "exported name is never defined")
            push!(findings, found)
        end
    end
    findings
end

# reaches-internal: a qualified reference to a name its owning module does not export. Lexical by nature -
# the question is whether the source names a binding the owner kept private, not how it is dispatched.
# The owning module is the LAST qualifier before the member: A.B.name belongs to B, not A.
const QUALIFIED_REF = r"\b(?:[A-Z][A-Za-z0-9_]*\.)*([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_!]*)"

function scanned_paths(index::SourceIndex, entry_dirs)
    paths = String[f.path for f in index.files]
    for d in entry_dirs, (root, _, files) in walkdir(d), f in files
        endswith(f, ".jl") || continue
        push!(paths, joinpath(root, f))
    end
    paths
end

function check_reaches_internal(index::SourceIndex, mods; entry_dirs)
    published = Dict{String,Set{String}}()
    owner = Dict{String,Module}()
    for M in mods
        name = string(nameof(M))
        exported = [string(n) for n in names(M)]
        published[name] = Set(exported)
        owner[name] = M
    end
    findings = Finding[]
    for path in scanned_paths(index, entry_dirs)
        isfile(path) || continue
        for (i, line) in enumerate(eachline(path))
            startswith(lstrip(line), "#") && continue
            for m in eachmatch(QUALIFIED_REF, line)
                mod_name = m.captures[1]
                member = m.captures[2]
                haskey(published, mod_name) || continue
                member in published[mod_name] && continue
                isdefined(owner[mod_name], Symbol(member)) || continue
                detail = "reference to a name its module does not export"
                found = Finding(Symbol(mod_name), :reaches_internal, path, "$mod_name.$member", i, detail)
                push!(findings, found)
            end
        end
    end
    findings
end
