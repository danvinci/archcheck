# Module paths resolved against the loaded modules: import clauses, qualifiers and aliases, and the module references
# the layering checks read.

struct ModRef
    from::Symbol          # module the reference is written in
    to::Symbol            # module the reference reaches
    file::String          # repo-relative path
    line::Int             # source line of the reference
    via::Symbol           # :using | :import | :qualified | :extends (a method on `to`'s function)
    names::Vector{Symbol} # names reached in `to`: an import list, or the name after a qualified path; empty for a whole module
end

# A module's dotted key from the package root, split: `Outer.Inner` -> [:Outer, :Inner].
function key_segments(key::Symbol)
    text = string(key)
    parts = split(text, '.')
    Symbol.(parts)
end

# The module `name` binds in a loaded module, as Julia resolves it there: its own definitions, what it imports,
# and its `as` and `const` aliases.
function bound_module(home::Module, name::Symbol)
    isdefined(home, name) || return nothing
    named = getfield(home, name)
    named isa Module ? named : nothing
end

# Code no loaded module holds binds no module by name.
bound_module(::Nothing, _name::Symbol) = nothing

# The modules a path passes from `opened`, one binding per name: `opened`, then each module a name names, up to the
# first name that names none. Every module path resolves here.
function descend!(passed::Vector{Module}, opened::Module, path)
    push!(passed, opened)
    current = opened
    for name in path
        member = bound_module(current, name)
        isnothing(member) && break
        push!(passed, member)
        current = member
    end
    passed
end

# The loaded module `path` names from `opened`; nothing when one of its names binds no module.
function path_module(opened::Module, path)
    passed = descend!(Module[], opened, path)
    length(passed) == length(path) + 1 || return nothing
    last(passed)
end

# The loaded module a dotted key names below the package or one of its loaded extensions; nothing when Julia did
# not load it, as for a file included under a version check that fails on this Julia.
function loaded_module(pkg::Module, key::Symbol)::Union{Nothing,Module}
    segments = key_segments(key)
    head = first(segments)
    opened = bound_module(pkg, head)
    if isnothing(opened)
        opened = Base.get_extension(pkg, head)
    end
    isnothing(opened) && return nothing
    rest = segments[2:end]
    path_module(opened, rest)
end

# Whether `outer` is `inner` or a module `inner` sits inside, by the loaded parent chain.
function encloses(outer::Module, inner::Module)
    current = inner
    while true
        current === outer && return true
        parent = parentmodule(current)
        parent === current && return false
        current = parent
    end
end

# Leading-dot count and names of an import path: `..A.B` -> (2, [:A, :B]).
function importpath_parts(path)
    dots = 0
    names = Symbol[]
    children = child_nodes(path)
    isnothing(children) && return dots, names
    for child in children
        name = named_symbol(child)
        isnothing(name) && continue
        if name === :. && isempty(names)
            dots += 1
        else
            push!(names, name)
        end
    end
    dots, names
end

# An `as` node's renamed path and the name it binds: `..A.B as C` -> (2, [:A, :B], :C).
function renamed_parts(node)
    parts = child_nodes(node)
    dots, path = importpath_parts(parts[1])
    bound = node_symbol(parts[2])
    (; dots, path, bound)
end

# The identifiers of a pure dotted name, `A.B.c` -> [:A, :B, :c]; nothing when any part is an expression.
function dotted_names(node)::Union{Nothing,Vector{Symbol}}
    named = node_symbol(node)
    if !isnothing(named)
        names = Symbol[named]
        return names
    end
    JS.kind(node) == K"." || return nothing
    children = child_nodes(node)
    child_count(children) != 2 && return nothing
    head = dotted_names(children[1])
    member = node_symbol(children[2])
    isnothing(head) && return nothing
    isnothing(member) && return nothing
    push!(head, member)
    head
end

# The loaded modules a reference resolves against, and the outside ones whose internals the package reads on purpose.
struct ReachModules
    by_key::Dict{Symbol,Module}   # each package module by its dotted key
    tracked::Set{Module}          # the package's own modules, which a finding names by key
    package::Module               # the package root, which an entry script knows by its name
    allowed::Set{Module}          # outside modules whose internal names the package reads on purpose
    top::Dict{Symbol,Module}      # each loaded top-level module by name, where a path with no leading dot opens
end

# The modules an entry script binds by name. A script runs where the package is loaded, so it knows the package by
# its name; every other name comes from its own using, import and `const` lines, bound as the walk meets them.
struct ScriptNames
    bound::Dict{Symbol,Module}   # name -> the loaded module it binds
    used::Vector{Module}         # modules a `using` line brings in whole, whose exported modules the script sees
    home::Union{Nothing,Module}  # the loaded module a script's module block stands for; nothing at a file's top level
    top::Dict{Symbol,Module}     # each loaded top-level module by name, where a path with no leading dot opens
end

# The names a script binds before any line of its own: Core and Base, as every module does, and the package.
function ScriptNames(modules::ReachModules, home)
    package = modules.package
    bound = Dict{Symbol,Module}(:Core => Core, :Base => Base)
    bound[nameof(package)] = package
    ScriptNames(bound, Module[], home, modules.top)
end

function bound_module(script::ScriptNames, name::Symbol)
    named = get(script.bound, name, nothing)
    isnothing(named) || return named
    for used in script.used
        Base.isexported(used, name) || continue
        exported = bound_module(used, name)
        isnothing(exported) || return exported
    end
    nothing
end

# The loaded module a qualifier names: a bare name's binding where the code sits, or the module a dotted qualifier
# met earlier in the walk named.
function qualifier_module(walk::CodeWalk, qualifier)
    name = node_symbol(qualifier)
    isnothing(name) || return bound_module(walk.names, name)
    get(walk.named, qualifier, nothing)
end

# The package a path with no leading dot opens at: a module the code binds by that name, else the loaded dependency or,
# once the environment that loaded the code is gone, the loaded package of that name.
function package_named(home::Module, name::Symbol)
    bound = bound_module(home, name)
    isnothing(bound) || return bound
    text = string(name)
    dependency = loaded_dependency(home, text)
    isnothing(dependency) || return dependency
    loaded_package(text)
end

package_named(script::ScriptNames, name::Symbol) = get(script.top, name, nothing)
package_named(::Nothing, _name::Symbol) = nothing

# The loaded module code sits in, where a path with leading dots climbs from.
code_module(home::Module) = home
code_module(script::ScriptNames) = script.home
code_module(::Nothing) = nothing

# Where an import path opens and how many of its names that takes. With no leading dot it opens at the package its
# first name names; with dots, at the module its first name binds in the code's module or a parent per further dot.
function path_opening(names, dots::Int, path::Vector{Symbol})
    head = first(path)
    dots == 0 && return package_named(names, head), 1
    enclosing = code_module(names)
    isnothing(enclosing) && return nothing, 1
    for _ in 2:dots
        enclosing = parentmodule(enclosing)
    end
    opened = bound_module(enclosing, head)
    isnothing(opened) && return enclosing, 0   # a name such as `..f`, read through the enclosing module
    opened, 1
end

# The loaded modules an import path passes from where the code sits, and the names its opening takes.
function path_modules(names, dots::Int, path::Vector{Symbol})
    passed = Module[]
    isempty(path) && return passed, 1
    opened, opening = path_opening(names, dots, path)
    isnothing(opened) && return passed, opening
    rest = path[(opening + 1):end]
    descend!(passed, opened, rest)
    passed, opening
end

# The loaded module a clause's whole path names; nothing when one of its names binds no module.
function named_module(clause::ImportClause)
    isempty(clause.modules) && return nothing
    reached = length(clause.modules) - 1 + clause.opening
    reached == length(clause.path) || return nothing
    last(clause.modules)
end

function import_item(item)
    line = source_line(item)
    if JS.kind(item) == K"as"
        renamed = renamed_parts(item)
        return ImportItem(renamed.path, renamed.bound, line)
    end
    _, path = importpath_parts(item)
    bound = isempty(path) ? nothing : last(path)
    ImportItem(path, bound, line)
end

# One clause as the record holds it: a whole path, a renamed one, or a path and the list it binds from there.
function import_clause(names, keyword::Symbol, line::Int, clause)
    kind = JS.kind(clause)
    items = ImportItem[]
    if kind == K":"
        children = child_nodes(clause)
        dots, path = importpath_parts(first(children))
        for item in children[2:end]
            push!(items, import_item(item))
        end
        bound = nothing
    elseif kind == K"as"
        renamed = renamed_parts(clause)
        dots = renamed.dots
        path = renamed.path
        bound = renamed.bound
    elseif kind == K"importpath"
        dots, path = importpath_parts(clause)
        bound = isempty(path) ? nothing : last(path)
    else
        return nothing
    end
    modules, opening = path_modules(names, dots, path)
    ImportClause(keyword, path, items, bound, line, clause, modules, opening)
end

function add_bound_names!(imports::Set{Symbol}, clause::ImportClause)
    if isempty(clause.items)
        isnothing(clause.bound) || push!(imports, clause.bound)
        return imports
    end
    for item in clause.items
        isnothing(item.bound) || push!(imports, item.bound)
    end
    imports
end

# Whether a node sits in quoted code below `root`, the whole tree for nothing; such code runs only where evaluated.
function in_quote(node, root)
    current = node.parent
    while !isnothing(current) && current !== root
        JS.kind(current) == K"quote" && return true
        current = current.parent
    end
    false
end

# The modules one clause binds in a script: a path naming a module whole binds its last name or the name after `as`,
# and `using` it brings its exports; a listed name binds when it names a module.
bind_clause!(_names, _clause::ImportClause) = nothing

function bind_clause!(script::ScriptNames, clause::ImportClause)
    named = named_module(clause)
    isnothing(named) && return
    if isempty(clause.items)
        isnothing(clause.bound) && return
        script.bound[clause.bound] = named
        clause.keyword === :using && push!(script.used, named)
        return
    end
    for item in clause.items
        length(item.path) == 1 || continue
        isnothing(item.bound) && continue
        member = bound_module(named, only(item.path))
        isnothing(member) && continue
        script.bound[item.bound] = member
    end
end

# Each clause of a using or import line, resolved once where the code sits. Julia runs such a line only outside
# methods and quoted code, so only those are filed; the names any clause binds join the scan's imports.
function note_import!(walk::CodeWalk, node, scope)
    keyword = Symbol(string(JS.kind(node)))
    line = source_line(node)
    is_run = isnothing(scope.method) && !in_quote(node, nothing)
    for child in child_nodes(node)
        clause = import_clause(walk.names, keyword, line, child)
        isnothing(clause) && continue
        add_bound_names!(walk.scan.imports, clause)
        is_run || continue
        push!(walk.scan.clauses, clause)
        bind_clause!(walk.names, clause)
    end
end

# A script's `const` binding of a module: its name stands for that module from then on. A loaded module's own
# binding already records an alias.
note_alias!(_walk::CodeWalk, _node) = nothing

function note_alias!(walk::CodeWalk{ScriptNames}, node)
    for declaration in child_nodes(node)
        JS.kind(declaration) == K"=" || continue
        sides = child_nodes(declaration)
        child_count(sides) < 2 && continue
        alias = node_symbol(sides[1])
        isnothing(alias) && continue
        aliased = qualifier_module(walk, sides[2])
        isnothing(aliased) && continue
        walk.names.bound[alias] = aliased
    end
end

# The reference one clause makes: the deepest package module its path passes, with the names after it and those its
# list binds. A path through no package module, or only through its own, makes none.
function clause_ref(from::Symbol, file::String, clause::ImportClause, module_keys)
    depth = findlast(passed -> haskey(module_keys, passed), clause.modules)
    isnothing(depth) && return nothing
    to = module_keys[clause.modules[depth]]
    to === from && return nothing
    first_after = depth + clause.opening
    names = clause.path[first_after:end]
    for item in clause.items
        append!(names, item.path)
    end
    ModRef(from, to, file, clause.line, clause.keyword, names)
end

# Whether a dotted name goes on past `dot` to a further named member, whose read holds the reference.
function continues_path(dot)
    outer = dot.parent
    isnothing(outer) && return false
    JS.kind(outer) == K"." || return false
    parts = child_nodes(outer)
    child_count(parts) == 2 || return false
    parts[1] === dot || return false
    member = named_symbol(parts[2])
    !isnothing(member)
end

# A `where` clause or a return type around a signature's call.
function wraps_signature(node)
    isnothing(node) && return false
    kind = JS.kind(node)
    kind == K"where" || kind == K"::"
end

# Whether `dot` is the name a method form defines, `Sub.f` in `Sub.f(x) = x`.
function names_method(dot)
    call = dot.parent
    isnothing(call) && return false
    form = call.parent
    while wraps_signature(form)   # bounded: each pass climbs one parent
        form = form.parent
    end
    isnothing(form) && return false
    is_method_form(form) || return false
    signature = first(child_nodes(form))
    signature_call(signature) === call || return false
    first(child_nodes(call)) === dot
end

# The reference one member read makes: the package module it names, or the one it is read through with its name. A
# method named this way extends that module's function.
function read_ref(from::Symbol, file::String, read::NameRead, module_keys)
    is_member(read) || return nothing
    through = read.through
    isnothing(through) && return nothing
    dot = read.qualifier.parent
    target = through
    names = Symbol[read.name]
    member = bound_module(through, read.name)
    if !isnothing(member) && haskey(module_keys, member)
        continues_path(dot) && return nothing
        target = member
        names = Symbol[]
    end
    to = get(module_keys, target, nothing)
    isnothing(to) && return nothing
    to === from && return nothing
    via = names_method(dot) ? :extends : :qualified
    ModRef(from, to, file, read.line, via, names)
end

# The module references one piece of code makes, in source order: its clauses, and its member reads through a package
# module. `module_keys` names each loaded package module by its index key.
function code_refs!(refs, from::Symbol, file::String, scan::FileScan, module_keys)
    placed = Tuple{Int,ModRef}[]
    for clause in scan.clauses
        ref = clause_ref(from, file, clause, module_keys)
        isnothing(ref) && continue
        byte = JS.first_byte(clause.node)
        push!(placed, (byte, ref))
    end
    for read in scan.reads
        ref = read_ref(from, file, read, module_keys)
        isnothing(ref) && continue
        byte = JS.first_byte(read.qualifier)
        push!(placed, (byte, ref))
    end
    sort!(placed; by = first)
    for (_, ref) in placed
        push!(refs, ref)
    end
    refs
end

# The loaded top-level module a script's module block names, as a fixture package's spine read as a script does.
function script_home(modules::ReachModules, tree)
    block = tree.parent
    isnothing(block) && return nothing
    is_module_block(block) || return nothing
    name = module_name(block)
    isnothing(name) && return nothing
    get(modules.top, name, nothing)
end
