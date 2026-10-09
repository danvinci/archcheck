# Interface checks: does a module declare what it publishes, and does anything reach past that declaration.
# A module that exports its whole namespace has no interface to hold, so nothing behind it can move.

function resolve_scan_path(index::SourceIndex, path)
    absolute = isabspath(path) ? path : joinpath(index.repo, path)
    normpath(absolute)
end

function is_blanket_names_call(n)
    JS.kind(n) == K"call" || return false
    kids = child_nodes(n)
    (isnothing(kids) || isempty(kids)) && return false
    kids[1].val === :names || return false
    for c in kids
        JS.kind(c) == K"parameters" || continue
        params = child_nodes(c)
        isnothing(params) && continue
        for p in params
            JS.kind(p) == K"=" || continue
            pk = child_nodes(p)
            (isnothing(pk) || length(pk) < 2) && continue
            pk[1].val === :all && pk[2].val === true && return true
        end
    end
    false
end

function find_blanket_names(n)
    is_blanket_names_call(n) && return n
    kids = child_nodes(n)
    isnothing(kids) && return nothing
    for c in kids
        found = find_blanket_names(c)
        isnothing(found) || return found
    end
    nothing
end

function check_blanket_exports(index::SourceIndex)
    findings = Finding[]
    for f in index.files
        is_wrapper(f) || continue
        hit = find_blanket_names(f.tree)
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
        owner = module_key(M)
        path = module_file(M)
        for n in names(M)
            n === nameof(M) && continue
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
    (isnothing(kids) || length(kids) != 2) && return nothing
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
    (isnothing(kids) || length(kids) < 2) && return
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
    if k == K"const" && !isnothing(kids)
        for c in kids
            collect_const_alias!(aliases, c, known)
        end
        return
    end
    isnothing(kids) && return
    for c in kids
        collect_const_aliases!(aliases, c, known)
    end
end

# Each entry-dir script's path and parse. The index reads these only for names, so they are parsed here.
function entry_trees(index::SourceIndex, entry_dirs)
    trees = Pair{String,JS.SyntaxNode}[]
    seen = Set(resolve_scan_path(index, f.path) for f in index.files)
    for d in entry_dirs
        isdir(d) || continue   # a missing entry dir contributes nothing, as in the index
        for (root, _, files) in walkdir(d), f in files
            endswith(f, ".jl") || continue
            path = joinpath(root, f)
            absolute = resolve_scan_path(index, path)
            absolute in seen && continue
            push!(seen, absolute)
            source = read(absolute, String)
            tree = parse_file(source, path)
            isnothing(tree) && continue
            push!(trees, path => tree)
        end
    end
    trees
end

function reaches_internal(mod_name, path, member, line)
    symbol = "$mod_name.$member"
    detail = "reference to a name its module does not declare public"
    Finding(mod_name, :reaches_internal, path, symbol, line, detail)
end

# An entry script's using or import clause binds an internal name the way a qualified path reaches it. A source
# file's clauses are the declared-names check's.
function imported_internals!(findings, path, tree, modules::ModuleNames, by_key)
    refs = ModRef[]
    walk_modrefs!(refs, :_, Symbol[], path, modules, tree)
    for ref in refs
        ref.via === :using || ref.via === :import || continue
        M = get(by_key, ref.to, nothing)
        isnothing(M) && continue
        for member in ref.names
            isdefined(M, member) || continue
            Base.ispublic(M, member) && continue
            push!(findings, reaches_internal(ref.to, path, member, ref.line))
        end
    end
end

function check_reaches_internal(index::SourceIndex, mods, root::Symbol; entry_dirs)
    known = loaded_modules(mods)
    tracked = Set(mods)
    findings = Finding[]
    scripts = entry_trees(index, entry_dirs)
    by_key = Dict(module_key(M) => M for M in mods)
    keys_known = Set{Symbol}(keys(by_key))
    modules = ModuleNames(keys_known, root)
    for (path, tree) in scripts
        imported_internals!(findings, path, tree, modules, by_key)
    end
    sources = Pair{String,JS.SyntaxNode}[f.path => f.tree for f in index.files]
    for (path, tree) in [sources; scripts]
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
            mod_name = module_key(M)
            push!(findings, reaches_internal(mod_name, path, member, line))
        end
        scope = ScanScope(placeholder, Set{Symbol}(), 0, 0, nothing, false)
        walk_scoped!(fs, tree, scope, on_qualified)
    end
    findings
end

# private-import: an import clause binding another module's underscore name, the mark of what its owner keeps
# internal. The qualified form, `Owner._name`, is reaches-internal's.
function check_private_imports(index::SourceIndex)
    findings = Finding[]
    for ref in index.refs, name in ref.names
        ref.via === :import || ref.via === :using || continue
        startswith(string(name), "_") || continue
        symbol = "$(ref.to).$name"
        detail = "imports a name its module marks private with a leading underscore"
        evidence = [:via => string(ref.via)]
        push!(findings, Finding(ref.from, :private_import, ref.file, symbol, ref.line, detail, evidence))
    end
    findings
end

# undeclared-name: a reference to a name the module it is written through neither exports nor declares public.
# A re-export declares the name there, so a module that only re-exports serves its callers.
function check_declared_names(index::SourceIndex, mods)
    by_key = Dict(module_key(M) => M for M in mods)
    key_of = Dict(M => module_key(M) for M in mods)
    findings = Finding[]
    for ref in index.refs, name in ref.names
        through = get(by_key, ref.to, nothing)
        isnothing(through) && continue
        isdefined(through, name) || continue
        Base.ispublic(through, name) && continue
        home = Base.binding_module(through, name)
        owner = get(key_of, home, join(fullname(home), "."))
        symbol = "$(ref.to).$name"
        detail = "reaches a name the module it names neither exports nor declares public"
        evidence = [:via => string(ref.via), :owner => string(owner)]
        push!(findings, Finding(ref.from, :undeclared_name, ref.file, symbol, ref.line, detail, evidence))
    end
    findings
end

# private-extension: a method one project module adds to a function another owns, unless the owner declares the
# function public and documents it. Extending an undeclared function reaches into its owner's implementation.
function check_declared_extensions(mods; repo)
    project = Set(mods)
    reported = Set{Tuple{Module,Module,Symbol}}()   # (owner, home, function): one finding for all of a home's methods
    findings = Finding[]
    for method in project_methods(mods)
        function_type, _ = split_signature(method.sig)
        function_type isa DataType && function_type <: Function && isdefined(function_type, :instance) || continue
        extended = function_type.instance
        owner_mod = parentmodule(extended)
        home = method.module
        owner_mod in project && owner_mod !== home || continue
        name = nameof(extended)
        key = (owner_mod, home, name)
        key in reported && continue
        push!(reported, key)
        is_public = Base.ispublic(owner_mod, name)
        docs = recorded_docs(owner_mod, name)
        is_documented = !isnothing(docs)
        is_public && is_documented && continue
        owner = string(module_key(owner_mod))
        file, line = method_site(method, repo)
        evidence = [:owner => owner, :function => string(name),
                    :public => string(is_public), :documented => string(is_documented)]
        detail = "adds a method to a function its owner does not declare public and document"
        finding = Finding(module_key(home), :private_extension, file, "$owner.$name", line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# undeclared-module: a reference to a module its source's wrapper does not name in a using or import line.
# Qualified paths count, so the wrapper's using and import lines list every module the module reaches.
function check_declared_modules(index::SourceIndex)
    wrappers = Dict(f.mod => f.path for f in index.files if is_wrapper(f))
    declared = Dict{Symbol,Set{Symbol}}()
    for ref in index.refs
        is_clause = ref.via === :using || ref.via === :import
        is_clause && get(wrappers, ref.from, "") == ref.file || continue
        push!(get!(Set{Symbol}, declared, ref.from), ref.to)
    end
    findings = Finding[]
    for ref in index.refs
        haskey(wrappers, ref.from) || continue
        named = get(declared, ref.from, Set{Symbol}())
        ref.to in named && continue
        target = string(ref.to)
        detail = "reaches a module its wrapper does not name in a using or import line"
        evidence = [:via => string(ref.via)]
        push!(findings, Finding(ref.from, :undeclared_module, ref.file, target, ref.line, detail, evidence))
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
        owner = module_key(parentmodule(unwrapped))
        type_name = nameof(unwrapped)
        file, line = site_of(sites, owner, type_name, ("", 0))
        for (reader, extras) in required
            sig = Tuple{family, extras.parameters...}
            hasmethod(reader, sig) && continue
            reader_name = nameof(reader)
            symbol = "$(type_name).$(reader_name)"
            found = Finding(owner, :reader_set, file, symbol, line,
                  "the type answers no method matching this reader",
                  [:reader => string(reader_name)])
            push!(findings, found)
        end
    end
    findings
end
