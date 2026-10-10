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

# The loaded module a dotted key names below the package; nothing when the package did not load it, as for a file
# included under a version check that fails on this Julia.
function loaded_module(pkg::Module, key::Symbol)::Union{Nothing,Module}
    found = pkg
    for segment in key_segments(key)
        isdefined(found, segment) || return nothing
        found = getfield(found, segment)
    end
    found
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
function resolve_module(modules::ModuleNames, scope, path, dots)
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

# One name of an import path: an identifier, or a macro's name with its `@` as Julia binds it.
function importpath_name(child)::Union{Nothing,Symbol}
    JS.kind(child) == K"macro_name" || return node_symbol(child)
    inner = first(child_nodes(child))
    Symbol("@", inner.val)
end

# Leading-dot count and names of an import path: `..A.B` -> (2, [:A, :B]).
function importpath_parts(path)
    dots = 0
    names = Symbol[]
    children = child_nodes(path)
    isnothing(children) && return dots, names
    for child in children
        name = importpath_name(child)
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

# Records `bound` as a name for the project module `path` names whole; a rename of anything else binds no module.
function add_alias!(aliases, modules::ModuleNames, scope, dots, path, bound)
    isnothing(bound) && return
    isempty(path) && return
    dots == 0 && first(path) !== modules.root && return
    to, spanned = resolve_module(modules, scope, path, dots)
    isnothing(to) && return
    spanned == length(path) || return
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

# The module renames one module's code makes. Julia takes using and import lines only outside method bodies and
# quoted code, so the walk leaves those out.
function code_aliases!(aliases, modules::ModuleNames, scope, node)
    kind = JS.kind(node)
    if kind == K"using" || kind == K"import"
        for clause in child_nodes(node)
            clause_aliases!(aliases, modules, scope, clause)
        end
        return aliases
    end
    kind == K"quote" && return aliases
    is_method_form(node) && return aliases
    children = child_nodes(node)
    isnothing(children) && return aliases
    for child in children
        code_aliases!(aliases, modules, scope, child)
    end
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
