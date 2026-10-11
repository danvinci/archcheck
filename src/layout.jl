# Package layout: the files a load includes, the module each goes into, and the include calls that name them.

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

function is_joinpath_call(node)
    JS.kind(node) == K"call" || return false
    children = child_nodes(node)
    child_count(children) < 2 && return false
    children[1].val === :joinpath
end

# The string literals a `joinpath` call starts with, up to its first piece computed at load.
function joinpath_literals(call)
    literals = String[]
    for piece in call_args(call)
        text = static_string(piece)
        isnothing(text) && break
        push!(literals, text)
    end
    literals
end

# The path an include argument names before load: a string literal, or a `joinpath` of string literals only.
# Nothing when the load computes any piece.
function include_spec(argument)
    is_joinpath_call(argument) || return static_string(argument)
    literals = joinpath_literals(argument)
    pieces = call_args(argument)
    length(literals) == length(pieces) || return nothing
    joinpath(literals...)
end

"""One include a package's load ran, as Julia recorded it."""
struct RecordedInclude
    path::String   # absolute normalized path of the included file
    key::Symbol    # module the file went into, keyed as the index keys modules
end

"""The includes one load ran, in the order each started, and how many of them the index walk has matched."""
struct IncludeRecord
    includes::Vector{RecordedInclude}   # every include after the load's entry file
    matched::Base.RefValue{Int}         # includes matched to a call so far, from the first
end

"""A load Julia kept no record of: the walk follows the literal includes in the branches this Julia runs."""
struct NoRecord end

const LoadRecord = Union{IncludeRecord,NoRecord}

# The recorded include no call has matched yet; nothing once every one is.
function next_include(record::IncludeRecord)
    position = record.matched[] + 1
    position > length(record.includes) && return nothing
    record.includes[position]
end

# A literal include ran when it names the next recorded include: the same file, into the same module.
function take_include!(record::IncludeRecord, owner::Symbol, target::String)
    upcoming = next_include(record)
    isnothing(upcoming) && return false
    upcoming.key === owner || return false
    upcoming.path == target || return false
    record.matched[] += 1
    true
end

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

# The root once with every loaded module: a single-module package's root is also its one module.
function package_modules(root::Module, mods)
    loaded = Vector{Module}()
    push!(loaded, root)
    for mod in mods
        module_value = mod::Module
        push!(loaded, module_value)
    end
    unique!(loaded)
end
package_modules(ctx) = package_modules(ctx.root, ctx.mods)
