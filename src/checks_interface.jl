# Interface checks: does a module declare what it publishes, and does anything reach past that declaration.
# A module that exports its whole namespace has no interface to hold, so nothing behind it can move.

# The module's own wrapper path, for a finding that has no single source line.
function module_file(M)
    name = string(nameof(M))
    "src/" * lowercase(name) * "/" * name * ".jl"
end

function resolve_scan_path(index::SourceIndex, path)
    absolute = isabspath(path) ? path : joinpath(index.repo, path)
    normpath(absolute)
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

# Loaded modules plus their parents, so `Root.Child` follows Module identity along the path.
function loaded_modules(mods)
    known = Dict{Symbol,Module}()
    for M in mods
        known[nameof(M)] = M
        ancestor = parentmodule(M)
        while !haskey(known, nameof(ancestor))
            known[nameof(ancestor)] = ancestor
            ancestor = parentmodule(ancestor)
        end
    end
    known
end

function resolve_loaded_module(n, known, aliases, bound)
    if n.val isa Symbol
        n.val in bound && return nothing
        if haskey(aliases, n.val)
            return aliases[n.val]
        end
        return get(known, n.val, nothing)
    end
    JS.kind(n) == K"." || return nothing
    kids = child_nodes(n)
    (kids === nothing || length(kids) != 2) && return nothing
    parent_mod = resolve_loaded_module(kids[1], known, aliases, bound)
    isnothing(parent_mod) && return nothing
    member = kids[2].val
    member isa Symbol || return nothing
    isdefined(parent_mod, member) || return nothing
    child = getfield(parent_mod, member)
    child isa Module ? child : nothing
end

function collect_const_alias!(aliases, n, known)
    JS.kind(n) == K"=" || return
    kids = child_nodes(n)
    (kids === nothing || length(kids) < 2) && return
    lhs = kids[1]
    lhs.val isa Symbol || return
    M = resolve_loaded_module(kids[2], known, aliases, Set{Symbol}())
    isnothing(M) && return
    aliases[lhs.val] = M
end

function collect_const_aliases!(aliases, n, known)
    k = JS.kind(n)
    k == K"quote" && return
    is_nested_scope(n) && return
    kids = child_nodes(n)
    if k == K"const" && kids !== nothing
        for c in kids
            collect_const_alias!(aliases, c, known)
        end
        return
    end
    kids === nothing && return
    for c in kids
        collect_const_aliases!(aliases, c, known)
    end
end

function scanned_paths(index::SourceIndex, entry_dirs)
    paths = String[f.path for f in index.files]
    for d in entry_dirs, (root, _, files) in walkdir(d), f in files
        endswith(f, ".jl") || continue
        push!(paths, joinpath(root, f))
    end
    unique(path -> resolve_scan_path(index, path), paths)
end

function check_reaches_internal(index::SourceIndex, mods; entry_dirs)
    known = loaded_modules(mods)
    tracked = Set(mods)
    findings = Finding[]
    for path in scanned_paths(index, entry_dirs)
        abs = resolve_scan_path(index, path)
        isfile(abs) || continue
        tree = parse_file(read(abs, String), path)
        tree === nothing && continue
        aliases = Dict{Symbol,Module}()
        collect_const_aliases!(aliases, tree, known)
        fs = empty_scan()
        placeholder = :_
        fs.refs[placeholder] = Set{Symbol}()
        function on_qualified(qualifier, member, line, bound)
            M = resolve_loaded_module(qualifier, known, aliases, bound)
            isnothing(M) && return
            M in tracked || return
            isdefined(M, member) || return
            Base.ispublic(M, member) && return
            mod_name = nameof(M)
            symbol = "$mod_name.$member"
            detail = "reference to a name its module does not declare public"
            push!(findings, Finding(mod_name, :reaches_internal, path, symbol, line, detail))
        end
        walk_scoped!(fs, tree, 0, placeholder, Set{Symbol}(), on_qualified)
    end
    findings
end
