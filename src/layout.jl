# Package layout: spine order, nested modules, wrappers and file ranks.

# Whether `path` lies inside directory `dir`.
function is_within(path, dir)
    relative = relpath(path, dir)
    relative != ".." && !startswith(relative, "../")
end

function is_include_call(node)
    JS.kind(node) == K"call" || return false
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) < 2) && return false
    kids[1].val === :include
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
    kids = child_nodes(node)
    isnothing(kids) && return
    for child in kids
        if is_module_block(child) || is_include_call(child)
            push!(events, child)
        end
        collect_load_events!(events, child)
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

# The literal include specs an entry file's module code runs, in source order.
function entry_includes(path::AbstractString)
    specs = String[]
    source = read(path, String)
    tree = parse_file(source, path)
    isnothing(tree) && return specs
    code = entry_code(tree)
    for (arg, _) in include_calls(code)
        spec = static_string(arg)
        isnothing(spec) || push!(specs, spec)
    end
    specs
end

# The directory modules an entry file declares: an `include` of a file in a subdirectory followed by `using .Name`.
# The module name comes from the `using` line; the filename may differ from it.
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
    dir2mod = Dict{String,Symbol}()
    for (index, statement) in enumerate(stmts)
        included = match(r"^include\(\"([^\"]+)\"\)$", statement)
        isnothing(included) && continue
        index == length(stmts) && continue
        following = stmts[index + 1]
        using_line = match(r"^using\s+\.([A-Za-z_][A-Za-z0-9_]*)\b", following)
        isnothing(using_line) && continue
        dir = dirname(included.captures[1])
        isempty(dir) && continue
        dir2mod[dir] = Symbol(using_line.captures[1])
    end
    dir2mod
end

# The directory key of a single-module package: src/ itself.
const SINGLE_MODULE_DIR = "."

# The package's directory modules. A spine that declares none makes the package one module: the root, keyed by
# its own name, owning src/.
function package_layout(spine_path::AbstractString, root::Symbol)
    dir2mod = parse_spine_order(spine_path)
    isempty(dir2mod) || return dir2mod
    Dict(SINGLE_MODULE_DIR => root)
end

# The root once with every loaded module: a single-module package's root is also its one module.
package_modules(root::Module, mods) = unique!([root; mods])
package_modules(ctx) = package_modules(ctx.root, ctx.mods)

# Each wrapper declares its nested modules by the package spine's rule. A nested module is keyed by its dotted path.
function nest_modules(src_root, dir2mod)
    dirs = copy(dir2mod)
    pending = collect(dir2mod)
    while !isempty(pending)   # bounded: a directory enters `dirs`, and so the queue, once
        dir, mod = pop!(pending)
        wrapper = wrapper_of(joinpath(src_root, dir))
        isnothing(wrapper) && continue
        children = parse_spine_order(wrapper)
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
function wrapper_of(module_dir::AbstractString)
    isdir(module_dir) || return nothing
    listed = readdir(module_dir; join = true)
    candidates = filter(is_capital_source, listed)
    length(candidates) == 1 && return only(candidates)
    included = Set{String}()
    for candidate in candidates
        for path in entry_includes(candidate)
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

