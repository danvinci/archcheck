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

"""One name code reads, as the index's scoped walk meets it: a bare name, or a member read through a qualifier that
can name a module. A name the code declares (an argument, a local, a field, a type parameter) is no read."""
struct NameRead
    name::Symbol                              # the name as Julia binds it, a macro's with its `@`
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

# One file's top-level defs and every name its code reads; `refs` and `modrefs` file the reads by definition.
struct FileScan
    funcs::Vector{Symbol}                                        # top-level function names, source order
    constructors::Set{Symbol}                                    # type names a top-level curly head (`T{P}(x) = ...`) adds methods to
    types::Vector{Symbol}                                        # top-level struct and abstract type names
    refs::Dict{Symbol,Set{Symbol}}                               # definition or qualified method -> bare names it reads, and members read through a package module
    modrefs::Set{Symbol}                                         # names read outside any definition
    line::Dict{Symbol,Int}                                       # def name -> source line
    argtypes::Dict{Symbol,Vector{Union{Symbol,Nothing}}}         # function -> positional declared types; last method wins
    tupletail::Dict{Symbol,Int}                                  # function -> slot count when its body ends in a bare tuple
    imports::Set{Symbol}                                         # names this file's import clauses bind
    callsites::Dict{MethodSite,Vector{CallSite}}                 # each method -> the calls its body writes, source order
    forms::Dict{MethodSite,JS.SyntaxNode}                        # each method -> its definition form, nested methods included
    reads::Vector{NameRead}                                      # every name the code reads, in walk order
end

function empty_scan()
    funcs = Symbol[]
    constructors = Set{Symbol}()
    types = Symbol[]
    refs = Dict{Symbol,Set{Symbol}}()
    modrefs = Set{Symbol}()
    line = Dict{Symbol,Int}()
    argtypes = Dict{Symbol,Vector{Union{Symbol,Nothing}}}()
    tupletail = Dict{Symbol,Int}()
    imports = Set{Symbol}()
    callsites = Dict{MethodSite,Vector{CallSite}}()
    forms = Dict{MethodSite,JS.SyntaxNode}()
    reads = NameRead[]
    FileScan(funcs, constructors, types, refs, modrefs, line, argtypes, tupletail, imports, callsites, forms, reads)
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

# A file's parse, read and parsed on first request; nothing when it does not parse.
function parsed_tree(parses::Parses, path::AbstractString)
    key = normpath(path)
    haskey(parses.trees, key) && return parses.trees[key]
    key in parses.failed && return nothing
    rel = relpath(key, parses.repo)
    source = read(key, String)
    tree = parse_file(source, rel)
    if isnothing(tree)
        push!(parses.failed, key)
        return nothing
    end
    parses.trees[key] = tree
    tree
end
