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

# One file's top-level defs and, per def, the names its body references. Closures are included.
struct FileScan
    funcs::Vector{Symbol}                                        # top-level function names, source order
    types::Vector{Symbol}                                        # top-level struct and abstract type names
    refs::Dict{Symbol,Set{Symbol}}                               # definition or qualified method -> referenced names
    modrefs::Set{Symbol}                                         # names referenced outside any function
    line::Dict{Symbol,Int}                                       # def name -> source line
    argtypes::Dict{Symbol,Vector{Union{Symbol,Nothing}}}         # function -> positional declared types; last method wins
    tupletail::Dict{Symbol,Int}                                  # function -> slot count when its body ends in a bare tuple
    imports::Set{Symbol}                                         # names this file's import clauses bind
    callsites::Dict{MethodSite,Vector{CallSite}}                 # each method -> the calls its body writes, source order
    forms::Dict{MethodSite,JS.SyntaxNode}                        # each method -> its definition form, nested methods included
end

function empty_scan()
    funcs = Symbol[]
    types = Symbol[]
    refs = Dict{Symbol,Set{Symbol}}()
    modrefs = Set{Symbol}()
    line = Dict{Symbol,Int}()
    argtypes = Dict{Symbol,Vector{Union{Symbol,Nothing}}}()
    tupletail = Dict{Symbol,Int}()
    imports = Set{Symbol}()
    callsites = Dict{MethodSite,Vector{CallSite}}()
    forms = Dict{MethodSite,JS.SyntaxNode}()
    FileScan(funcs, types, refs, modrefs, line, argtypes, tupletail, imports, callsites, forms)
end

# The one parse. `nothing` on failure, so a caller accounts for it.
function parse_file(src::AbstractString, filename)
    try
        JS.parseall(JS.SyntaxNode, src; filename = filename)
    catch
        nothing
    end
end
