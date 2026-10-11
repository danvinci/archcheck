# Imported names: a name a module reads that only a bare `using` brings in, and a name an import list binds that the
# module leaves unread. The parse says which names the module reads; the loaded module says where each comes from.

"""Runs in `CHECKS`. A module reads a name that a bare `using` alone brings in, or a `using X: a` or `import X: a` list binds a name the module leaves unread; a method the module defines through the binding, bare or spliced into an `@eval`, reads it. A name that the package's own modules, Base or Core export stays out of the first: the package or Julia owns both sides of it."""
struct ImportedNames <: Check end

kinds(::ImportedNames) = (:implicit_import => :advisory, :stale_import => :advisory)

run(::ImportedNames, ctx) = check_imported_names(ctx.index, ctx.mods, ctx.root, ctx.recorded)

# Every bare name one module's code reads or exports, across the files and blocks that hold it.
function module_reads(files)
    names = Set{Symbol}()
    for file in files, read in file.scan.reads
        is_member(read) && continue
        is_local_read(read) && continue
        read.is_quoted && continue
        push!(names, read.name)
    end
    names
end

# A bare `using X`: the module it brings in whole and where it is written.
struct WholeUsing
    used::Module   # the module the clause names
    file::String   # repo-relative path
    line::Int      # source line of the clause
end

# One name an import list binds: `a` in `using X: a`, `b` in `import X: a as b`.
struct ListedName
    name::Symbol   # the name the module binds
    from::Module   # the module the clause names
    file::String   # repo-relative path
    line::Int      # source line of the listed name
end

# One module's using and import clauses, resolved against the loaded module.
struct ModuleImports
    whole::Vector{WholeUsing}    # bare using clauses, in load order
    listed::Vector{ListedName}   # names import lists bind, in load order
    bound::Set{Symbol}           # every name a clause binds by writing it: an imported module, a listed or renamed name
end

# The loaded module an import path names from `home`; nothing when the clause did not run, as under a version check
# this Julia skips. A package the module has not bound by name is found through the module's dependencies.
function imported_module(home::Module, dots, path)::Union{Nothing,Module}
    isempty(path) && return nothing
    found = home
    if dots == 0
        found = bound_module(home, first(path))
        if isnothing(found)
            package_name = string(first(path))
            found = loaded_dependency(home, package_name)
        end
    else
        for _ in 2:dots
            found = parentmodule(found)
        end
        found = bound_module(found, first(path))
    end
    for name in path[2:end]
        isnothing(found) && return nothing
        found = bound_module(found, name)
    end
    found
end

# The name one list item binds and the line it is written on.
function listed_binding(item)
    if JS.kind(item) == K"as"
        renamed = renamed_parts(item)
        return renamed.bound, source_line(item)
    end
    _, names = importpath_parts(item)
    isempty(names) && return nothing, 0
    last(names), source_line(item)
end

function add_clause!(imports::ModuleImports, home::Module, file, clause::JS.SyntaxNode, line_kind)
    kind = JS.kind(clause)
    if kind == K"as"
        renamed = renamed_parts(clause)
        isnothing(renamed.bound) || push!(imports.bound, renamed.bound)
        return
    end
    # `import X` binds X; `using X` brings X in with its exports, as Julia's own binding records it.
    if kind == K"importpath"
        dots, path = importpath_parts(clause)
        isempty(path) && return
        if line_kind == K"import"
            push!(imports.bound, last(path))
            return
        end
        used = imported_module(home, dots, path)
        isnothing(used) && return
        line = source_line(clause)
        push!(imports.whole, WholeUsing(used, file, line))
        return
    end
    kind == K":" || return
    children = child_nodes(clause)
    dots, path = importpath_parts(first(children))
    from = imported_module(home, dots, path)
    for item in children[2:end]
        name, line = listed_binding(item)
        isnothing(name) && continue
        push!(imports.bound, name)
        isnothing(from) && continue
        push!(imports.listed, ListedName(name, from, file, line))
    end
end

function module_imports(home::Module, files)
    imports = ModuleImports(WholeUsing[], ListedName[], Set{Symbol}())
    for file in files
        each_clause((clause, line_kind) -> add_clause!(imports, home, file.path, clause, line_kind), file.tree)
    end
    imports
end

# Whether the package or Julia owns both sides of an export: a module of the package, Base, Core, or one inside them.
function is_held_exporter(exporter::Module, modules::ReachModules)
    exporter in modules.tracked && return true
    top = Base.moduleroot(exporter)
    top === modules.package || top === Base || top === Core
end

# Whether `exporter` exports the binding `name` resolves to in the reading module, which `owner` defines.
function exports_binding(exporter::Module, name::Symbol, owner::Module)
    Base.isexported(exporter, name) || return false
    isdefined(exporter, name) || return false
    defining = binding_owner(exporter, name)
    defining === owner
end

# The bare using that brings `name` into `home`; nothing when a clause binds it by name, the module defines it,
# a held module exports the same binding, or the name was imported from more than one module.
function implicit_source(home::Module, name::Symbol, imports::ModuleImports, modules::ReachModules)
    name in imports.bound && return nothing
    isdefined(home, name) || return nothing
    owner = binding_owner(home, name)
    isnothing(owner) && return nothing
    owner === home && return nothing
    for implicit in (Base, Core)
        exports_binding(implicit, name, owner) && return nothing
    end
    source = nothing
    for clause in imports.whole
        exports_binding(clause.used, name, owner) || continue
        is_held_exporter(clause.used, modules) && return nothing
        if isnothing(source)
            source = clause
        end
    end
    source
end

function implicit_findings!(findings, key, home::Module, reads, imports::ModuleImports, modules::ReachModules)
    for name in sort!(collect(reads))
        clause = implicit_source(home, name, imports, modules)
        isnothing(clause) && continue
        owner = binding_owner(home, name)
        isnothing(owner) && continue
        evidence = [:from => module_label(clause.used, modules), :owner => module_label(owner, modules)]
        detail = "reads a name that only a bare using brings in"
        finding = Finding(key, :implicit_import, clause.file, string(name), clause.line, detail, evidence)
        push!(findings, finding)
    end
end

# The lines, per repo-relative file, where `home` itself defines methods of the function its binding `name` holds.
function defining_lines(home::Module, name::Symbol, recorded::RecordedPaths)
    lines = Dict{String,Set{Int}}()
    value = getfield(home, name)
    value isa Function || value isa Type || return lines
    for method in methods(value, home)
        path, line = method_site(method, recorded)
        push!(get!(Set{Int}, lines, path), line)
    end
    lines
end

# Whether a definition's signature names its function through the module's binding: bare, or spliced into quoted code
# (`$op(...)`). A qualified head (`Base.$op`) reaches the function past the binding.
function names_through_binding(form, name::Symbol)
    signature = first(child_nodes(form))
    parts = call_parts(signature)
    isnothing(parts) && return false
    head = parts.head
    JS.kind(head) == K"$" && return true
    node_symbol(head) === name
end

# Whether a definition starting on one of `lines` under `node` names its function through the binding. Quoted code is
# walked too: an `@eval` loop defines from it.
function defines_through_binding(node, lines, name::Symbol)
    if is_method_form(node) && source_line(node) in lines
        names_through_binding(node, name) && return true
    end
    children = child_nodes(node)
    isnothing(children) && return false
    for child in children
        defines_through_binding(child, lines, name) && return true
    end
    false
end

# Whether `home` extends the function its binding `name` holds at a site that names it through that binding: the
# loaded methods say where, the source how. Julia resolved such a definition through the import, so the import is read.
function extends_through_binding(home::Module, name::Symbol, files, recorded)
    lines = defining_lines(home, name, recorded)
    for file in files
        at = get(lines, file.path, nothing)
        isnothing(at) && continue
        defines_through_binding(file.tree, at, name) && return true
    end
    false
end

function stale_findings!(findings, key, home::Module, reads, imports::ModuleImports, modules::ReachModules, files,
                         recorded)
    reported = Set{Tuple{Symbol,Module}}()   # (name, clause module): one finding for a name listed twice
    for listed in imports.listed
        listed.name in reads && continue
        isdefined(home, listed.name) || continue
        Base.ispublic(home, listed.name) && continue
        extends_through_binding(home, listed.name, files, recorded) && continue
        pair = (listed.name, listed.from)
        pair in reported && continue
        push!(reported, pair)
        defining = binding_owner(home, listed.name)
        # A binding imported from more than one module keeps the clause's module as its owner label.
        owner = listed.from
        if !isnothing(defining)
            owner = defining
        end
        evidence = [:from => module_label(listed.from, modules), :owner => module_label(owner, modules)]
        detail = "an import list binds a name the module leaves unread"
        finding = Finding(key, :stale_import, listed.file, string(listed.name), listed.line, detail, evidence)
        push!(findings, finding)
    end
end

# implicit-import and stale-import, per loaded module of the package, extensions included.
function check_imported_names(index::SourceIndex, mods, package::Module, recorded::RecordedPaths)
    no_allowed = ()
    modules = ReachModules(mods, package, no_allowed)
    findings = Finding[]
    for home in mods
        key = module_key(home)
        files = files_of(index, key)
        isempty(files) && continue
        reads = module_reads(files)
        imports = module_imports(home, files)
        implicit_findings!(findings, key, home, reads, imports, modules)
        stale_findings!(findings, key, home, reads, imports, modules, files, recorded)
    end
    findings
end
