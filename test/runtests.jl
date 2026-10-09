# Self-tests for the architecture tool, over synthetic trees rather than any host project's tree.
using Test, JSON, Random
using ArchCheck

# The nested fixture loads as a package, so its modules carry the dotted names its source spine declares.
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "fixtures"))
using Nested
popfirst!(LOAD_PATH)

# A synthetic tree has no parsed def index, so these tests declare its absence rather than omit it.
const NO_SITES = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()

# Two modules exporting one name bound to different objects: the duplicate-owner and stale-export tests read them.
module FDupA
    export dup
    dup() = :a
end
module FDupB
    export dup
    dup() = :b
end

# evidence is a fixed key/value vocabulary per kind, so tests read it by key
ev(f, key) = only(v for (k, v) in f.evidence if k === key)

# A package loaded into Main from a fresh `src/`: `spine` is the body of `module name`, `files` the other sources by
# path under `src/`. A test runs a check on it with `run(check, case_context(case))`.
function load_package(name::AbstractString, spine::AbstractString, files = Pair{String,String}[])
    root = mktempdir()
    src = joinpath(root, "src")
    mkpath(src)
    for (relative, source) in files
        path = joinpath(src, relative)
        mkpath(dirname(path))
        write(path, source)
    end
    spine_path = joinpath(src, name * ".jl")
    write(spine_path, "module $name\n$spine\nend\n")
    pkg = Base.include(Main, spine_path)
    (; pkg, root, src)
end

case_context(case; options...) = Context(case.pkg; src = case.src, options...)

# Findings as sorted rows of kind, symbol, and the named evidence values.
function evidence_rows(found, keys::Symbol...)
    rows = [(f.kind, f.symbol, (ev(f, key) for key in keys)...) for f in found]
    sort!(rows)
end

# every engine check at its declared severity, with no consumer promotion
function default_severity()
    engine = (ArchCheck.CHECKS..., ReaderSet(Any, ()), ScanSeeds(()))
    ArchCheck.severities(engine)
end

# n files, random defs, random cross-file calls, and a random include order.
# The generator's edge set is the oracle for the back-edge and index checks.
function random_module(rng, dir)
    nfiles = rand(rng, 2:5)
    names = ["f$i.jl" for i in 1:nfiles]
    defs = Dict(n => ["d$(i)_$(j)" for j in 1:rand(rng, 1:3)] for (i, n) in enumerate(names))
    every = [(file, d) for file in names for d in defs[file]]

    bodies = Dict(n => String[] for n in names)
    truth = Set{Tuple{String,String}}()          # (from file, to file) the generator intended
    for file in names, def in defs[file]
        callees = String[]
        for _ in 1:rand(rng, 0:2)
            target_file, target_def = rand(rng, every)
            target_def in defs[file] && continue          # same-file calls are not cross-file edges
            push!(callees, target_def)
            push!(truth, (file, target_file))
        end
        body = isempty(callees) ? "1" : join(["$c()" for c in callees], " + ")
        push!(bodies[file], "$def() = $body")
    end

    order = shuffle(rng, names)
    mkpath(dir)
    write(joinpath(dir, "M.jl"), join(["include(\"$n\")" for n in order], "\n"))
    for n in names
        write(joinpath(dir, n), join(bodies[n], "\n"))
    end
    rank = Dict(n => i for (i, n) in enumerate(order))
    (truth = truth, rank = rank, files = names)
end

# One file per promise: the name model's checks in names/, the value model's in values/, sharing these helpers.
for model in ("names", "values")
    directory = joinpath(@__DIR__, model)
    for name in sort(readdir(directory))
        endswith(name, "_tests.jl") || continue
        path = joinpath(directory, name)
        include(path)
    end
end
