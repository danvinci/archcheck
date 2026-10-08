# Shared source index: module references, include-order ranks and definition sites.
struct ModRef
    from::Symbol
    to::Symbol
    file::String     # repo-relative
    line::Int
    via::Symbol      # :using | :import | :qualified | :extends (a method on `to`'s function)
    names::Vector{Symbol}   # names reached in `to`: an import list, or the name after a qualified path; empty for a whole module
end
ModRef(from, to, file, line, via) = ModRef(from, to, file, line, via, Symbol[])

struct ModuleGraph
    rank::Dict{Symbol,Vector{Int}}  # module -> package-spine position, then its place in each enclosing wrapper's include order
    dir2mod::Dict{String,Symbol}    # src subdir -> module, nested modules by dotted key
    refs::Vector{ModRef}            # every cross-module reference in src/
end

# A module's dotted key from the package root, split: `Geometry.Meshes` -> [:Geometry, :Meshes].
key_segments(key::Symbol) = Symbol.(split(string(key), '.'))

# Whether `path` lies inside directory `dir`.
function is_within(path, dir)
    relative = relpath(path, dir)
    relative != ".." && !startswith(relative, "../")
end

# An entry file's include order - the rank source at both zooms: the package spine ranks modules,
# <Domain>.jl ranks files.
function include_stmts(entry_path::AbstractString)
    stmts = Tuple{String,Int}[]
    source = read(entry_path, String)
    tree = parse_file(source, entry_path)
    isnothing(tree) && return stmts
    walk_include_calls!(tree) do arg, line
        spec = static_string(arg)
        isnothing(spec) && return
        push!(stmts, (spec, line))
    end
    stmts
end

include_paths(entry_path::AbstractString) = [spec for (spec, _) in include_stmts(entry_path)]

function static_string(n)
    JS.kind(n) == K"string" || return nothing
    kids = child_nodes(n)
    kids === nothing && return nothing
    parts = String[]
    for c in kids
        JS.kind(c) == K"String" || return nothing
        push!(parts, string(c.val))
    end
    join(parts)
end

function walk_include_calls!(visit, n)
    kids = child_nodes(n)
    if JS.kind(n) == K"call" && kids !== nothing && !isempty(kids) && kids[1].val === :include
        args = [c for c in kids[2:end] if JS.kind(c) != K"parameters"]
        if !isempty(args)
            visit(args[1], Int(JS.source_location(n)[1]))
        end
    end
    kids === nothing && return
    for c in kids
        walk_include_calls!(visit, c)
    end
end

# The package spine's include order is the declared module DAG; it gives both rank and dir->module.
# The module name comes from the paired `using .Name`, not the filename, which need not match it.
function parse_spine_order(spine_path::AbstractString)
    # Comments stripped and `;`-joined statements split, so same-line and two-line forms parse alike.
    stmts = String[]
    for line in eachline(spine_path)
        code = first(split(line, '#'; limit = 2))
        for part in split(code, ';')
            statement = strip(part)
            isempty(statement) || push!(stmts, statement)
        end
    end
    rank = Dict{Symbol,Int}()
    dir2mod = Dict{String,Symbol}()
    position = 0
    for (i, statement) in enumerate(stmts)
        inc = match(r"^include\(\"([^\"]+)\"\)$", statement)
        isnothing(inc) && continue
        position += 1
        i == length(stmts) && continue
        using_line = match(r"^using\s+\.([A-Za-z_][A-Za-z0-9_]*)\b", stmts[i + 1])
        isnothing(using_line) && continue
        dir = dirname(inc.captures[1])
        isempty(dir) && continue
        modname = Symbol(using_line.captures[1])
        rank[modname] = position
        dir2mod[dir] = modname
    end
    rank, dir2mod
end

# The directory key of a single-module package: src/ itself.
const SINGLE_MODULE_DIR = "."

# The package's modules and their directories. A spine that declares no module (no `include` followed by
# `using .X`) makes the package one module: the root, keyed by its own name, owning src/ and ranked by the spine.
function package_layout(spine_path::AbstractString, root::Symbol)
    rank, dir2mod = parse_spine_order(spine_path)
    isempty(rank) || return rank, dir2mod
    Dict(root => 1), Dict(SINGLE_MODULE_DIR => root)
end

# Each wrapper declares its nested modules by the package spine's rule. A nested module is keyed by its dotted
# path; its rank is its parent's plus its position in the parent wrapper's include order.
function nest_modules(src_root, rank, dir2mod)
    ranks = Dict{Symbol,Vector{Int}}(mod => [position] for (mod, position) in rank)
    dirs = copy(dir2mod)
    pending = collect(dir2mod)
    while !isempty(pending)   # bounded: a directory enters `dirs`, and so the queue, once
        dir, mod = pop!(pending)
        haskey(ranks, mod) || continue
        wrapper = wrapper_of(joinpath(src_root, dir))
        isnothing(wrapper) && continue
        positions, children = parse_spine_order(wrapper)
        for (child_dir, child) in children
            nested_dir = normpath(joinpath(dir, child_dir))
            haskey(dirs, nested_dir) && continue
            key = Symbol(mod, ".", child)
            ranks[key] = [ranks[mod]; positions[child]]
            dirs[nested_dir] = key
            push!(pending, nested_dir => key)
        end
    end
    ranks, dirs
end

# The module dir's entry file: capitalized by convention, and the one candidate no sibling includes.
# Nothing when the dir declares no entry or leaves it ambiguous, which blocks via unranked_file.
function wrapper_of(module_dir::AbstractString)
    isdir(module_dir) || return nothing
    candidates = filter(readdir(module_dir; join = true)) do f
        name = basename(f)
        endswith(name, ".jl") && occursin(r"^[A-Z]", name)
    end
    length(candidates) == 1 && return only(candidates)
    included = Set{String}()
    for candidate in candidates
        for path in include_paths(candidate)
            target = joinpath(module_dir, path)
            push!(included, normpath(target))
        end
    end
    entries = String[]
    for candidate in candidates
        normpath(candidate) in included && continue
        push!(entries, candidate)
    end
    length(entries) == 1 ? only(entries) : nothing
end

function skips_nested(target, nested)
    for dir in nested
        is_within(target, dir) && return true
    end
    false
end

# Depth-first. `position` is how many files are already ranked; the return is the count after `file`.
function rank_includes!(order, module_dir, nested, file, position)
    here = dirname(file)          # an include resolves against its includer, apart from the module root
    for included in include_paths(file)
        joined = joinpath(here, included)
        target = normpath(joined)
        skips_nested(target, nested) && continue   # a nested module ranks its own files
        rel = relpath(target, module_dir)
        haskey(order, rel) && continue     # also the cycle guard: a revisit leaves the walk
        position += 1
        order[rel] = position
        if isfile(target)
            position = rank_includes!(order, module_dir, nested, target, position)
        end
    end
    position
end

# A module wrapper's include order is the declared file DAG within that module: path in module -> position.
# Depth-first, so a nested include takes its position from where its includer reaches it - Julia's load order.
function file_rank(module_dir::AbstractString; nested = String[])
    entry = wrapper_of(module_dir)
    isnothing(entry) && return Dict{String,Int}()
    order = Dict{String,Int}()
    rank_includes!(order, module_dir, nested, entry, 0)
    order
end

# Owning module for a source path: the longest directory prefix dir2mod declares; a nested module resolves to
# itself. Past every prefix, a single-module package's root owns the path.
function module_of(path, src_root, dir2mod)
    parts = splitpath(relpath(path, src_root))
    for depth in (length(parts) - 1):-1:1
        dir = joinpath(parts[1:depth]...)
        haskey(dir2mod, dir) && return dir2mod[dir]
    end
    get(dir2mod, SINGLE_MODULE_DIR, nothing)
end

# The names module paths resolve against.
struct ModuleNames
    known::Set{Symbol}               # every project module, by dotted key below the package
    root::Union{Symbol,Nothing}      # the package's own name, which a path may open with; nothing when unknown
end

# The project module a name path reaches from `scope`, and how many names it spans. One leading dot opens in
# `scope`, each more in its parent; lookup widens to the root, where `using ..Name` bindings point.
function resolve_module(modules::ModuleNames, scope, path, dots)
    known = modules.known
    opening = max(length(scope) - (dots - 1), 0)
    for depth in opening:-1:0
        if depth == 0 && first(path) === modules.root   # the package itself; its modules sit below it
            length(path) == 1 && return modules.root, 1
            inner, spanned = resolve_module(modules, Symbol[], path[2:end], 1)
            return isnothing(inner) ? (modules.root, 1) : (inner, spanned + 1)
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
    kids === nothing && return dots, names
    for c in kids
        c.val isa Symbol || continue
        if c.val === :. && isempty(names)
            dots += 1
        else
            push!(names, c.val)
        end
    end
    dots, names
end

# The identifiers of a pure dotted name, `A.B.c` -> [:A, :B, :c]; nothing when any part is an expression.
function dotted_names(n)
    n.val isa Symbol && return [n.val]
    JS.kind(n) == K"." || return nothing
    kids = child_nodes(n)
    (kids === nothing || length(kids) != 2) && return nothing
    head = dotted_names(kids[1])
    member = kids[2].val
    (isnothing(head) || !(member isa Symbol)) && return nothing
    push!(head, member)
end

# One using/import clause: the project module its path names and the names it binds from there. A path with
# no leading dot names an outside package, unless it opens with the package's own name.
function clause_ref!(refs, from, scope, file, line, modules, clause, via)
    k = JS.kind(clause)
    if k == K"as"
        source = first(child_nodes(clause))
        return clause_ref!(refs, from, scope, file, line, modules, source, via)
    end
    path_node = clause
    listed = Symbol[]
    if k == K":"
        kids = child_nodes(clause)
        path_node = first(kids)
        for item in kids[2:end]
            source = JS.kind(item) == K"as" ? first(child_nodes(item)) : item
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
    push!(refs, ModRef(from, to, file, line, via, [tail; listed]))
end

# A dotted name reaching a project module: the reference, with the first name past the module path.
function qualified_ref(from, scope, file, line, modules, path, via)
    to, spanned = resolve_module(modules, scope, path, 1)
    (isnothing(to) || to == from) && return nothing
    reached = path[(spanned + 1):min(spanned + 1, length(path))]
    ModRef(from, to, file, line, via, reached)
end

# The call inside a signature, past `where` clauses and a return type.
function signature_call(sig)
    while JS.kind(sig) == K"where" || JS.kind(sig) == K"::"
        sig = first(child_nodes(sig))
    end
    JS.kind(sig) == K"call" ? sig : nothing
end

# A signature's parts other than the method name: arguments, `where` bounds, return type.
function walk_signature_rest!(refs, from, scope, file, modules, sig)
    kids = child_nodes(sig)
    kids === nothing && return
    JS.kind(sig) == K"call" || walk_signature_rest!(refs, from, scope, file, modules, kids[1])
    for c in kids[2:end]
        walk_modrefs!(refs, from, scope, file, modules, c)
    end
end

# A method whose name is qualified by a project module extends that module's function.
function extension_ref(from, scope, file, line, modules, n)
    call = signature_call(first(child_nodes(n)))
    isnothing(call) && return nothing
    path = dotted_names(first(child_nodes(call)))
    (isnothing(path) || length(path) < 2) && return nothing
    qualified_ref(from, scope, file, line, modules, path, :extends)
end

# `scope` is `from` split into its dotted segments, the frame every name in the file resolves in.
function walk_modrefs!(refs, from, scope, file, modules, n)
    kids = child_nodes(n)
    kids === nothing && return
    k = JS.kind(n)
    line = JS.source_location(n)[1]
    if k == K"using" || k == K"import"
        via = Symbol(string(k))
        for clause in kids
            clause_ref!(refs, from, scope, file, line, modules, clause, via)
        end
        return
    elseif k == K"."
        path = dotted_names(n)
        if !isnothing(path)
            ref = qualified_ref(from, scope, file, line, modules, path, :qualified)
            isnothing(ref) || push!(refs, ref)
            return
        end
    elseif is_method_form(n)
        extension = extension_ref(from, scope, file, line, modules, n)
        if !isnothing(extension)
            push!(refs, extension)
            walk_signature_rest!(refs, from, scope, file, modules, kids[1])
            for c in kids[2:end]
                walk_modrefs!(refs, from, scope, file, modules, c)
            end
            return
        end
    end
    for c in kids
        walk_modrefs!(refs, from, scope, file, modules, c)
    end
end

function scan_modrefs(src::AbstractString, from, file, known; root = nothing)
    refs = ModRef[]
    tree = parse_file(src, file)
    tree === nothing && return refs
    modules = ModuleNames(Set{Symbol}(known), root)
    walk_modrefs!(refs, from, key_segments(from), file, modules, tree)
    refs
end

# One source file. (modrank, filerank) is the layer coordinate the rank checks compare.
struct FileNode
    mod::Symbol       # owning module
    path::String      # repo-relative path
    name::String      # basename
    modrank::Vector{Int}   # module rank: package-spine position, then its place in each enclosing wrapper
    filerank::Int     # file position in the wrapper's depth-first include order; 0 when nothing includes it
    iswrapper::Bool   # this module's entry file, resolved from its directory rather than by name
    scan::FileScan    # this file's defs and the names each references
    tree::JS.SyntaxNode   # the file's one parse, kept so no check reads the file again
end

# src/ and the entry dirs. Every check reads a slice; nothing re-walks the tree.
struct SourceIndex
    repo::String                            # the root every path below is relative to
    rank::Dict{Symbol,Vector{Int}}          # module, nested ones by dotted key -> package-spine position, then wrapper positions
    dir2mod::Dict{String,Symbol}            # src subdir -> module
    files::Vector{FileNode}                 # every module-owned source file
    refs::Vector{ModRef}                    # cross-module references, from the same parse
    external::Set{Symbol}                   # names referenced from entry dirs other than test/ (scripts/, ...)
    unparsed::Vector{Tuple{Symbol,String}}  # (owner, path) of files no check could read; :Entry = an entry dir
    missing::Vector{Tuple{Symbol,String,String,Int}}  # include of a file that is not on disk: owner, includer, spec, line
    nonliteral::Vector{Tuple{Symbol,String,Int}}      # include whose argument is not a string literal: owner, file, line
end

# The wrapper is the only file its own module never includes, so it is legitimately unranked.
is_wrapper(f::FileNode) = f.iswrapper

# Git-tracked members of `dir`, as absolute normalized paths - the shipped corpus. `nothing` when
# `dir` sits outside any git work tree, so a synthetic test corpus skips filtering instead of losing every file.
function tracked_files(dir::AbstractString)
    cmd = Cmd(`git ls-files`; dir = dir)
    buf = IOBuffer()
    piped = pipeline(cmd; stdout = buf, stderr = devnull)
    ok = success(piped)
    ok || return nothing
    text = String(take!(buf))
    lines = split(text, '\n')
    Set(normpath(joinpath(dir, line)) for line in lines if !isempty(line))
end

function build_source_index(src_root::AbstractString, rank, dir2mod; entry_dirs = String[], root = nothing)
    src_root = abspath(src_root)
    repo = dirname(src_root)
    tracked = tracked_files(src_root)
    ranks, dir2mod = nest_modules(src_root, rank, dir2mod)
    modules = ModuleNames(Set(keys(ranks)), root)
    franks = Dict{Symbol,Dict{String,Int}}()
    wrappers = Dict{Symbol,String}()   # module -> its entry file, the one file the module never includes
    moddirs = Dict{Symbol,String}()    # module -> its directory, the root its file ranks are keyed against
    for (dir, mod) in dir2mod
        moddir = joinpath(src_root, dir)
        moddirs[mod] = moddir
        inner = String[]
        for (other_dir, other) in dir2mod
            other_path = joinpath(src_root, other_dir)
            other !== mod && is_within(other_path, moddir) && push!(inner, other_path)
        end
        franks[mod] = file_rank(moddir; nested = inner)
        entry = wrapper_of(moddir)
        if !isnothing(entry)
            wrappers[mod] = entry
        end
    end
    nodes = FileNode[]
    refs = ModRef[]
    unparsed = Tuple{Symbol,String}[]
    missing = Tuple{Symbol,String,String,Int}[]
    nonliteral = Tuple{Symbol,String,Int}[]
    function collect_includes!(owner, path, rel, tree)
        walk_include_calls!(tree) do arg, line
            spec = static_string(arg)
            if isnothing(spec)
                push!(nonliteral, (owner, rel, line))
            else
                target = normpath(joinpath(dirname(path), spec))
                isfile(target) || push!(missing, (owner, rel, spec, line))
            end
        end
    end
    indexed = Set{Tuple{Symbol,String}}()
    parsed = Set{String}()
    function add_file!(owner, path)
        path = normpath(path)
        (owner, path) in indexed && return
        push!(indexed, (owner, path))
        push!(parsed, path)
        rel = relpath(path, repo)
        source = read(path, String)
        tree = parse_file(source, rel)
        if isnothing(tree)
            push!(unparsed, (owner, rel))
            return
        end
        collect_includes!(owner, path, rel, tree)
        walk_modrefs!(refs, owner, key_segments(owner), rel, modules, tree)
        entry = get(wrappers, owner, nothing)
        iswrapper = !isnothing(entry) && normpath(entry) == path
        inmod = relpath(path, moddirs[owner])
        filerank = get(franks[owner], inmod, 0)
        modrank = get(ranks, owner, Int[])
        name = basename(path)
        scan = scan_tree(tree)
        push!(nodes, FileNode(owner, rel, name, modrank, filerank, iswrapper, scan, tree))
    end
    # Ranked includes are module-owned even when they sit outside the mapped directory or git tree.
    for (mod, order) in franks
        moddir = moddirs[mod]
        for rel in keys(order)
            target = normpath(joinpath(moddir, rel))
            if isfile(target)
                add_file!(mod, target)
            end
        end
        entry = get(wrappers, mod, nothing)
        if !isnothing(entry) && isfile(entry)
            add_file!(mod, entry)
        end
    end
    for (root, _, files) in walkdir(src_root), fn in files
        endswith(fn, ".jl") || continue
        path = joinpath(root, fn)
        abs_path = normpath(path)
        abs_path in parsed && continue
        isnothing(tracked) || abs_path in tracked || continue
        owner = module_of(path, src_root, dir2mod)
        if isnothing(owner)
            rel = relpath(path, repo)
            source = read(path, String)
            tree = parse_file(source, rel)
            isnothing(tree) || collect_includes!(Symbol(first(splitext(fn))), path, rel, tree)
            continue
        end
        add_file!(owner, abs_path)
    end

    # Entry dirs are parsed but never loaded: a parse failure here shrinks `external`, turning defs used
    # only from a script into false dead-code findings.
    external = Set{Symbol}()
    for dir in entry_dirs
        isdir(dir) || continue
        basename(normpath(dir)) == "test" && continue   # nothing production runs reaches a test/ reference
        for (root, _, files) in walkdir(dir), fn in files
            endswith(fn, ".jl") || continue
            path = joinpath(root, fn)
            rel = relpath(path, repo)
            tree = parse_file(read(path, String), rel)
            if tree === nothing
                push!(unparsed, (:Entry, rel))
            else
                all_symbols!(external, tree)
            end
        end
    end
    SourceIndex(repo, ranks, dir2mod, nodes, refs, external, unparsed, missing, nonliteral)
end

build_module_graph(index::SourceIndex) = ModuleGraph(index.rank, index.dir2mod, index.refs)

function build_module_graph(src_root::AbstractString, spine_path::AbstractString)
    rank, dir2mod = parse_spine_order(spine_path)
    build_module_graph(build_source_index(src_root, rank, dir2mod))
end

files_of(index::SourceIndex, mod::Symbol) = [f for f in index.files if f.mod === mod]

# Where each def lives - the one owner of a finding's location, so every check reports the same form.
function def_sites(index::SourceIndex)
    sites = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()
    for f in index.files, (name, line) in f.scan.line
        sites[(f.mod, name)] = (f.path, line)
    end
    sites
end

site_of(sites, mod, name, fallback) = get(sites, (mod, Symbol(name)), fallback)
