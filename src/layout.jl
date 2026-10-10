# Package layout: spine order, nested modules, wrappers and file ranks.

# A package's src/ as a normalized absolute path; the repository root is its parent.
source_root(src::AbstractString) = normpath(abspath(src))
function package_parses(src::AbstractString)
    rooted = source_root(src)
    repo = dirname(rooted)
    Parses(repo)
end

# Whether `path` lies inside directory `dir`.
function is_within(path, dir)
    relative = relpath(path, dir)
    relative != ".." && !startswith(relative, "../")
end

function is_include_call(node)
    JS.kind(node) == K"call" || return false
    children = child_nodes(node)
    child_count(children) < 2 && return false
    children[1].val === :include
end

# A code root's include calls, in source order: the argument node and its line.
function include_calls(tree)
    found = Tuple{JS.SyntaxNode,Int}[]
    for event in load_events(tree)
        is_include_call(event) || continue
        argument = first(call_args(event))
        push!(found, (argument, source_line(event)))
    end
    found
end

# What a code root loads, in source order: each include call and each module block, at any depth. The walk stops
# at a module block, whose code its own module loads, and at quoted code, which runs only when evaluated.
function load_events(root)
    events = JS.SyntaxNode[]
    collect_load_events!(events, root)
    events
end

function collect_load_events!(events, node)
    JS.kind(node) == K"quote" && return
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        if is_module_block(child) || is_include_call(child)
            push!(events, child)
        end
        collect_load_events!(events, child)
    end
end

# A string literal's text; nothing when any piece is an interpolation.
function static_string(node)
    JS.kind(node) == K"string" || return nothing
    children = child_nodes(node)
    isnothing(children) && return nothing
    parts = String[]
    for child in children
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

# The literal include specs an entry file's module code runs, in source order.
function entry_includes(parses::Parses, path::AbstractString)
    specs = String[]
    tree = parsed_tree(parses, path)
    isnothing(tree) && return specs
    code = entry_code(tree)
    for (arg, _) in include_calls(code)
        spec = static_string(arg)
        isnothing(spec) || push!(specs, spec)
    end
    specs
end

# The module a `using .Name` statement brings in; nothing for any other statement.
function used_sibling(node)
    JS.kind(node) == K"using" || return nothing
    clauses = child_nodes(node)
    isempty(clauses) && return nothing
    path = clauses[1]
    if JS.kind(path) == K":"
        listed = child_nodes(path)
        path = listed[1]
    end
    JS.kind(path) == K"importpath" || return nothing
    parts = child_nodes(path)
    length(parts) == 2 || return nothing
    JS.kind(parts[1]) == K"." || return nothing
    node_symbol(parts[2])
end

# The directory modules an entry file declares: an `include` of a file in a subdirectory, then `using .Name` as the
# next statement in its block. The module name comes from the `using` statement; the filename may differ from it.
function spine_modules(parses::Parses, path::AbstractString)
    dir2mod = Dict{String,Symbol}()
    tree = parsed_tree(parses, path)
    isnothing(tree) && return dir2mod
    for node in walk_nodes(entry_code(tree))
        statements = child_nodes(node)
        isnothing(statements) && continue
        for index in 1:(length(statements) - 1)
            included = statements[index]
            is_include_call(included) || continue
            argument = first(call_args(included))
            spec = static_string(argument)
            isnothing(spec) && continue
            dir = dirname(spec)
            isempty(dir) && continue
            name = used_sibling(statements[index + 1])
            if !isnothing(name)
                dir2mod[dir] = name
            end
        end
    end
    dir2mod
end

# The directory key of a single-module package: src/ itself.
const SINGLE_MODULE_DIR = "."

# The directory beside src/ that Julia's package loader reads extensions from.
const EXTENSION_DIR = "ext"

# The package's extensions Julia has loaded, each by name with the entry file it loaded. Julia names an extension
# after its entry under `ext/`: `ext/Name.jl` or `ext/Name/Name.jl`.
function loaded_extensions(pkg::Module, repo::AbstractString)
    found = Pair{Symbol,String}[]
    directory = joinpath(repo, EXTENSION_DIR)
    isdir(directory) || return found
    for entry in readdir(directory)
        stem = first(splitext(entry))
        name = Symbol(stem)
        extension = Base.get_extension(pkg, name)
        isnothing(extension) && continue
        loaded = pathof(extension)::String
        path = normpath(loaded)
        push!(found, name => path)
    end
    unique!(found)
end

# The package's directory modules. A spine that declares none makes the package one module: the root, keyed by
# its own name, owning src/.
function package_layout(parses::Parses, spine_path::AbstractString, root::Symbol)
    dir2mod = spine_modules(parses, spine_path)
    isempty(dir2mod) || return dir2mod
    Dict(SINGLE_MODULE_DIR => root)
end

# The root once with every loaded module: a single-module package's root is also its one module.
package_modules(root::Module, mods) = unique!([root; mods])
package_modules(ctx) = package_modules(ctx.root, ctx.mods)

# Each wrapper declares its nested modules by the package spine's rule. A nested module is keyed by its dotted path.
function nest_modules(parses::Parses, src_root, dir2mod)
    dirs = copy(dir2mod)
    pending = collect(dir2mod)
    while !isempty(pending)   # bounded: a directory enters `dirs`, and so the queue, once
        dir, mod = pop!(pending)
        wrapper = wrapper_of(parses, joinpath(src_root, dir))
        isnothing(wrapper) && continue
        children = spine_modules(parses, wrapper)
        for (child_dir, child) in children
            joined = joinpath(dir, child_dir)
            nested_dir = normpath(joined)
            haskey(dirs, nested_dir) && continue
            key = Symbol(mod, ".", child)
            dirs[nested_dir] = key
            push!(pending, nested_dir => key)
        end
    end
    dirs
end

# A source file whose name starts with a capital, the conventional entry-file shape.
function is_capital_source(path)
    name = basename(path)
    endswith(name, ".jl") && occursin(r"^[A-Z]", name)
end

# The module dir's entry file: capitalized by convention, and the one candidate no sibling includes.
# Nothing when the dir declares no entry or leaves it ambiguous, which blocks via unranked_file.
function wrapper_of(parses::Parses, module_dir::AbstractString)
    isdir(module_dir) || return nothing
    listed = readdir(module_dir; join = true)
    candidates = filter(is_capital_source, listed)
    length(candidates) == 1 && return only(candidates)
    included = Set{String}()
    for candidate in candidates
        for path in entry_includes(parses, candidate)
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

