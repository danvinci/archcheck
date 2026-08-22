# The one pass over src/: cross-module references, the include-order ranks at both zooms, and where
# every def lives.
struct ModRef
    from::Symbol
    to::Symbol
    file::String     # repo-relative
    line::Int
    via::Symbol      # :using | :import | :qualified
end

struct ModuleGraph
    rank::Dict{Symbol,Int}          # module -> position in the package spine's include order
    dir2mod::Dict{String,Symbol}    # src subdir -> module
    refs::Vector{ModRef}            # every cross-module reference in src/
end

# An entry file's include order - the rank source at both zooms: the package spine ranks modules,
# <Domain>.jl ranks files.
function include_stmts(entry_path::AbstractString)
    stmts = Tuple{String,Int}[]
    for (line, text) in enumerate(eachline(entry_path))
        m = match(r"^\s*include\(\"([^\"]+)\"\)", text)
        isnothing(m) || push!(stmts, (m.captures[1], line))
    end
    stmts
end

include_paths(entry_path::AbstractString) = [spec for (spec, _) in include_stmts(entry_path)]

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

# A module wrapper's include order is the declared file DAG within that module: path in module -> position.
# Depth-first, so a nested include takes its position from where its includer reaches it - Julia's load order.
function file_rank(module_dir::AbstractString)
    entry = wrapper_of(module_dir)
    isnothing(entry) && return Dict{String,Int}()
    order = Dict{String,Int}()
    position = 0
    function rank_includes_of(file)
        here = dirname(file)          # an include resolves against its includer, not the module root
        for included in include_paths(file)
            target = normpath(joinpath(here, included))
            rel = relpath(target, module_dir)
            haskey(order, rel) && continue     # also the cycle guard: a revisit never recurses
            position += 1
            order[rel] = position
            isfile(target) && rank_includes_of(target)
        end
    end
    rank_includes_of(entry)
    order
end

# Owning module for a source path: the longest directory prefix dir2mod declares. A flat layout has only
# a one-segment prefix to try, so this matches a first-segment lookup; a nested module resolves to itself.
function module_of(path, src_root, dir2mod)
    parts = splitpath(relpath(path, src_root))
    for depth in (length(parts) - 1):-1:1
        dir = joinpath(parts[1:depth]...)
        haskey(dir2mod, dir) && return dir2mod[dir]
    end
    nothing
end

function walk_modrefs!(refs, from, file, known, n)
    kids = child_nodes(n); kids === nothing && return
    k = JS.kind(n); ln = JS.source_location(n)[1]
    if k == K"using" || k == K"import"
        for clause in kids
            path = JS.kind(clause) == K":" ? first(child_nodes(clause)) : clause   # `using X: a` -> X
            if JS.kind(path) == K"importpath"
                to = importpath_module(path)
                (to !== nothing && to != from) && push!(refs, ModRef(from, to, file, ln, Symbol(string(k))))
            end
        end
        return
    elseif k == K"." && !isempty(kids) && kids[1].val isa Symbol && kids[1].val in known && kids[1].val != from
        push!(refs, ModRef(from, kids[1].val, file, ln, :qualified))
    end
    for c in kids; walk_modrefs!(refs, from, file, known, c); end
end

function scan_modrefs(src::AbstractString, from, file, known)
    refs = ModRef[]
    tree = parse_file(src, file)
    tree === nothing && return refs
    walk_modrefs!(refs, from, file, known, tree)
    refs
end

# One source file. (modrank, filerank) is the layer coordinate the rank checks compare.
struct FileNode
    mod::Symbol       # owning module
    path::String      # repo-relative path
    name::String      # basename
    modrank::Int      # module position in the package spine's include order
    filerank::Int     # file position in the wrapper's depth-first include order; 0 when nothing includes it
    iswrapper::Bool   # this module's entry file, resolved from its directory rather than by name
    scan::FileScan    # this file's defs and the names each references
end

# src/ and the entry dirs, parsed once. Every check reads a slice; nothing re-walks the tree.
struct SourceIndex
    repo::String                            # the root every path below is relative to
    rank::Dict{Symbol,Int}                  # module -> package-spine include position
    dir2mod::Dict{String,Symbol}            # src subdir -> module
    files::Vector{FileNode}                 # every module-owned source file
    refs::Vector{ModRef}                    # cross-module references, from the same parse
    external::Set{Symbol}                   # names referenced from the entry dirs (test/, scripts/)
    unparsed::Vector{Tuple{Symbol,String}}  # (owner, path) of files no check could read; :Entry = an entry dir
    missing::Vector{Tuple{Symbol,String,String,Int}}  # include of a file that is not on disk: owner, includer, spec, line
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

function build_source_index(src_root::AbstractString, rank, dir2mod; entry_dirs = String[])
    src_root = abspath(src_root)
    repo = dirname(src_root)
    tracked = tracked_files(src_root)
    known = Set(keys(rank))
    franks = Dict{Symbol,Dict{String,Int}}()
    wrappers = Dict{Symbol,String}()   # module -> its entry file, the one file the module never includes
    moddirs = Dict{Symbol,String}()    # module -> its directory, the root its file ranks are keyed against
    for (dir, mod) in dir2mod
        moddir = joinpath(src_root, dir)
        moddirs[mod] = moddir
        franks[mod] = file_rank(moddir)
        entry = wrapper_of(moddir)
        if !isnothing(entry)
            wrappers[mod] = entry
        end
    end
    nodes = FileNode[]
    refs = ModRef[]
    unparsed = Tuple{Symbol,String}[]
    missing = Tuple{Symbol,String,String,Int}[]
    function collect_missing!(owner, path, rel)
        for (spec, line) in include_stmts(path)
            target = normpath(joinpath(dirname(path), spec))
            isfile(target) && continue
            push!(missing, (owner, rel, spec, line))
        end
    end
    for (root, _, files) in walkdir(src_root), fn in files
        endswith(fn, ".jl") || continue
        path = joinpath(root, fn)
        isnothing(tracked) || normpath(path) in tracked || continue   # untracked = not the shipped corpus
        mod = module_of(path, src_root, dir2mod)
        rel = relpath(path, repo)
        if isnothing(mod)
            collect_missing!(Symbol(first(splitext(fn))), path, rel)
            continue
        end
        collect_missing!(mod, path, rel)
        tree = parse_file(read(path, String), rel)
        if tree === nothing
            push!(unparsed, (mod, rel))
            continue
        end
        walk_modrefs!(refs, mod, rel, known, tree)              # cross-module edges
        iswrapper = path == get(wrappers, mod, "")
        inmod = relpath(path, moddirs[mod])      # the key file ranks are held against
        push!(nodes, FileNode(mod, rel, fn, get(rank, mod, 0), get(franks[mod], inmod, 0),
                              iswrapper, scan_tree(tree)))   # defs + body refs
    end

    # Entry dirs are parsed but never loaded: a parse failure here shrinks `external`, turning defs used
    # only from a script into false dead-code findings.
    external = Set{Symbol}()
    for dir in entry_dirs
        isdir(dir) || continue
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
    SourceIndex(repo, rank, dir2mod, nodes, refs, external, unparsed, missing)
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
