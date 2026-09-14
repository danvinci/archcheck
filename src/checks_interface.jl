# Interface checks: does a module declare what it publishes, and does anything reach past that declaration.
# A module that exports its whole namespace has no interface to hold, so nothing behind it can move.

# The module's own wrapper path, for a finding that has no single source line.
function module_file(M)
    name = string(nameof(M))
    "src/" * lowercase(name) * "/" * name * ".jl"
end

function resolve_scan_path(index::SourceIndex, path)
    isabspath(path) ? path : joinpath(index.repo, path)
end

function is_blanket_names_call(n)
    JS.kind(n) == K"call" || return false
    kids = child_nodes(n)
    (kids === nothing || isempty(kids)) && return false
    kids[1].val === :names || return false
    for c in kids
        JS.kind(c) == K"parameters" || continue
        params = child_nodes(c)
        params === nothing && continue
        for p in params
            JS.kind(p) == K"=" || continue
            pk = child_nodes(p)
            (pk === nothing || length(pk) < 2) && continue
            pk[1].val === :all && pk[2].val === true && return true
        end
    end
    false
end

function find_blanket_names(n)
    is_blanket_names_call(n) && return n
    kids = child_nodes(n)
    kids === nothing && return nothing
    for c in kids
        found = find_blanket_names(c)
        found === nothing || return found
    end
    nothing
end

function check_blanket_exports(index::SourceIndex)
    findings = Finding[]
    for f in index.files
        is_wrapper(f) || continue
        path = resolve_scan_path(index, f.path)
        isfile(path) || continue
        tree = parse_file(read(path, String), f.path)
        tree === nothing && continue
        hit = find_blanket_names(tree)
        isnothing(hit) && continue
        line = Int(JS.source_location(hit)[1])
        detail = "module exports its whole namespace, so it declares no interface"
        push!(findings, Finding(f.mod, :blanket_export, f.path, "", line, detail))
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

# A.B.name belongs to B: the qualifier immediately before the member.
function rightmost_ident(n)
    n.val isa Symbol && return n.val
    JS.kind(n) == K"." || return nothing
    kids = child_nodes(n)
    (kids === nothing || isempty(kids)) && return nothing
    rightmost_ident(last(kids))
end

function walk_qualified!(visit, n)
    kids = child_nodes(n)
    if JS.kind(n) == K"." && kids !== nothing && length(kids) == 2
        owner = rightmost_ident(kids[1])
        member = kids[2].val
        if owner isa Symbol && member isa Symbol
            visit(owner, member, Int(JS.source_location(n)[1]))
        end
    end
    kids === nothing && return
    for c in kids
        walk_qualified!(visit, c)
    end
end

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
        abs = resolve_scan_path(index, path)
        isfile(abs) || continue
        tree = parse_file(read(abs, String), path)
        tree === nothing && continue
        walk_qualified!(tree) do mod_name, member, line
            key = string(mod_name)
            haskey(published, key) || return
            string(member) in published[key] && return
            isdefined(owner[key], member) || return
            detail = "reference to a name its module does not export"
            found = Finding(mod_name, :reaches_internal, path, "$mod_name.$member", line, detail)
            push!(findings, found)
        end
    end
    findings
end

# Every concrete subtype of `super` answers each (reader, extra-argument types) pair, including inherited methods.
function check_reader_set(mods, super::Type, required; sites = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}())
    findings = Finding[]
    seen = Set{Type}()
    for M in mods, n in names(M; all = true)
        is_module = n === nameof(M)
        is_internal = startswith(string(n), "#")
        (is_module || is_internal) && continue
        isdefined(M, n) || continue
        T = getfield(M, n)
        T isa Type || continue
        unwrapped = Base.unwrap_unionall(T)
        unwrapped isa DataType || continue
        isabstracttype(unwrapped) && continue
        family = unwrapped.name.wrapper
        family <: super || continue
        family == super && continue
        family in seen && continue
        push!(seen, family)
        owner_mod = parentmodule(unwrapped)
        type_name = nameof(unwrapped)
        file, line = site_of(sites, nameof(owner_mod), type_name, ("", 0))
        for (reader, extras) in required
            sig = Tuple{family, extras.parameters...}
            hasmethod(reader, sig) && continue
            reader_name = nameof(reader)
            symbol = "$(type_name).$(reader_name)"
            found = Finding(nameof(owner_mod), :reader_set, file, symbol, line,
                  "the type answers no method matching this reader",
                  [:reader => string(reader_name)];
                  tier = :structure)
            push!(findings, found)
        end
    end
    findings
end
