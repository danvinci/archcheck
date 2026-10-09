# Source index: one parse of each module-owned file, with its rank, scan and cross-module references.

struct ModuleGraph
    rank::Dict{Symbol,Vector{Int}}  # module -> package-spine position, then its place in each enclosing wrapper's include order
    dir2mod::Dict{String,Symbol}    # src subdir -> module, nested modules by dotted key
    refs::Vector{ModRef}            # every cross-module reference in src/
end

# One module's code in one source file: a whole file, or a module block inside one, which shares its path.
# (modrank, filerank) is the layer coordinate the rank checks compare.
struct FileNode
    mod::Symbol       # owning module
    path::String      # repo-relative path
    name::String      # basename
    modrank::Vector{Int}   # module rank: package-spine position, then its place in each enclosing module
    filerank::Int     # file position in the wrapper's depth-first include order; 0 when nothing includes it
    iswrapper::Bool   # this module's entry: its directory's entry file, or its module block
    scan::FileScan    # this code's defs and the names each references
    tree::JS.SyntaxNode   # this code from the file's one parse, kept so no check reads the file again
end

# src/ and the entry dirs. Every check reads a slice; nothing re-walks the tree.
struct SourceIndex
    repo::String                            # the root every path below is relative to
    rank::Dict{Symbol,Vector{Int}}          # module, nested ones by dotted key -> package-spine position, then wrapper positions
    dir2mod::Dict{String,Symbol}            # src subdir -> module
    files::Vector{FileNode}                 # every module-owned source file
    refs::Vector{ModRef}                    # cross-module references, from the same parse
    external::Set{Symbol}                   # names referenced from entry dirs other than test/
    unparsed::Vector{Tuple{Symbol,String}}  # (owner, path) of files no check could read; :Entry = an entry dir
    missing::Vector{Tuple{Symbol,String,String,Int}}  # include of a file that is not on disk: owner, includer, spec, line
    nonliteral::Vector{Tuple{Symbol,String,Int}}      # include whose argument is not a string literal: owner, file, line
end

# The wrapper is the one file its module leaves out of the include order, so it stays unranked.
is_wrapper(file::FileNode) = file.iswrapper

# The collections an index build fills. Steps below take this value and write the slice they own.
struct IndexBuild
    repo::String                                              # root every path below is relative to
    src_root::String                                          # absolute src/ being indexed
    root::Symbol                                              # package name, the root module's key
    ranks::Dict{Symbol,Vector{Int}}                           # module -> spine position, then enclosing positions
    dir2mod::Dict{String,Symbol}                              # src subdir -> module, nested by dotted key
    franks::Dict{Symbol,Dict{String,Int}}                     # module -> file path in the module -> include position
    wrappers::Dict{Symbol,String}                             # module -> its entry file
    moddirs::Dict{Symbol,String}                              # module -> directory its file ranks are keyed against
    nodes::Vector{FileNode}                                   # files accepted into the index
    refs::Vector{ModRef}                                      # cross-module references from the same parse
    unparsed::Vector{Tuple{Symbol,String}}                    # owner and path of a file the parse rejected
    missing::Vector{Tuple{Symbol,String,String,Int}}          # include of a file absent on disk: owner, includer, spec, line
    nonliteral::Vector{Tuple{Symbol,String,Int}}              # include whose argument is an expression: owner, file, line
    indexed::Set{Tuple{Symbol,String}}                        # owner and absolute path already accepted
    visited::Set{String}                                      # absolute paths the walk already accepted or rejected
    external::Set{Symbol}                                     # names referenced from entry dirs other than test/
end

# Git-tracked members of `dir`, as absolute normalized paths: the shipped corpus. `nothing` when
# `dir` sits outside any git work tree, so a synthetic test corpus skips filtering and keeps every file.
function tracked_files(dir::AbstractString)
    cmd = Cmd(`git ls-files`; dir = dir)
    buf = IOBuffer()
    piped = pipeline(cmd; stdout = buf, stderr = devnull)
    ok = success(piped)
    ok || return nothing
    text = String(take!(buf))
    lines = split(text, '\n')
    found = Set{String}()
    for line in lines
        isempty(line) && continue
        joined = joinpath(dir, line)
        push!(found, normpath(joined))
    end
    found
end

function nested_dirs(build::IndexBuild, mod, moddir)
    inner = String[]
    for (other_dir, other) in build.dir2mod
        other === mod && continue
        other_path = joinpath(build.src_root, other_dir)
        if is_within(other_path, moddir)
            push!(inner, other_path)
        end
    end
    inner
end

function rank_module!(build::IndexBuild, mod, moddir, entry)
    build.moddirs[mod] = moddir
    if isnothing(entry)
        build.franks[mod] = Dict{String,Int}()
        return
    end
    inner = nested_dirs(build, mod, moddir)
    build.franks[mod] = file_rank(entry, moddir; nested = inner)
    build.wrappers[mod] = entry
end

# File ranks and entry files for every module. The root's directory is src/ and its entry the spine, so it owns
# each file the spine includes outside a module directory.
function rank_modules!(build::IndexBuild)
    for (dir, mod) in build.dir2mod
        mod === build.root && continue
        moddir = joinpath(build.src_root, dir)
        entry = wrapper_of(moddir)
        rank_module!(build, mod, moddir, entry)
    end
    spine_name = string(build.root) * ".jl"
    spine = joinpath(build.src_root, spine_name)
    entry = isfile(spine) ? spine : nothing
    rank_module!(build, build.root, build.src_root, entry)
    build
end

function start_index(src_root::AbstractString, rank, dir2mod, root)
    rooted = abspath(src_root)
    repo = dirname(rooted)
    ranks, dirs = nest_modules(rooted, rank, dir2mod)
    build = IndexBuild(
        repo,
        rooted,
        root,
        ranks,
        dirs,
        Dict{Symbol,Dict{String,Int}}(),
        Dict{Symbol,String}(),
        Dict{Symbol,String}(),
        FileNode[],
        ModRef[],
        Tuple{Symbol,String}[],
        Tuple{Symbol,String,String,Int}[],
        Tuple{Symbol,String,Int}[],
        Set{Tuple{Symbol,String}}(),
        Set{String}(),
        Set{Symbol}(),
    )
    rank_modules!(build)
end

function note_includes!(build::IndexBuild, owner::Symbol, path, rel, tree)
    for (arg, line) in include_calls(tree)
        spec = static_string(arg)
        if isnothing(spec)
            push!(build.nonliteral, (owner, rel, line))
        else
            parent = dirname(path)
            joined = joinpath(parent, spec)
            target = normpath(joined)
            if !isfile(target)
                push!(build.missing, (owner, rel, spec, line))
            end
        end
    end
end

function file_node(owner, rel, modrank, filerank, iswrapper, code)
    name = basename(rel)
    scan = scan_tree(code)
    FileNode(owner, rel, name, modrank, filerank, iswrapper, scan, code)
end

# An inline module is keyed by its dotted path below the package, as a directory module is.
function inline_key(build::IndexBuild, owner::Symbol, name::Symbol)
    owner === build.root && return name
    Symbol(owner, ".", name)
end

# A node joins the index with the module blocks its code holds. Only loaded code holds them: a module's entry or a
# file its module includes. A block ranks inside its module at its file's include position.
function add_node!(build::IndexBuild, node::FileNode, full)
    push!(build.nodes, node)
    note_includes!(build, node.mod, full, node.path, node.tree)
    is_loaded = node.iswrapper || node.filerank > 0
    is_loaded || return
    for block in module_blocks(node.tree)
        name = module_name(block)
        isnothing(name) && continue
        key = inline_key(build, node.mod, name)
        rank = [node.modrank; node.filerank]
        build.ranks[key] = rank
        body = module_body(block)
        inline = file_node(key, node.path, rank, 0, true, body)
        add_node!(build, inline, full)
    end
end

function index_file!(build::IndexBuild, owner::Symbol, path::AbstractString)
    full = normpath(path)
    key = (owner, full)
    key in build.indexed && return
    push!(build.indexed, key)
    push!(build.visited, full)
    rel = relpath(full, build.repo)
    source = read(full, String)
    tree = parse_file(source, rel)
    if isnothing(tree)
        push!(build.unparsed, (owner, rel))
        return
    end
    entry = get(build.wrappers, owner, nothing)
    iswrapper = !isnothing(entry) && normpath(entry) == full
    code = iswrapper ? entry_code(tree) : tree
    moddir = build.moddirs[owner]
    inmod = relpath(full, moddir)
    order = build.franks[owner]
    filerank = get(order, inmod, 0)
    modrank = module_rank_of(owner, build.ranks, build.root)
    node = file_node(owner, rel, modrank, filerank, iswrapper, code)
    add_node!(build, node, full)
end

# Module references resolve once every module is known, the inline ones included.
function add_refs!(build::IndexBuild)
    known = Set(keys(build.ranks))
    modules = ModuleNames(known, build.root)
    for node in build.nodes
        scope = key_segments(node.mod)
        walk_modrefs!(build.refs, node.mod, scope, node.path, modules, node.tree)
    end
end

# Ranked includes are module-owned even when they sit outside the mapped directory or git tree.
function add_ranked_files!(build::IndexBuild)
    for (mod, order) in build.franks
        moddir = build.moddirs[mod]
        for rel in keys(order)
            joined = joinpath(moddir, rel)
            target = normpath(joined)
            isfile(target) || continue
            index_file!(build, mod, target)
        end
        entry = get(build.wrappers, mod, nothing)
        if !isnothing(entry) && isfile(entry)
            index_file!(build, mod, entry)
        end
    end
end

# A file's top level and the body of every module block it holds, at any depth.
function code_roots(tree)
    roots = JS.SyntaxNode[tree]
    for block in module_blocks(tree)
        body = module_body(block)
        inner = code_roots(body)
        append!(roots, inner)
    end
    roots
end

function note_unowned_includes!(build::IndexBuild, path, name)
    rel = relpath(path, build.repo)
    source = read(path, String)
    tree = parse_file(source, rel)
    isnothing(tree) && return
    stem = first(splitext(name))
    owner = Symbol(stem)
    for root in code_roots(tree)
        note_includes!(build, owner, path, rel, root)
    end
end

function add_loose_files!(build::IndexBuild)
    tracked = tracked_files(build.src_root)
    for (dir, _, names) in walkdir(build.src_root), name in names
        endswith(name, ".jl") || continue
        path = joinpath(dir, name)
        full = normpath(path)
        full in build.visited && continue
        if !isnothing(tracked) && !(full in tracked)
            continue
        end
        owner = module_of(path, build.src_root, build.dir2mod)
        if isnothing(owner)
            note_unowned_includes!(build, path, name)
            continue
        end
        index_file!(build, owner, full)
    end
end

# Entry dirs stay unloaded. A parse failure here shrinks `external`, so a def used only from a script
# looks like dead code.
function read_entry_dir!(build::IndexBuild, dir)
    for (folder, _, names) in walkdir(dir), name in names
        endswith(name, ".jl") || continue
        path = joinpath(folder, name)
        rel = relpath(path, build.repo)
        source = read(path, String)
        tree = parse_file(source, rel)
        if isnothing(tree)
            push!(build.unparsed, (:Entry, rel))
            continue
        end
        for root in code_roots(tree)
            all_symbols!(build.external, root)
        end
    end
end

function read_entry_dirs!(build::IndexBuild, entry_dirs)
    for dir in entry_dirs
        isdir(dir) || continue
        base = basename(normpath(dir))
        base == "test" && continue
        read_entry_dir!(build, dir)
    end
end

function source_index(build::IndexBuild)
    SourceIndex(
        build.repo,
        build.ranks,
        build.dir2mod,
        build.nodes,
        build.refs,
        build.external,
        build.unparsed,
        build.missing,
        build.nonliteral,
    )
end

function build_source_index(src_root::AbstractString, rank, dir2mod; entry_dirs = String[], root::Symbol)
    build = start_index(src_root, rank, dir2mod, root)
    add_ranked_files!(build)
    add_loose_files!(build)
    add_refs!(build)
    read_entry_dirs!(build, entry_dirs)
    source_index(build)
end

build_module_graph(index::SourceIndex) = ModuleGraph(index.rank, index.dir2mod, index.refs)

# Names written anywhere but as a callee: stored, passed, returned, exported, or read by an entry script. A function
# called through a value unknown at its call site was written as one of these.
function value_names(index::SourceIndex)
    names = Set{Symbol}()
    for file in index.files
        callees = Base.IdSet{JS.SyntaxNode}()
        for node in walk_nodes(file.tree)
            kind = JS.kind(node)
            (kind == K"call" || kind == K"dotcall") || continue
            callee = callee_node(node)
            isnothing(callee) || push!(callees, callee)
        end
        for node in walk_nodes(file.tree)
            node in callees && continue
            name = node_symbol(node)
            isnothing(name) || push!(names, name)
        end
    end
    union!(names, index.external)
end

files_of(index::SourceIndex, mod::Symbol) = [file for file in index.files if file.mod === mod]

function line_span(node)
    first_line = source_line(node)
    source = JS.sourcefile(node)
    end_byte = JS.last_byte(node)
    location = JS.source_location(source, end_byte)
    first_line:Int(location[1])
end

# The indexed node holding a line of a repo-relative path: the innermost module block around it, else the file.
# Nothing for a line the index does not hold.
function indexed_file(index::SourceIndex, path::AbstractString, line::Integer)
    found = nothing
    narrowest = typemax(Int)
    for file in index.files
        file.path == path || continue
        span = line_span(file.tree)
        line in span || continue
        length(span) < narrowest || continue
        found = file
        narrowest = length(span)
    end
    found
end

# Where each def lives. One owner of a finding's location, so every check reports the same form.
function def_sites(index::SourceIndex)
    sites = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()
    for file in index.files
        for (name, line) in file.scan.line
            sites[(file.mod, name)] = (file.path, line)
        end
    end
    sites
end

site_of(sites, mod, name, fallback) = get(sites, (mod, Symbol(name)), fallback)
