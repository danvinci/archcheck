# Package layout: spine order, nested modules, wrappers and file ranks.

# Whether `path` lies inside directory `dir`.
function is_within(path, dir)
    relative = relpath(path, dir)
    relative != ".." && !startswith(relative, "../")
end

# An entry file's include calls, in source order: the argument node and its line.
function include_calls(tree)
    found = Tuple{JS.SyntaxNode,Int}[]
    collect_include_calls!(found, tree)
    found
end

function collect_include_calls!(found, node)
    kids = child_nodes(node)
    is_call = JS.kind(node) == K"call"
    has_kids = !isnothing(kids) && !isempty(kids)
    if is_call && has_kids && kids[1].val === :include
        args = call_args(node)
        if !isempty(args)
            location = JS.source_location(node)
            line = Int(location[1])
            push!(found, (first(args), line))
        end
    end
    isnothing(kids) && return
    for child in kids
        collect_include_calls!(found, child)
    end
end

# A string literal's text; nothing when any piece is an interpolation.
function static_string(node)
    JS.kind(node) == K"string" || return nothing
    kids = child_nodes(node)
    isnothing(kids) && return nothing
    parts = String[]
    for child in kids
        JS.kind(child) == K"String" || return nothing
        value = child.val
        value isa String || return nothing
        push!(parts, value)
    end
    join(parts)
end

# A wrapper holds its module as the one module block at its top level; its code is that block's body.
function entry_code(tree)
    blocks = module_blocks(tree)
    length(blocks) == 1 || return tree
    block = only(blocks)
    module_body(block)
end

# The literal include specs a file's code runs, in source order. `code` picks that code out of the file's parse:
# `entry_code` for a wrapper, `identity` for a file another includes.
function include_paths(path::AbstractString, code)
    specs = String[]
    source = read(path, String)
    tree = parse_file(source, path)
    isnothing(tree) && return specs
    root = code(tree)
    for (arg, _) in include_calls(root)
        spec = static_string(arg)
        isnothing(spec) || push!(specs, spec)
    end
    specs
end

# The package spine's include order is the declared module DAG; it gives both rank and dir->module.
# The module name comes from the paired `using .Name`. The filename may differ from it.
function parse_spine_order(spine_path::AbstractString)
    # Comments stripped and `;`-joined statements split, so same-line and two-line forms parse alike.
    stmts = String[]
    for line in eachline(spine_path)
        code = first(split(line, '#'; limit = 2))
        for part in split(code, ';')
            statement = strip(part)
            if !isempty(statement)
                push!(stmts, statement)
            end
        end
    end
    rank = Dict{Symbol,Int}()
    dir2mod = Dict{String,Symbol}()
    position = 0
    for (index, statement) in enumerate(stmts)
        included = match(r"^include\(\"([^\"]+)\"\)$", statement)
        isnothing(included) && continue
        position += 1
        index == length(stmts) && continue
        following = stmts[index + 1]
        using_line = match(r"^using\s+\.([A-Za-z_][A-Za-z0-9_]*)\b", following)
        isnothing(using_line) && continue
        dir = dirname(included.captures[1])
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

# The root once with every loaded module: a single-module package's root is also its one module.
package_modules(root::Module, mods) = unique!([root; mods])
package_modules(ctx) = package_modules(ctx.root, ctx.mods)

# Each wrapper declares its nested modules by the package spine's rule. A nested module is keyed by its dotted
# path; its rank is its parent's plus its position in the parent wrapper's include order.
function nest_modules(src_root, rank, dir2mod)
    ranks = Dict{Symbol,Vector{Int}}()
    for (mod, position) in rank
        ranks[mod] = [position]
    end
    dirs = copy(dir2mod)
    pending = collect(dir2mod)
    while !isempty(pending)   # bounded: a directory enters `dirs`, and so the queue, once
        dir, mod = pop!(pending)
        haskey(ranks, mod) || continue
        wrapper = wrapper_of(joinpath(src_root, dir))
        isnothing(wrapper) && continue
        positions, children = parse_spine_order(wrapper)
        for (child_dir, child) in children
            joined = joinpath(dir, child_dir)
            nested_dir = normpath(joined)
            haskey(dirs, nested_dir) && continue
            key = Symbol(mod, ".", child)
            ranks[key] = [ranks[mod]; positions[child]]
            dirs[nested_dir] = key
            push!(pending, nested_dir => key)
        end
    end
    ranks, dirs
end

# A source file whose name starts with a capital, the conventional entry-file shape.
function is_capital_source(path)
    name = basename(path)
    endswith(name, ".jl") && occursin(r"^[A-Z]", name)
end

# The module dir's entry file: capitalized by convention, and the one candidate no sibling includes.
# Nothing when the dir declares no entry or leaves it ambiguous, which blocks via unranked_file.
function wrapper_of(module_dir::AbstractString)
    isdir(module_dir) || return nothing
    listed = readdir(module_dir; join = true)
    candidates = filter(is_capital_source, listed)
    length(candidates) == 1 && return only(candidates)
    included = Set{String}()
    for candidate in candidates
        for path in include_paths(candidate, entry_code)
            target = joinpath(module_dir, path)
            push!(included, normpath(target))
        end
    end
    entries = String[]
    for candidate in candidates
        normpath(candidate) in included && continue
        push!(entries, candidate)
    end
    length(entries) == 1 || return nothing
    only(entries)
end

function skips_nested(target, nested)
    for dir in nested
        is_within(target, dir) && return true
    end
    false
end

# Depth-first. `position` is how many files are already ranked; the return is the count after `file`.
function rank_includes!(order, module_dir, nested, file, code, position)
    includer_dir = dirname(file)   # an include resolves against its includer, apart from the module root
    for included in include_paths(file, code)
        joined = joinpath(includer_dir, included)
        target = normpath(joined)
        if skips_nested(target, nested)   # a nested module ranks its own files
            continue
        end
        rel = relpath(target, module_dir)
        haskey(order, rel) && continue   # also the cycle guard: a revisit leaves the walk
        position += 1
        order[rel] = position
        if isfile(target)
            position = rank_includes!(order, module_dir, nested, target, identity, position)
        end
    end
    position
end

# A module wrapper's include order is the declared file DAG within that module: path in module -> position.
# Depth-first, so a nested include takes its position from where its includer reaches it: the load order.
function file_rank(entry::AbstractString, module_dir::AbstractString; nested = String[])
    order = Dict{String,Int}()
    rank_includes!(order, module_dir, nested, entry, entry_code, 0)
    order
end

# Owning module for a source path: the longest directory prefix dir2mod declares; a nested module resolves to
# itself. Past every prefix, a single-module package's root owns the path.
function module_of(path, src_root, dir2mod)
    relative = relpath(path, src_root)
    parts = splitpath(relative)
    depth = length(parts) - 1
    for level in depth:-1:1
        dir = joinpath(parts[1:level]...)
        haskey(dir2mod, dir) && return dir2mod[dir]
    end
    get(dir2mod, SINGLE_MODULE_DIR, nothing)
end

# A module keeps the rank stored for it. The root of a package with directory modules has none stored; its
# rank is earlier than every module rank, which starts at 1.
function module_rank_of(owner, ranks, root)
    haskey(ranks, owner) && return ranks[owner]
    owner === root && return Int[0]
    Int[]
end
