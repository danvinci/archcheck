# The intra-module function call graph: owned functions, the file each lives in, and which owned
# functions each calls. Reuses the body walk; cross-module calls belong to the module zoom.
struct CallGraph
    mod::Symbol
    funcs::Vector{Symbol}               # relocatable defs: functions, never types
    files::Dict{Symbol,String}          # def -> its file (repo-relative)
    calls::Dict{Symbol,Set{Symbol}}     # def -> the module's own defs it references
    refs::Dict{Symbol,Set{Symbol}}      # def -> every name it references; sinkable resolves these by reflection
    rank::Dict{String,Int}              # file (repo-relative) -> position in the module wrapper's include order
    site_refs::Dict{Tuple{Symbol,String},Set{Symbol}}   # (def, the file THAT method lives in) -> its own refs
end

# rank-free: adjacency is enough for callers that never compare positions.
CallGraph(mod, funcs, files, calls) = CallGraph(mod, funcs, files, calls, calls, Dict{String,Int}())

# One definition site per name: the per-site view collapses to the per-name one.
CallGraph(mod, funcs, files, calls, refs, rank) =
    CallGraph(mod, funcs, files, calls, refs, rank,
              Dict{Tuple{Symbol,String},Set{Symbol}}((n, get(files, n, "")) => r for (n, r) in refs))

# One module's graph from the index. Types carry refs (field + supertype coupling), so a struct embedding
# another file's type is an edge; only functions relocate, so funcs excludes them.
function build_call_graph(index, mod::Symbol)
    files = Dict{Symbol,String}()
    refs = Dict{Symbol,Set{Symbol}}()
    types = Set{Symbol}()
    rank = Dict{String,Int}()
    # A name's home is its LOWEST-ranked defining file: methods of one function can live in several files,
    # and a reference is satisfiable by the earliest of them.
    home!(name, f) = (!haskey(files, name) || f.filerank < rank[files[name]]) && (files[name] = f.path)
    site_refs = Dict{Tuple{Symbol,String},Set{Symbol}}()
    for f in files_of(index, mod)
        rank[f.path] = f.filerank
        for name in f.scan.funcs
            home!(name, f)
            union!(get!(refs, name, Set{Symbol}()), f.scan.refs[name])
            union!(get!(site_refs, (name, f.path), Set{Symbol}()), f.scan.refs[name])
        end
        for name in f.scan.types
            home!(name, f)
            push!(types, name)
            haskey(f.scan.refs, name) || continue
            union!(get!(refs, name, Set{Symbol}()), f.scan.refs[name])
            union!(get!(site_refs, (name, f.path), Set{Symbol}()), f.scan.refs[name])
        end
    end
    known = Set(keys(files))
    calls = Dict(n => Set(c for c in refs[n] if c in known && c != n) for n in keys(refs))
    funcs = [n for n in keys(refs) if !(n in types)]
    CallGraph(mod, funcs, files, calls, refs, rank, site_refs)
end
