# Imported names: a name a module reads that only a bare `using` brings in, and a name an import list binds that the
# module leaves unread. The parse says which names the module reads; the loaded module says where each comes from.

"""Runs in `CHECKS`. A module reads a name that a bare `using` alone brings in, or a `using X: a` or `import X: a` list binds a name the module leaves unread. A name that the package's own modules, Base or Core export stays out of the first: the package or Julia owns both sides of it."""
struct ImportedNames <: Check end

kinds(::ImportedNames) = (:implicit_import => :advisory, :stale_import => :advisory)

run(::ImportedNames, ctx) = check_imported_names(ctx.index, ctx.mods, ctx.root)

# The free names one module's code reads, gathered by the index's scoped walk.
struct ReadNames
    refs::Dict{Symbol,Set{Symbol}}                    # the per-definition sets a method opens in the walk, left unread
    read::Set{Symbol}                                 # each free name the code reads, a macro's with its `@`
    macro_locals::IdDict{JS.SyntaxNode,Set{Symbol}}   # each macro definition -> the names its arguments and body bind
end

function ReadNames()
    refs = Dict{Symbol,Set{Symbol}}()
    ReadNames(refs, Set{Symbol}(), IdDict{JS.SyntaxNode,Set{Symbol}}())
end

# The name an identifier reads, as Julia binds it: a macro's with its `@`, a string macro's with its suffix.
# A name an import clause writes and a lone quoted symbol read nothing.
function read_name(node)::Union{Nothing,Symbol}
    name = node_symbol(node)
    isnothing(name) && return nothing
    kind = JS.kind(node)
    kind == K"StrMacroName" && return Symbol("@", name, "_str")
    kind == K"CmdMacroName" && return Symbol("@", name, "_cmd")
    parent = node.parent
    isnothing(parent) && return name
    parent_kind = JS.kind(parent)
    parent_kind == K"importpath" && return nothing
    parent_kind == K"as" && return nothing
    if parent_kind == K"quote"
        quoted = child_nodes(parent)
        child_count(quoted) == 1 && return nothing
    end
    parent_kind == K"macro_name" || return name
    holder = parent.parent
    !isnothing(holder) && JS.kind(holder) == K"importpath" && return nothing
    Symbol("@", name)
end

# A form around a field name that keeps it a name: the left of `x::T` and `x = v`, `const`, a docstring's subject.
function is_field_wrapper(parent, child)
    kind = JS.kind(parent)
    kind == K"const" && return true
    children = child_nodes(parent)
    child_count(children) == 0 && return false
    if kind == K"::" || kind == K"="
        return children[1] === child
    end
    if kind == K"doc"
        return last(children) === child
    end
    false
end

# A struct field's name, bare, typed, with a default, `const` or documented, in the struct's own block.
function is_field_name(node)
    current = node
    parent = node.parent
    while !isnothing(parent) && is_field_wrapper(parent, current)
        current = parent
        parent = parent.parent
    end
    isnothing(parent) && return false
    JS.kind(parent) == K"block" || return false
    holder = parent.parent
    isnothing(holder) && return false
    JS.kind(holder) == K"struct"
end

# A macro definition's own name, `m` in `macro m(ex)`.
function is_macro_name(node)
    call = node.parent
    isnothing(call) && return false
    JS.kind(call) == K"call" || return false
    definition = call.parent
    isnothing(definition) && return false
    JS.kind(definition) == K"macro" || return false
    signature = first(child_nodes(definition))
    callee = first(child_nodes(call))
    signature === call && callee === node
end

# The type parameters a type definition declares: `T` in `struct S{T<:Real} <: A{T}`.
function type_parameters(definition)
    parameters = Symbol[]
    children = child_nodes(definition)
    child_count(children) == 0 && return parameters
    head = children[1]
    if JS.kind(head) == K"<:"
        head = first(child_nodes(head))
    end
    JS.kind(head) == K"curly" || return parameters
    declared = child_nodes(head)
    for parameter in declared[2:end]
        _argname!(parameters, parameter)
    end
    parameters
end

function macro_locals(scan::ReadNames, definition)
    haskey(scan.macro_locals, definition) && return scan.macro_locals[definition]
    children = child_nodes(definition)
    outer = Set{Symbol}()
    bound = child_count(children) < 2 ? outer : body_locals(children[1], children[2], outer)
    scan.macro_locals[definition] = bound
    bound
end

# Whether `node` declares `name` where the scoped walk sees a read: a struct field, a type's parameter, a `where`
# variable, a macro's name, or a macro's argument or local.
function is_declared_name(scan::ReadNames, node, name)
    is_field_name(node) && return true
    is_macro_name(node) && return true
    current = node.parent
    while !isnothing(current)
        kind = JS.kind(current)
        if kind == K"where"
            variables = Symbol[]
            where_vars!(variables, current)
            name in variables && return true
        elseif is_type_form(kind)
            name in type_parameters(current) && return true
        elseif kind == K"macro"
            name in macro_locals(scan, current) && return true
        end
        current = current.parent
    end
    false
end

# The scoped walk's free-name hook, for a read of imported names.
function note_free_name!(scan::ReadNames, node, scope)
    name = read_name(node)
    isnothing(name) && return
    name in scope.bound && return
    is_declared_name(scan, node, name) && return
    push!(scan.read, name)
end

# A member read through a qualifier names no binding of the reading module.
note_member!(::ReadNames, scope, qualifier, member) = nothing

# The scoped walk reads signatures and assignment targets only while a listener is set; this read keeps no path.
ignore_qualified(qualifier, member, line, bound) = nothing

# Every name one module's code reads, across the files and blocks that hold it.
function module_reads(files)
    scan = ReadNames()
    for file in files
        scope = ScanScope(:_, Set{Symbol}(), 0, 0, nothing, false)
        walk_scoped!(scan, file.tree, scope, ignore_qualified)
    end
    scan.read
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
            id = Base.identify_package(home, string(first(path)))
            isnothing(id) && return nothing
            found = Base.maybe_root_module(id)
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

function add_clause!(imports::ModuleImports, home::Module, file, clause, line_kind)
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
    which(exporter, name) === owner
end

# The bare using that brings `name` into `home`; nothing when a clause binds it by name, the module defines it, or
# a held module exports the same binding.
function implicit_source(home::Module, name::Symbol, imports::ModuleImports, modules::ReachModules)
    name in imports.bound && return nothing
    isdefined(home, name) || return nothing
    owner = which(home, name)
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
        owner = which(home, name)
        evidence = [:from => module_label(clause.used, modules), :owner => module_label(owner, modules)]
        detail = "reads a name that only a bare using brings in"
        finding = Finding(key, :implicit_import, clause.file, string(name), clause.line, detail, evidence)
        push!(findings, finding)
    end
end

function stale_findings!(findings, key, home::Module, reads, imports::ModuleImports, modules::ReachModules)
    reported = Set{Tuple{Symbol,Module}}()   # (name, clause module): one finding for a name listed twice
    for listed in imports.listed
        listed.name in reads && continue
        isdefined(home, listed.name) || continue
        Base.ispublic(home, listed.name) && continue
        pair = (listed.name, listed.from)
        pair in reported && continue
        push!(reported, pair)
        owner = which(home, listed.name)
        evidence = [:from => module_label(listed.from, modules), :owner => module_label(owner, modules)]
        detail = "an import list binds a name the module leaves unread"
        finding = Finding(key, :stale_import, listed.file, string(listed.name), listed.line, detail, evidence)
        push!(findings, finding)
    end
end

# implicit-import and stale-import, per loaded module of the package, extensions included.
function check_imported_names(index::SourceIndex, mods, package::Module)
    modules = ReachModules(mods, package)
    findings = Finding[]
    for home in mods
        key = module_key(home)
        files = files_of(index, key)
        isempty(files) && continue
        reads = module_reads(files)
        imports = module_imports(home, files)
        implicit_findings!(findings, key, home, reads, imports, modules)
        stale_findings!(findings, key, home, reads, imports, modules)
    end
    findings
end
