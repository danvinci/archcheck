# Multi-owner gate: two independent module-level constants that each decide the same concept drift
# silently, since nothing ties them together. Single-owner, read at the granularity of a boolean gate.
#
# Scope is const-vs-const only, never a function's own keyword-argument default: a kwarg default is
# routinely threaded hand-to-hand through several signatures under the identical name, so a name-stem
# match on that shape would flag idiomatic parameter-passing rather than a real duplication.

const GATE_TOKENS = Set(("ON", "OFF", "ENABLE", "ENABLED", "DISABLE", "DISABLED"))

function is_boolish_rhs(n)
    n.val isa Bool && return true
    infix_op(n) in (:(==), :(!=), :(<), :(<=), :(>), :(>=))
end

# The concept a gate name encodes, on/off vocabulary stripped: MSCKF_ON and MSCKF_ENABLED both reduce
# to "MSCKF". `nothing` when nothing survives the strip, leaving no bare concept to compare.
function gate_stem(name::Symbol)
    raw_tokens = split(string(name), '_')
    tokens = [uppercase(t) for t in raw_tokens if !isempty(t)]
    kept = [t for t in tokens if !(t in GATE_TOKENS)]
    isempty(kept) ? nothing : join(kept, "_")
end

# every top-level `const NAME = <boolish>` in one already-parsed file.
function module_consts(tree)
    out = Tuple{Symbol,Any}[]
    kids = child_nodes(tree)
    kids === nothing && return out
    for stmt in kids
        JS.kind(stmt) == K"const" || continue
        cs = child_nodes(stmt)
        (cs === nothing || isempty(cs)) && continue
        JS.kind(cs[1]) == K"=" || continue
        aks = child_nodes(cs[1])
        (aks === nothing || length(aks) != 2) && continue
        lhs, rhs = aks
        lhs.val isa Symbol && push!(out, (lhs.val, rhs))
    end
    out
end

function record_module_consts!(owners, path::AbstractString, rel::AbstractString)
    isfile(path) || return
    tree = parse_file(read(path, String), rel)
    tree === nothing && return
    for (name, rhs) in module_consts(tree)
        is_boolish_rhs(rhs) || continue
        stem = gate_stem(name)
        stem === nothing && continue
        push!(get!(owners, stem, Tuple{Symbol,String}[]), (name, rel))
    end
end

# Walks src/ directly rather than index.files: a file with no module wrapper, sitting at src/'s own top
# level, never enters index.files, yet is exactly where a top-level gate constant tends to live.
function check_multi_owner_gate(index::SourceIndex, entry_dirs)
    owners = Dict{String,Vector{Tuple{Symbol,String}}}()
    src_dir = joinpath(index.repo, "src")
    for dir in vcat([src_dir], collect(entry_dirs))
        isdir(dir) || continue
        for (root, _, files) in walkdir(dir), fn in files
            endswith(fn, ".jl") || continue
            path = joinpath(root, fn)
            record_module_consts!(owners, path, relpath(path, index.repo))
        end
    end

    findings = Finding[]
    for stem in sort(collect(keys(owners)))
        sites = owners[stem]
        files = sort(unique(f for (_, f) in sites))
        length(files) >= 2 || continue
        own_names = unique(string(n) for (n, _) in sites)
        names = join(sort(own_names), " ")
        sitestr = join(("$file:$name" for (name, file) in sort(sites)), "  ")
        push!(findings, Finding(:Multiple, :multi_owner_gate, first(files), stem, 0,
              "more than one module-level const gates the same concept independently",
              [:names => names, :sites => sitestr]))
    end
    findings
end
