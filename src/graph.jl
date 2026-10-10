# Source index: one parse of each module-owned file, with its rank, scan and cross-module references.

struct ModuleGraph
    rank::Dict{Symbol,Vector{Int}}  # module -> its load position in each enclosing module, outermost first
    dir2mod::Dict{String,Symbol}    # src subdir -> module, nested modules by dotted key
    refs::Vector{ModRef}            # every cross-module reference in src/
end

# One module's code in one source file: a whole file, or a module block inside one, which shares its path.
# (modrank, filerank) is the layer coordinate the rank checks compare.
struct FileNode
    mod::Symbol       # owning module
    path::String      # repo-relative path
    name::String      # basename
    modrank::Vector{Int}   # module rank: the package 1, its extensions after, then the place in each enclosing module
    filerank::Int     # load position inside its module; 0 for a module's own code, or for a file nothing loads
    iswrapper::Bool   # this module's entry: its directory's entry file, or its module block
    scan::FileScan    # this code's defs and the names each references
    tree::JS.SyntaxNode   # this code from the file's one parse, kept so no check reads the file again
    bodies::Vector{MethodBody}   # every method this code writes, nested ones included, with the names each binds
end

# One piece of code outside the loaded modules: an entry script, or an extension Julia has not loaded.
struct EntryCode
    path::String          # an entry script's walked path, or an extension file's repo-relative path
    owner::Symbol         # :Entry for an entry script; the extension's name for an unloaded extension
    tree::JS.SyntaxNode   # the code
    scan::FileScan        # what the one walk recorded over it, each qualifier resolved as the code binds it
end

# src/ and the entry dirs. Every check reads a slice; nothing re-walks the tree.
struct SourceIndex
    repo::String                            # the root every path below is relative to
    rank::Dict{Symbol,Vector{Int}}          # module, nested ones by dotted key -> its load position in each enclosing module
    dir2mod::Dict{String,Symbol}            # src subdir -> module
    files::Vector{FileNode}                 # every module-owned source file
    refs::Vector{ModRef}                    # cross-module references, from the same parse
    external::Set{Symbol}                   # names referenced from entry dirs other than test/ and unloaded extensions
    scripts::Vector{EntryCode}              # each code root of the entry-dir files outside src/ and of unloaded extensions
    unparsed::Vector{Tuple{Symbol,String}}  # (owner, path) of files no check could read; :Entry = an entry dir
    missing::Vector{Tuple{Symbol,String,String,Int}}  # include of a file that is not on disk: owner, includer, spec, line
    nonliteral::Vector{Tuple{Symbol,String,Int}}      # include whose argument is not a string literal: owner, file, line
end

# The wrapper is the one file its module leaves out of the include order, so it stays unranked.
is_wrapper(file::FileNode) = file.iswrapper

# One piece of loaded code: a whole file, a directory module's entry, or an inline module's block.
struct Placement
    owner::Symbol                 # module the code belongs to
    path::String                  # absolute path of the file holding it
    position::Int                 # load position inside its module; 0 for the module's own entry code
    code::JS.SyntaxNode           # the code itself: a file's parse, an entry's module body, or a block's body
end

# The collections an index build fills. Steps below take this value and write the slice they own.
struct IndexBuild
    repo::String                                              # root every path below is relative to
    src_root::String                                          # absolute src/ being indexed
    root::Symbol                                              # package name, the root module's key
    package::Module                                           # the loaded package, whose modules qualifiers resolve to
    loaded::Dict{Symbol,Module}                               # each ranked module this Julia loaded, by key
    extensions::Vector{Pair{Symbol,String}}                   # loaded extension -> its absolute entry file
    ranks::Dict{Symbol,Vector{Int}}                           # module -> its load position in each enclosing module
    dir2mod::Dict{String,Symbol}                              # src subdir -> module, nested by dotted key
    openers::Dict{String,Tuple{Symbol,String}}                # a directory module's absolute entry file -> its key, directory
    parses::Parses                                            # every file's one parse, shared with the layout
    placements::Vector{Placement}                             # loaded code in load order
    nodes::Vector{FileNode}                                   # code accepted into the index
    refs::Vector{ModRef}                                      # cross-module references from the same parse
    aliases::Dict{Symbol,Dict{Symbol,Symbol}}                 # module -> each name its `as` clauses bind -> module it names
    unparsed::Vector{Tuple{Symbol,String}}                    # owner and path of a file the parse rejected
    missing::Vector{Tuple{Symbol,String,String,Int}}          # include of a file absent on disk: owner, includer, spec, line
    nonliteral::Vector{Tuple{Symbol,String,Int}}              # include whose argument is an expression: owner, file, line
    placed::Set{Tuple{Symbol,String}}                         # module and absolute path placed there: the revisit guard
    visited::Set{String}                                      # absolute paths any walk placed or the index took
    external::Set{Symbol}                                     # names referenced from entry dirs other than test/ and unloaded extensions
    scripts::Vector{EntryCode}                                # code roots outside src/: entry dirs and unloaded extensions
end

# One module's load walk: the module, its rank, the directories its nested directory modules own, and how many of
# its load events are placed so far.
struct LoadUnit
    owner::Symbol                 # module the walked code belongs to
    rank::Vector{Int}             # rank its children extend
    nested::Vector{String}        # absolute directories of directory modules inside it
    count::Base.RefValue{Int}     # load events placed so far
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

# The directories of the directory modules inside `moddir`, which place their own files.
function nested_dirs(build::IndexBuild, moddir)
    inner = String[]
    for dir in keys(build.dir2mod)
        dir == SINGLE_MODULE_DIR && continue
        joined = joinpath(build.src_root, dir)
        other = normpath(joined)
        other == moddir && continue
        is_within(other, moddir) && push!(inner, other)
    end
    inner
end

function start_index(parses::Parses, src_root::AbstractString, dir2mod, package::Module, extensions)
    rooted = source_root(src_root)
    root = nameof(package)
    dirs = nest_modules(parses, rooted, dir2mod)
    build = IndexBuild(
        parses.repo,
        rooted,
        root,
        package,
        Dict{Symbol,Module}(),
        extensions,
        Dict{Symbol,Vector{Int}}(),
        dirs,
        Dict{String,Tuple{Symbol,String}}(),
        parses,
        Placement[],
        FileNode[],
        ModRef[],
        Dict{Symbol,Dict{Symbol,Symbol}}(),
        Tuple{Symbol,String}[],
        Tuple{Symbol,String,String,Int}[],
        Tuple{Symbol,String,Int}[],
        Set{Tuple{Symbol,String}}(),
        Set{String}(),
        Set{Symbol}(),
        EntryCode[],
    )
    for (dir, key) in dirs
        key === root && continue
        joined = joinpath(rooted, dir)
        moddir = normpath(joined)
        entry = wrapper_of(parses, moddir)
        isnothing(entry) && continue
        build.openers[normpath(entry)] = (key, moddir)
    end
    build
end

function next_position!(unit::LoadUnit)
    unit.count[] += 1
    unit.count[]
end

# An inline module is keyed by its dotted path below the package, as a directory module is.
function inline_key(build::IndexBuild, owner::Symbol, name::Symbol)
    owner === build.root && return name
    Symbol(owner, ".", name)
end

# A module opens at its entry file: the entry's module body is its code at position 0, and what that code loads
# takes the positions after.
function open_module!(build::IndexBuild, key::Symbol, rank::Vector{Int}, entry::String, nested)
    push!(build.visited, entry)
    tree = parsed_tree(build.parses,entry)
    if isnothing(tree)
        rel = relpath(entry, build.repo)
        push!(build.unparsed, (key, rel))
        return
    end
    code = entry_code(tree)
    push!(build.placements, Placement(key, entry, 0, code))
    unit = LoadUnit(key, rank, nested, Ref(0))
    walk_code!(build, unit, code, entry)
end

# Load order: each include and each module block takes the next position in the walking module, and the walk
# enters it there, as Julia loads it.
function walk_code!(build::IndexBuild, unit::LoadUnit, code, file)
    for event in load_events(code)
        if is_module_block(event)
            place_block!(build, unit, event, file)
        else
            place_include!(build, unit, event, file)
        end
    end
end

# A directory module's entry opens that module where it is included. A file inside another directory module's
# directory is that module's to place; any other file joins the including module. An include of an expression or
# of a file absent on disk is noted where the walk meets it.
function place_include!(build::IndexBuild, unit::LoadUnit, call, file)
    argument = first(call_args(call))
    spec = static_string(argument)
    line = source_line(call)
    rel = relpath(file, build.repo)
    if isnothing(spec)
        push!(build.nonliteral, (unit.owner, rel, line))
        return
    end
    joined = joinpath(dirname(file), spec)
    target = normpath(joined)
    if !isfile(target)
        push!(build.missing, (unit.owner, rel, spec, line))
        return
    end
    # A loaded extension's entry is its extension's to place, where a fallback include for older Julia names it too.
    any(extension -> last(extension) == target, build.extensions) && return
    if haskey(build.openers, target)
        target in build.visited && return
        key, moddir = build.openers[target]
        position = next_position!(unit)
        rank = [unit.rank; position]
        build.ranks[key] = rank
        nested = nested_dirs(build, moddir)
        open_module!(build, key, rank, target, nested)
        return
    end
    skips_nested(target, unit.nested) && return
    key = (unit.owner, target)
    key in build.placed && return
    push!(build.placed, key)
    push!(build.visited, target)
    position = next_position!(unit)
    tree = parsed_tree(build.parses,target)
    if isnothing(tree)
        rel = relpath(target, build.repo)
        push!(build.unparsed, (unit.owner, rel))
        return
    end
    push!(build.placements, Placement(unit.owner, target, position, tree))
    walk_code!(build, unit, tree, target)
end

function place_block!(build::IndexBuild, unit::LoadUnit, block, file)
    name = module_name(block)
    isnothing(name) && return
    position = next_position!(unit)
    key = inline_key(build, unit.owner, name)
    rank = [unit.rank; position]
    build.ranks[key] = rank
    body = module_body(block)
    push!(build.placements, Placement(key, file, 0, body))
    inner = LoadUnit(key, rank, unit.nested, Ref(0))
    walk_code!(build, inner, body, file)
end

# The root opens at the spine, first in load order; every module the spine declares ranks inside it.
function walk_package!(build::IndexBuild)
    spine_name = string(build.root) * ".jl"
    joined = joinpath(build.src_root, spine_name)
    spine = normpath(joined)
    isfile(spine) || return
    rank = [1]
    build.ranks[build.root] = rank
    nested = nested_dirs(build, build.src_root)
    open_module!(build, build.root, rank, spine, nested)
end

# Julia loads an extension once the package and its triggers have loaded, so each ranks after the whole package.
function walk_extensions!(build::IndexBuild)
    for (position, (key, entry)) in enumerate(build.extensions)
        rank = [1 + position]
        build.ranks[key] = rank
        open_module!(build, key, rank, entry, String[])
    end
end

# A module's rank; empty for a module no load walk reaches.
module_rank(build::IndexBuild, owner::Symbol) = get(build.ranks, owner, Int[])

# The includes of code no load walk reached: an expression, or a file absent on disk.
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

# The ranked modules this Julia loaded, once every load walk has ranked them.
function load_modules!(build::IndexBuild)
    for key in keys(build.ranks)
        loaded = loaded_module(build.package, key)
        if !isnothing(loaded)
            build.loaded[key] = loaded
        end
    end
end

# A member read through a qualifier naming one of the package's modules, from where the code sits. Code this Julia
# did not load, a splice, a macro's result or a head name its module does not bind may name one, so it counts.
function reads_package_name(build::IndexBuild, home, read::NameRead)
    isnothing(read.through) || return read.through in values(build.loaded)
    isnothing(home) && return true
    path = dotted_names(read.qualifier)
    isnothing(path) && return true
    head = first(path)
    !isdefined(home, head)
end

# Each name written joins its definition's refs, or modrefs outside any; signatures and export lists stay out. An
# imported name and a type's own name root in modrefs: a method on either extends what dispatch reaches.
function file_refs!(build::IndexBuild, home, scan::FileScan)
    for read in scan.reads
        read.in_signature && continue
        read.in_export && continue
        is_local_read(read) && continue
        if is_member(read)
            reads_package_name(build, home, read) || continue
        end
        names = scan.modrefs
        if !isnothing(read.def)
            names = get!(Set{Symbol}, scan.refs, read.def)
        end
        push!(names, read.name)
    end
    union!(scan.modrefs, scan.imports)
    union!(scan.modrefs, scan.types)
    scan
end

function add_node!(build::IndexBuild, owner::Symbol, path, filerank, iswrapper, code)
    rel = relpath(path, build.repo)
    name = basename(rel)
    modrank = module_rank(build, owner)
    home = get(build.loaded, owner, nothing)
    walked = scan_tree(code, home)
    scan = file_refs!(build, home, walked)
    bodies = method_bodies(code, rel, owner)
    node = FileNode(owner, rel, name, modrank, filerank, iswrapper, scan, code, bodies)
    push!(build.nodes, node)
end

# Loaded code in load order. Position 0 is a module's own code: a directory module's entry, or an inline block.
function index_placements!(build::IndexBuild)
    for placement in build.placements
        is_entry = placement.position == 0
        add_node!(build, placement.owner, placement.path, placement.position, is_entry, placement.code)
    end
end

# Module references resolve once every module is known, the inline ones included, and once every module's renames
# are read, since a file may write a path through a name another file of its module binds.
function add_refs!(build::IndexBuild)
    known = Set(keys(build.ranks))
    plain = ModuleNames(known, build.root)
    for node in build.nodes
        scope = key_segments(node.mod)
        renames = get!(Dict{Symbol,Symbol}, build.aliases, node.mod)
        code_aliases!(renames, plain, scope, node.tree)
    end
    modules = ModuleNames(known, build.root, build.aliases)
    for node in build.nodes
        scope = key_segments(node.mod)
        walk_modrefs!(build.refs, node.mod, scope, node.path, modules, node.tree)
    end
end

# A file's top level and the body of every module block it holds, at any depth outside quoted code.
function code_roots(tree)
    roots = JS.SyntaxNode[tree]
    for event in load_events(tree)
        is_module_block(event) || continue
        body = module_body(event)
        inner = code_roots(body)
        append!(roots, inner)
    end
    roots
end

function note_unowned_includes!(build::IndexBuild, path, tree)
    rel = relpath(path, build.repo)
    name = basename(path)
    stem = first(splitext(name))
    owner = Symbol(stem)
    for root in code_roots(tree)
        note_includes!(build, owner, path, rel, root)
    end
end

# A source file no load walk reached joins the index unranked, under the module whose directory holds it.
function add_loose_files!(build::IndexBuild)
    tracked = tracked_files(build.src_root)
    for (dir, _, names) in walkdir(build.src_root), name in names
        endswith(name, ".jl") || continue
        joined = joinpath(dir, name)
        full = normpath(joined)
        full in build.visited && continue
        if !isnothing(tracked) && !(full in tracked)
            continue
        end
        push!(build.visited, full)
        owner = module_of(full, build.src_root, build.dir2mod)
        tree = parsed_tree(build.parses,full)
        if isnothing(tree)
            rel = relpath(full, build.repo)
            unowned = isnothing(owner) ? Symbol(first(splitext(name))) : owner
            push!(build.unparsed, (unowned, rel))
            continue
        end
        if isnothing(owner)
            note_unowned_includes!(build, full, tree)
            continue
        end
        add_node!(build, owner, full, 0, false, tree)
        rel = relpath(full, build.repo)
        note_includes!(build, owner, full, rel, tree)
    end
end

# An entry-dir file joins `scripts` unless the index holds it as source. Outside test/ its names join `external`, and
# a parse failure is reported: it shrinks `external`, so a def used only from a script looks like dead code.
function read_entry_file!(build::IndexBuild, modules::ReachModules, path, is_test, scripted)
    joined = isabspath(path) ? path : joinpath(build.repo, path)
    absolute = normpath(joined)
    tree = parsed_tree(build.parses, absolute)
    if isnothing(tree)
        rel = relpath(absolute, build.repo)
        is_test || push!(build.unparsed, (:Entry, rel))
        return
    end
    codes = outside_codes(modules, path, :Entry, tree)
    if !is_test
        for code in codes
            add_external!(build, code)
        end
    end
    absolute in build.visited && return
    absolute in scripted && return
    push!(scripted, absolute)
    append!(build.scripts, codes)
end

# Each code root of a file outside the loaded modules, walked once with the names the code itself binds.
function outside_codes(modules::ReachModules, path, owner::Symbol, tree)
    codes = EntryCode[]
    for root in code_roots(tree)
        home = script_home(modules, root)
        names = script_names(root, modules, home)
        scan = scan_tree(root, names)
        push!(codes, EntryCode(path, owner, root, scan))
    end
    codes
end

# Every name outside code reads, a member's included, keeps a definition it names alive.
function add_external!(build::IndexBuild, code::EntryCode)
    for read in code.scan.reads
        is_local_read(read) && continue
        push!(build.external, read.name)
    end
end

# The loaded modules outside code resolves against: the package's, and every top-level module this Julia loaded.
function outside_modules(build::IndexBuild)
    loaded = collect(values(build.loaded))
    tracked = Set{Module}(loaded)
    by_key = copy(build.loaded)
    top = top_modules()
    ReachModules(by_key, tracked, build.package, Set{Module}(), top)
end

# Entry dirs stay unloaded and each file parses once; a file two listed dirs hold is one script.
function read_entry_dirs!(build::IndexBuild, modules::ReachModules, entry_dirs)
    scripted = Set{String}()
    for dir in entry_dirs
        isdir(dir) || continue
        base = basename(normpath(dir))
        is_test = base == "test"
        for (folder, _, names) in walkdir(dir), name in names
            endswith(name, ".jl") || continue
            path = joinpath(folder, name)
            read_entry_file!(build, modules, path, is_test, scripted)
        end
    end
end

# The extension a file under `ext/` belongs to, as Julia names it: `ext/Name.jl`, or any file in `ext/Name/`.
function extension_of(path, directory)
    relative = relpath(path, directory)
    parts = splitpath(relative)
    head = first(parts)
    stem = first(splitext(head))
    Symbol(stem)
end

# An extension Julia has not loaded is code outside the loaded modules, read as an entry script outside test/ is,
# under the extension's own name: its names join `external`, so a definition only it reads stays live.
function read_unloaded_extensions!(build::IndexBuild, modules::ReachModules)
    joined = joinpath(build.repo, EXTENSION_DIR)
    directory = normpath(joined)
    isdir(directory) || return
    for (folder, _, names) in walkdir(directory), name in names
        endswith(name, ".jl") || continue
        found = joinpath(folder, name)
        path = normpath(found)
        path in build.visited && continue
        owner = extension_of(path, directory)
        rel = relpath(path, build.repo)
        tree = parsed_tree(build.parses, path)
        if isnothing(tree)
            push!(build.unparsed, (owner, rel))
            continue
        end
        codes = outside_codes(modules, rel, owner, tree)
        for code in codes
            add_external!(build, code)
        end
        append!(build.scripts, codes)
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
        build.scripts,
        build.unparsed,
        build.missing,
        build.nonliteral,
    )
end

function build_source_index(parses::Parses, src_root::AbstractString, dir2mod; entry_dirs = String[],
                            package::Module, extensions = Pair{Symbol,String}[])
    build = start_index(parses, src_root, dir2mod, package, extensions)
    walk_package!(build)
    walk_extensions!(build)
    load_modules!(build)
    index_placements!(build)
    add_loose_files!(build)
    add_refs!(build)
    modules = outside_modules(build)
    read_entry_dirs!(build, modules, entry_dirs)
    read_unloaded_extensions!(build, modules)
    source_index(build)
end

build_module_graph(index::SourceIndex) = ModuleGraph(index.rank, index.dir2mod, index.refs)

# The node naming what a call calls: its operator token, the member of a dotted name, a type application's type,
# or the bare name. Every other identifier in the call is a value it passes.
function callee_node(call)
    children = child_nodes(call)
    child_count(children) == 0 && return nothing
    if is_operator_call(call)
        JS.is_prefix_op_call(call) && return first(children)
        index = findfirst(operator_token, children)
        return isnothing(index) ? nothing : children[index]
    end
    head = first(children)
    kind = JS.kind(head)
    (kind == K"curly" || kind == K".") || return head
    parts = child_nodes(head)
    isnothing(parts) && return head
    kind == K"curly" ? first(parts) : last(parts)
end

# The nodes `node` writes without holding a value: a call's callee, the type an annotation declares, a struct's header.
function unheld_nodes!(unheld, node)
    kind = JS.kind(node)
    if kind == K"call" || kind == K"dotcall"
        callee = callee_node(node)
        isnothing(callee) || push!(unheld, callee)
        return unheld
    end
    (kind == K"::" || kind == K"struct") || return unheld
    children = child_nodes(node)
    child_count(children) == 0 && return unheld
    declared = kind == K"::" ? last(children) : first(children)
    for inner in walk_nodes(declared)
        push!(unheld, inner)
    end
    unheld
end

# Names written anywhere but as a callee or a declared type: stored, passed, returned, exported, or read by an entry
# script. A function or type called through a value unknown at its call site was written as one of these.
function value_names(index::SourceIndex)
    names = Set{Symbol}()
    for file in index.files
        unheld = Base.IdSet{JS.SyntaxNode}()
        for node in walk_nodes(file.tree)
            unheld_nodes!(unheld, node)
        end
        for node in walk_nodes(file.tree)
            node in unheld && continue
            name = node_symbol(node)
            isnothing(name) || push!(names, name)
        end
    end
    union!(names, index.external)
end

files_of(index::SourceIndex, mod::Symbol) = [file for file in index.files if file.mod === mod]

# A node's place in load order: its module's rank, then its position there. Compared as vectors, the order is
# the one Julia loads the code in.
load_place(file::FileNode) = [file.modrank; file.filerank]

# Each node's load place by module and path; a module block shares its file's path, so the path alone is ambiguous.
function load_places(index::SourceIndex)
    places = Dict{Tuple{Symbol,String},Vector{Int}}()
    for file in index.files
        places[(file.mod, file.path)] = load_place(file)
    end
    places
end

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
