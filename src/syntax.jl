# One file's definitions, the names they reference, and the calls each method writes.

"One method's definition in its file: the name it defines, as `FileScan.refs` keys it, and the line it starts on."
struct MethodSite
    name::Symbol   # the def name, a qualified method name (`M.show`) or a callable's receiver type
    line::Int      # source line of the definition
end

"""One call written in a method's body, closures and comprehensions included. Two calls with equal text in one
method ask one question: the text is the source as written, whitespace collapsed, with no name resolved."""
struct CallSite
    callee::Symbol       # the called name: `f` in `f(x)`, `g` in `M.g(x)`
    qualifier::String    # the module path written before the name, `M` in `M.g(x)`; "" for a bare call
    arguments::String    # positional argument source text in order, whitespace collapsed
    keywords::String     # keyword argument source text sorted by name, whitespace collapsed
    line::Int            # source line of the call
    loop_depth::Int      # loops, comprehensions and generators enclosing the call within its method
    is_used::Bool        # the call's value is read
end

"""One local binding the scoped walk opens: an argument, an assigned or declared local, or a `where` parameter."""
struct LocalBinding
    name::Symbol                           # the bound name
    node::JS.SyntaxNode                    # its declaring identifier, which every read of it names
    line::Int                              # source line of the declaration
    kind::Symbol                           # :argument, :local, :function for a local method's name, or :parameter
    def::Union{Nothing,Symbol}             # refs key of the definition holding it; nothing outside any
    method::Union{Nothing,JS.SyntaxNode}   # outermost method, macro or closure form holding it
end

"""One name code reads, as the index's scoped walk meets it: a bare name, or a member read through a qualifier that
can name a module. A name the code declares (an argument, a local, a field, a type parameter) is no read."""
struct NameRead
    name::Symbol                              # the name as Julia binds it, a macro's with its `@`
    binding::Union{Nothing,JS.SyntaxNode}     # declaring identifier of the local the name resolves to; nothing for a free name
    qualifier::Union{Nothing,JS.SyntaxNode}   # the code a member is read through; nothing for a bare name
    through::Union{Nothing,Module}            # the loaded module the qualifier names, resolved once at index build
    def::Union{Nothing,Symbol}                # refs key of the definition holding the read; nothing outside any
    method::Union{Nothing,JS.SyntaxNode}      # outermost method, macro or closure form holding it; nothing in load-time code
    line::Int                                 # source line of the read
    in_signature::Bool                        # in a signature's annotations, which run where the method is defined
    in_export::Bool                           # listed by an `export` or `public` line, which publishes the binding
    is_quoted::Bool                           # a quoted symbol, which names a binding without reading it
end

is_member(read::NameRead) = !isnothing(read.qualifier)
is_local_read(read::NameRead) = !isnothing(read.binding)

# One file's top-level defs and every name its code reads; `refs` and `modrefs` file the reads by definition.
struct FileScan
    funcs::Vector{Symbol}                                        # top-level function names, source order
    constructors::Set{Symbol}                                    # type names a top-level curly head (`T{P}(x) = ...`) adds methods to
    types::Vector{Symbol}                                        # top-level struct and abstract type names
    refs::Dict{Symbol,Set{Symbol}}                               # definition or qualified method -> bare names it reads, and members read through a package module
    modrefs::Set{Symbol}                                         # names read outside any definition
    line::Dict{Symbol,Int}                                       # def name -> source line
    tupletail::Dict{Symbol,Int}                                  # function -> slot count when its body ends in a bare tuple
    imports::Set{Symbol}                                         # names this file's import clauses bind
    callsites::Dict{MethodSite,Vector{CallSite}}                 # each method -> the calls its body writes, source order
    forms::Dict{MethodSite,JS.SyntaxNode}                        # each method -> its definition form, nested methods included
    reads::Vector{NameRead}                                      # every name the code reads, in walk order
    bindings::Vector{LocalBinding}                                    # every local binding the code opens, in walk order
    resolved::IdDict{JS.SyntaxNode,JS.SyntaxNode}                # each identifier naming a local -> that local's declaring identifier
end

# The declaring identifier of the local an identifier the walk met names; nothing for a free name.
local_binding(scan::FileScan, node::JS.SyntaxNode) = get(scan.resolved, node, nothing)

function empty_scan()
    funcs = Symbol[]
    constructors = Set{Symbol}()
    types = Symbol[]
    refs = Dict{Symbol,Set{Symbol}}()
    modrefs = Set{Symbol}()
    line = Dict{Symbol,Int}()
    tupletail = Dict{Symbol,Int}()
    imports = Set{Symbol}()
    callsites = Dict{MethodSite,Vector{CallSite}}()
    forms = Dict{MethodSite,JS.SyntaxNode}()
    reads = NameRead[]
    bindings = LocalBinding[]
    resolved = IdDict{JS.SyntaxNode,JS.SyntaxNode}()
    FileScan(funcs, constructors, types, refs, modrefs, line, tupletail, imports, callsites, forms, reads, bindings,
             resolved)
end

# `nothing` on failure, so a caller accounts for it.
function parse_file(src::AbstractString, filename)
    try
        JS.parseall(JS.SyntaxNode, src; filename = filename)
    catch
        nothing
    end
end

# Every file's one parse: the layout, the index and the entry dirs all read through here.
struct Parses
    repo::String                       # root a parse names its file by
    trees::Dict{String,JS.SyntaxNode}  # normalized absolute path -> its parse
    failed::Set{String}                # normalized absolute paths whose parse failed
end

Parses(repo::AbstractString) = Parses(repo, Dict{String,JS.SyntaxNode}(), Set{String}())

function record_parse!(parses::Parses, key::String, tree::Union{Nothing,JS.SyntaxNode})
    if isnothing(tree)
        push!(parses.failed, key)
    else
        parses.trees[key] = tree
    end
    parses
end

# A file's parse, read and parsed on first request; nothing when it does not parse.
function parsed_tree(parses::Parses, path::AbstractString)
    key = normpath(path)
    haskey(parses.trees, key) && return parses.trees[key]
    key in parses.failed && return nothing
    rel = relpath(key, parses.repo)
    source = read(key, String)
    tree = parse_file(source, rel)
    record_parse!(parses, key, tree)
    tree
end

# One file's parse on a task of its own, through a cache of its own, which the shared cache takes in after.
fresh_parse(path::String, repo::String) = parsed_tree(Parses(repo), path)

# A task's value; a task that threw throws its own exception here, as the same call on the caller's task would.
function task_result(task::Task)
    try
        fetch(task)
    catch failure
        failure isa TaskFailedException || rethrow()
        throw(failure.task.exception)
    end
end

# `f(item, shared)` for each item, in the items' order whatever order the calls finish in. With one thread the calls
# run in turn on the caller's task; with more, each is its own task on the default pool.
function ordered_results(f::F, ::Type{T}, items::AbstractVector, shared) where {F,T}
    results = Vector{T}(undef, length(items))
    if Threads.nthreads() == 1
        for (position, item) in enumerate(items)
            results[position] = f(item, shared)
        end
        return results
    end
    tasks = Vector{Task}(undef, length(items))
    for (position, item) in enumerate(items)
        tasks[position] = Threads.@spawn f($item, $shared)
    end
    for (position, task) in enumerate(tasks)
        results[position] = task_result(task)::T
    end
    results
end
