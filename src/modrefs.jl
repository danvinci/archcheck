# Module references: import clauses and qualified paths, resolved against the package's modules.

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

# The loaded module a dotted key names below the package or one of its loaded extensions; nothing when Julia did
# not load it, as for a file included under a version check that fails on this Julia.
function loaded_module(pkg::Module, key::Symbol)::Union{Nothing,Module}
    segments = key_segments(key)
    head = first(segments)
    if isdefined(pkg, head)
        found = getfield(pkg, head)
    else
        found = Base.get_extension(pkg, head)
    end
    isnothing(found) && return nothing
    for segment in segments[2:end]
        isdefined(found, segment) || return nothing
        found = getfield(found, segment)
    end
    found
end

# The module `name` binds in a loaded module, as Julia resolves it there: its own definitions, what it imports,
# and its `as` and `const` aliases.
function bound_module(home::Module, name::Symbol)
    isdefined(home, name) || return nothing
    named = getfield(home, name)
    named isa Module ? named : nothing
end

# The loaded module a qualifier names, read where the code sits: a name `names` binds, else a member module of
# the module its own qualifier names. A name the code binds locally names no module.
function resolve_loaded_module(qualifier, names, bound)
    name = node_symbol(qualifier)
    if !isnothing(name)
        name in bound && return nothing
        return bound_module(names, name)
    end
    JS.kind(qualifier) == K"." || return nothing
    path_parts = child_nodes(qualifier)
    child_count(path_parts) != 2 && return nothing
    enclosing = resolve_loaded_module(path_parts[1], names, bound)
    isnothing(enclosing) && return nothing
    member = node_symbol(path_parts[2])
    isnothing(member) && return nothing
    bound_module(enclosing, member)
end

# The names module paths resolve against.
struct ModuleNames
    known::Set{Symbol}          # every project module, by dotted key below the package
    root::Union{Symbol,Nothing} # the package's own name, which a path may open with; nothing when unknown
    aliases::Dict{Symbol,Dict{Symbol,Symbol}}   # module -> each name its `as` clauses bind -> the project module it names
end

# Names before any `as` clause is read: the read that collects the renames resolves through plain paths.
ModuleNames(known, root) = ModuleNames(known, root, Dict{Symbol,Dict{Symbol,Symbol}}())

# The key of the module `name` inside the module keyed `key`; the root's own modules are keyed by their names.
child_key(modules::ModuleNames, key, name) = key === modules.root ? name : Symbol(key, ".", name)

# The deepest project module `path` names below the module keyed `key`, and how many names of `path` that took.
function descend_module(modules::ModuleNames, key, path)
    spanned = 0
    while spanned < length(path)
        deeper = child_key(modules, key, path[spanned + 1])
        deeper in modules.known || break
        key = deeper
        spanned += 1
    end
    key, spanned
end

# A path with no leading dot is absolute and opens at the root. One dot opens in `scope`, each further dot
# in its parent, and lookup then widens toward the root.
function resolve_opening(scope, dots)
    dots == 0 && return 0
    climbed = length(scope) - (dots - 1)
    max(climbed, 0)
end

# The project module a path reaches from `scope`, and how many names of that path it spans.
function resolve_module(modules::ModuleNames, scope::Vector{Symbol}, path::Vector{Symbol}, dots::Int)
    opening = resolve_opening(scope, dots)
    rest = path[2:end]
    for depth in opening:-1:0
        if depth == 0 && first(path) === modules.root   # the package itself; its modules sit below it
            inner, spanned = descend_module(modules, modules.root, rest)
            return inner, spanned + 1
        end
        segments = [scope[1:depth]; path[1]]
        key = Symbol(join(segments, "."))
        key in modules.known || continue
        deeper, spanned = descend_module(modules, key, rest)
        return deeper, spanned + 1
    end
    nothing, 0
end

# The project module a qualified path written in `from` reaches. A name an `as` clause binds in `from` stands for
# the module it renames, as Julia resolves the binding.
function resolve_qualifier(modules::ModuleNames, from, scope, path)
    renames = get(modules.aliases, from, nothing)
    target = isnothing(renames) ? nothing : get(renames, first(path), nothing)
    isnothing(target) && return resolve_module(modules, scope, path, 1)
    rest = path[2:end]
    deeper, spanned = descend_module(modules, target, rest)
    deeper, spanned + 1
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

# The key of the project module an import path names whole; nothing for a path to anything else.
function whole_module(modules::ModuleNames, scope, dots, path)::Union{Nothing,Symbol}
    isempty(path) && return nothing
    dots == 0 && first(path) !== modules.root && return nothing
    to, spanned = resolve_module(modules, scope, path, dots)
    spanned == length(path) || return nothing
    to
end

# Records `bound` as a name for the project module `path` names whole; a rename of anything else binds no module.
function add_alias!(aliases, modules::ModuleNames, scope, dots, path, bound)
    isnothing(bound) && return
    to = whole_module(modules, scope, dots, path)
    isnothing(to) && return
    aliases[bound] = to
end

# The module renames one using/import clause makes: `import A.B as C` binds C, `using A: b as c` binds c to A.b.
function clause_aliases!(aliases, modules::ModuleNames, scope, clause)
    kind = JS.kind(clause)
    if kind == K"as"
        whole = renamed_parts(clause)
        add_alias!(aliases, modules, scope, whole.dots, whole.path, whole.bound)
        return
    end
    kind == K":" || return
    children = child_nodes(clause)
    dots, base = importpath_parts(first(children))
    for item in children[2:end]
        JS.kind(item) == K"as" || continue
        listed = renamed_parts(item)
        path = [base; listed.path]
        add_alias!(aliases, modules, scope, dots, path, listed.bound)
    end
end

# Each using or import clause in one module's code, with its line's keyword kind. Julia takes using and import
# lines only outside method bodies and quoted code, so the walk leaves those out.
function each_clause(visit, node)
    kind = JS.kind(node)
    if kind == K"using" || kind == K"import"
        for clause in child_nodes(node)
            visit(clause, kind)
        end
        return
    end
    kind == K"quote" && return
    is_method_form(node) && return
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        each_clause(visit, child)
    end
end

# The module renames one module's code makes.
function code_aliases!(aliases, modules::ModuleNames, scope, node)
    each_clause((clause, _) -> clause_aliases!(aliases, modules, scope, clause), node)
    aliases
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

function clause_source(item)
    JS.kind(item) == K"as" || return item
    first(child_nodes(item))
end

# One using/import clause: the project module its path names and the names it binds from there. A path with
# no leading dot names an outside package, unless it opens with the package's own name.
function clause_ref!(refs, from, scope, file, line, modules, clause, via)
    kind = JS.kind(clause)
    if kind == K"as"
        source = first(child_nodes(clause))
        return clause_ref!(refs, from, scope, file, line, modules, source, via)
    end
    path_node = clause
    listed = Symbol[]
    if kind == K":"
        children = child_nodes(clause)
        path_node = first(children)
        for item in children[2:end]
            source = clause_source(item)
            _, item_names = importpath_parts(source)
            append!(listed, item_names)
        end
    end
    JS.kind(path_node) == K"importpath" || return
    dots, path = importpath_parts(path_node)
    isempty(path) && return
    dots == 0 && first(path) !== modules.root && return
    to, spanned = resolve_module(modules, scope, path, dots)
    (isnothing(to) || to == from) && return
    tail = path[(spanned + 1):end]
    names = [tail; listed]
    push!(refs, ModRef(from, to, file, line, via, names))
end

# A dotted name reaching a project module: the reference, with the first name past the module path.
function qualified_ref(from, scope, file, line, modules, path, via)
    to, spanned = resolve_qualifier(modules, from, scope, path)
    (isnothing(to) || to == from) && return nothing
    last_index = min(spanned + 1, length(path))
    reached = path[(spanned + 1):last_index]
    ModRef(from, to, file, line, via, reached)
end

# A signature's parts other than the method name: arguments, `where` bounds, return type.
function walk_signature_rest!(refs, from, scope, file, modules, sig)
    children = child_nodes(sig)
    isnothing(children) && return
    if JS.kind(sig) != K"call"
        walk_signature_rest!(refs, from, scope, file, modules, children[1])
    end
    for child in children[2:end]
        walk_modrefs!(refs, from, scope, file, modules, child)
    end
end

# A method whose name is qualified by a project module extends that module's function.
function extension_ref(from, scope, file, line, modules, node)
    head = first(child_nodes(node))
    call = signature_call(head)
    isnothing(call) && return nothing
    callee = first(child_nodes(call))
    path = dotted_names(callee)
    isnothing(path) && return nothing
    length(path) < 2 && return nothing
    qualified_ref(from, scope, file, line, modules, path, :extends)
end

function walk_import!(refs, from, scope, file, modules, node, children)
    kind = JS.kind(node)
    via = Symbol(string(kind))
    line = JS.source_location(node)[1]
    for clause in children
        clause_ref!(refs, from, scope, file, line, modules, clause, via)
    end
end

# Records a qualified reference and reports whether the node was a pure dotted name.
function walk_dotted_ref!(refs, from, scope, file, line, modules, node)
    path = dotted_names(node)
    isnothing(path) && return false
    ref = qualified_ref(from, scope, file, line, modules, path, :qualified)
    isnothing(ref) || push!(refs, ref)
    true
end

# Records an extension and walks the rest of the method. False when the name stays in this module.
function walk_extension!(refs, from, scope, file, line, modules, node, children)
    extension = extension_ref(from, scope, file, line, modules, node)
    isnothing(extension) && return false
    push!(refs, extension)
    walk_signature_rest!(refs, from, scope, file, modules, children[1])
    for child in children[2:end]
        walk_modrefs!(refs, from, scope, file, modules, child)
    end
    true
end

# `scope` is `from` split into its dotted segments, the frame every name in the file resolves in.
function walk_modrefs!(refs, from, scope, file, modules, node)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    line = JS.source_location(node)[1]
    if kind == K"using" || kind == K"import"
        walk_import!(refs, from, scope, file, modules, node, children)
        return
    end
    if kind == K"."
        walk_dotted_ref!(refs, from, scope, file, line, modules, node) && return
    end
    if is_method_form(node)
        walk_extension!(refs, from, scope, file, line, modules, node, children) && return
    end
    for child in children
        walk_modrefs!(refs, from, scope, file, modules, child)
    end
end

# The loaded modules a reference resolves against, and the outside ones whose internals the package reads on purpose.
struct ReachModules
    by_key::Dict{Symbol,Module}   # each package module by its dotted key
    tracked::Set{Module}          # the package's own modules, which a finding names by key
    package::Module               # the package root, which an entry script knows by its name
    allowed::Set{Module}          # outside modules whose internal names the package reads on purpose
    top::Dict{Symbol,Module}      # each loaded top-level module by name, where a path with no leading dot opens
end


# Where an import path opens, and the names after its opening. With no leading dot it opens at the loaded top-level
# module its first name names; with dots, at the module its first name binds in `home` or a parent per further dot.
function path_opening(modules::ReachModules, home, dots::Int, path::Vector{Symbol})
    rest = path[2:end]
    if dots == 0
        opened = get(modules.top, first(path), nothing)
        return opened, rest
    end
    isnothing(home) && return nothing, rest
    enclosing = home
    for _ in 2:dots
        enclosing = parentmodule(enclosing)
    end
    opened = bound_module(enclosing, first(path))
    isnothing(opened) && return enclosing, path   # a name such as `..f`, read through the enclosing module
    opened, rest
end

# What an import path reads from `home`: each name after its opening, through the module before it, and the module
# the path names whole, if it does; nothing when the path opens at no loaded module.
function path_target(modules::ReachModules, home, dots, path)
    isempty(path) && return nothing
    current, rest = path_opening(modules, home, dots, path)
    isnothing(current) && return nothing
    reads = Tuple{Module,Symbol}[]
    for name in rest
        push!(reads, (current, name))
        member = bound_module(current, name)
        isnothing(member) && return (; reads, named = nothing)
        current = member
    end
    (; reads, named = current)
end

# The modules an entry script binds by name. A script runs where the package is loaded, so it knows the package by
# its name; every other name comes from its own using, import and `const` lines.
struct ScriptNames
    bound::Dict{Symbol,Module}   # name -> the loaded module it binds
    used::Vector{Module}         # modules a `using` line brings in whole, whose exported modules the script sees
    home::Union{Nothing,Module}  # the loaded module a script's module block stands for; nothing at a file's top level
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

function collect_const_alias!(script::ScriptNames, assignment)
    JS.kind(assignment) == K"=" || return
    sides = child_nodes(assignment)
    child_count(sides) < 2 && return
    alias = node_symbol(sides[1])
    isnothing(alias) && return
    no_locals = Set{Symbol}()
    aliased = resolve_loaded_module(sides[2], script, no_locals)
    isnothing(aliased) && return
    script.bound[alias] = aliased
end

# Each `const` binding of a loaded module, outside quoted code and nested scopes.
function collect_const_aliases!(script::ScriptNames, node)
    kind = JS.kind(node)
    kind == K"quote" && return
    is_nested_scope(node) && return
    children = child_nodes(node)
    isnothing(children) && return
    if kind == K"const"
        for declaration in children
            collect_const_alias!(script, declaration)
        end
        return
    end
    for child in children
        collect_const_aliases!(script, child)
    end
end

# The loaded module an entry script's import path names whole; nothing for a path to a name inside a module.
function script_path_module(modules::ReachModules, path_node)
    dots, path = importpath_parts(path_node)
    target = path_target(modules, nothing, dots, path)
    isnothing(target) && return nothing
    target.named
end

# A listed name's path in a `:` clause and the name it binds in the script: itself, or the name after its `as`.
function listed_source_binding(item)
    if JS.kind(item) == K"as"
        renamed = renamed_parts(item)
        return renamed.path, renamed.bound
    end
    _, path = importpath_parts(item)
    bound = length(path) == 1 ? only(path) : nothing
    path, bound
end

# The modules one clause binds in a script: a path naming a module whole binds its last name, or the name after
# `as`, and `using` it brings its exports; a listed name binds when it names a module.
function script_clause!(script::ScriptNames, modules::ReachModules, clause, line_kind)
    kind = JS.kind(clause)
    if kind == K"as"
        renamed = renamed_parts(clause)
        target = path_target(modules, nothing, renamed.dots, renamed.path)
        isnothing(target) && return
        named = target.named
        isnothing(named) && return
        isnothing(renamed.bound) && return
        script.bound[renamed.bound] = named
        return
    end
    if kind == K"importpath"
        loaded = script_path_module(modules, clause)
        isnothing(loaded) && return
        _, path = importpath_parts(clause)
        script.bound[last(path)] = loaded
        if line_kind == K"using"
            push!(script.used, loaded)
        end
        return
    end
    kind == K":" || return
    children = child_nodes(clause)
    base = script_path_module(modules, first(children))
    isnothing(base) && return
    for item in children[2:end]
        path, bound = listed_source_binding(item)
        length(path) == 1 || continue
        isnothing(bound) && continue
        member = bound_module(base, only(path))
        if !isnothing(member)
            script.bound[bound] = member
        end
    end
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

# The modules a script binds by name: Core and Base, as every module does, the package, and its own clauses.
function script_names(tree, modules::ReachModules, home)
    package = modules.package
    bound = Dict{Symbol,Module}(:Core => Core, :Base => Base)
    bound[nameof(package)] = package
    script = ScriptNames(bound, Module[], home)
    each_clause((clause, line_kind) -> script_clause!(script, modules, clause, line_kind), tree)
    collect_const_aliases!(script, tree)
    script
end

