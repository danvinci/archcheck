# Module references: import clauses and qualified paths, resolved against the package's modules.

struct ModRef
    from::Symbol          # module the reference is written in
    to::Symbol            # module the reference reaches
    file::String          # repo-relative path
    line::Int             # source line of the reference
    via::Symbol           # :using | :import | :qualified | :extends (a method on `to`'s function)
    names::Vector{Symbol} # names reached in `to`: an import list, or the name after a qualified path; empty for a whole module
end
ModRef(from, to, file, line, via) = ModRef(from, to, file, line, via, Symbol[])

# A module's dotted key from the package root, split: `Outer.Inner` -> [:Outer, :Inner].
function key_segments(key::Symbol)
    text = string(key)
    parts = split(text, '.')
    Symbol.(parts)
end

# The loaded module a dotted key names below the package.
function loaded_module(pkg::Module, key::Symbol)
    found = pkg
    for segment in key_segments(key)
        found = getfield(found, segment)
    end
    found
end

# The names module paths resolve against.
struct ModuleNames
    known::Set{Symbol}          # every project module, by dotted key below the package
    root::Union{Symbol,Nothing} # the package's own name, which a path may open with; nothing when unknown
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
    known = modules.known
    opening = resolve_opening(scope, dots)
    for depth in opening:-1:0
        if depth == 0 && first(path) === modules.root   # the package itself; its modules sit below it
            length(path) == 1 && return modules.root, 1
            inner, spanned = resolve_module(modules, Symbol[], path[2:end], 1)
            isnothing(inner) && return modules.root, 1
            return inner, spanned + 1
        end
        segments = [scope[1:depth]; path[1]]
        key = Symbol(join(segments, "."))
        key in known || continue
        spanned = 1
        while spanned < length(path)
            deeper = Symbol(key, ".", path[spanned + 1])
            deeper in known || break
            key = deeper
            spanned += 1
        end
        return key, spanned
    end
    nothing, 0
end

# Leading-dot count and names of an import path: `..A.B` -> (2, [:A, :B]).
function importpath_parts(path)
    dots = 0
    names = Symbol[]
    kids = child_nodes(path)
    isnothing(kids) && return dots, names
    for child in kids
        child.val isa Symbol || continue
        if child.val === :. && isempty(names)
            dots += 1
        else
            push!(names, child.val)
        end
    end
    dots, names
end

# The identifiers of a pure dotted name, `A.B.c` -> [:A, :B, :c]; nothing when any part is an expression.
function dotted_names(node)
    node.val isa Symbol && return [node.val]
    JS.kind(node) == K"." || return nothing
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) != 2) && return nothing
    head = dotted_names(kids[1])
    member = kids[2].val
    (isnothing(head) || !(member isa Symbol)) && return nothing
    push!(head, member)
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
        kids = child_nodes(clause)
        path_node = first(kids)
        for item in kids[2:end]
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
    to, spanned = resolve_module(modules, scope, path, 1)
    (isnothing(to) || to == from) && return nothing
    last_index = min(spanned + 1, length(path))
    reached = path[(spanned + 1):last_index]
    ModRef(from, to, file, line, via, reached)
end

# A signature's parts other than the method name: arguments, `where` bounds, return type.
function walk_signature_rest!(refs, from, scope, file, modules, sig)
    kids = child_nodes(sig)
    isnothing(kids) && return
    if JS.kind(sig) != K"call"
        walk_signature_rest!(refs, from, scope, file, modules, kids[1])
    end
    for child in kids[2:end]
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
    (isnothing(path) || length(path) < 2) && return nothing
    qualified_ref(from, scope, file, line, modules, path, :extends)
end

function walk_import!(refs, from, scope, file, modules, node, kids)
    kind = JS.kind(node)
    via = Symbol(string(kind))
    line = JS.source_location(node)[1]
    for clause in kids
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
function walk_extension!(refs, from, scope, file, line, modules, node, kids)
    extension = extension_ref(from, scope, file, line, modules, node)
    isnothing(extension) && return false
    push!(refs, extension)
    walk_signature_rest!(refs, from, scope, file, modules, kids[1])
    for child in kids[2:end]
        walk_modrefs!(refs, from, scope, file, modules, child)
    end
    true
end

# `scope` is `from` split into its dotted segments, the frame every name in the file resolves in.
function walk_modrefs!(refs, from, scope, file, modules, node)
    kids = child_nodes(node)
    isnothing(kids) && return
    kind = JS.kind(node)
    line = JS.source_location(node)[1]
    if kind == K"using" || kind == K"import"
        walk_import!(refs, from, scope, file, modules, node, kids)
        return
    end
    if kind == K"."
        walk_dotted_ref!(refs, from, scope, file, line, modules, node) && return
    end
    if is_method_form(node)
        walk_extension!(refs, from, scope, file, line, modules, node, kids) && return
    end
    for child in kids
        walk_modrefs!(refs, from, scope, file, modules, child)
    end
end

function scan_modrefs(src::AbstractString, from, file, known; root = nothing)
    refs = ModRef[]
    tree = parse_file(src, file)
    isnothing(tree) && return refs
    known_set = Set{Symbol}(known)
    modules = ModuleNames(known_set, root)
    scope = key_segments(from)
    walk_modrefs!(refs, from, scope, file, modules, tree)
    refs
end
