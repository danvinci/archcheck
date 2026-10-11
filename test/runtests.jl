# Self-tests for the architecture tool, over synthetic trees rather than any host project's tree.
using Test, JSON, Random
using ArchCheck

# Fixture packages, so `gate` finds their `src/`: Nested is a module tree, SpineNamed a spine importing its child by
# the package name, Made modules its dependency Maker's macros make.
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "fixtures"))
using Nested
using SpineNamed
using Made
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

# A package written to a fresh directory and imported into Main as a user's is; a `cached` one loads from the cache
# file it builds, so Julia records its includes. `spine` is the body of `module name`, `files` the other src/ sources.
function load_package(name::AbstractString, spine::AbstractString, files = Pair{String,String}[], project = "";
                      cached::Bool = false)
    root = mktempdir()
    src = joinpath(root, "src")
    mkpath(src)
    for (relative, source) in files
        path = joinpath(src, relative)
        mkpath(dirname(path))
        write(path, source)
    end
    spine_path = joinpath(src, name * ".jl")
    header = cached ? "module $name" : "module $name; __precompile__(false)"
    write(spine_path, "$header\n$spine\nend\n")
    seed = hash(name)
    high = UInt128(seed) << 64
    low = UInt128(hash(seed))
    uuid = Base.UUID(high | low)
    write(joinpath(root, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\n$project")
    binding = Symbol(name)
    pushfirst!(LOAD_PATH, root)
    try
        Core.eval(Main, :(import $binding))
    finally
        popfirst!(LOAD_PATH)
    end
    pkg = Base.invokelatest(getfield, Main, binding)
    (; pkg, root, src)
end

case_context(case; options...) = Context(case.pkg; options...)

# Extensions on loaded triggers, one also named by a fallback include, one with an absent trigger that alone reads
# `_absent_only`; one extension's definitions use its trigger's type. The module-rank, sink and dead-code tests read it.
const HOSTED = load_package("Hosted", """
_inner() = 1
_absent_only() = 2
@static if false
    include("../ext/HostedTestExt.jl")
end
""", [
    "../ext/HostedRandomExt.jl" => """
    module HostedRandomExt; __precompile__(false)
    using Random
    using Hosted: _inner
    scaled(x::Int) = map(step -> step * _inner(), 1:x)
    draw(source::Random.AbstractRNG) = rand(source) * _inner()
    end
    """,
    "../ext/HostedTestExt.jl" => "module HostedTestExt; __precompile__(false)\nusing Hosted: _inner\nend\n",
    "../ext/HostedAbsentExt.jl" => """
    module HostedAbsentExt
    using Hosted: _inner
    doubled() = 2 * Hosted._absent_only()
    end
    """,
], """
[weakdeps]
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
Absent = "4d5c8b1e-0f3a-4e6b-9c2d-7a1b3c5d7e9f"

[extensions]
HostedRandomExt = "Random"
HostedTestExt = "Test"
HostedAbsentExt = "Absent"
""")

# `gate` with a throwaway report and no output, returning its findings.
function gate_findings(pkg; options...)
    report = joinpath(mktempdir(), "architecture.jsonl")
    ArchCheck.gate(pkg; report_path = report, io = devnull, options...)
end

# A workload check that keeps what the run observed, read the way a check author reads it.
module Observed
    using ArchCheck
    struct Keep <: Check end
    const LAST = Ref{Union{Nothing,Observation}}(nothing)
    function ArchCheck.run(::Keep, ctx)
        LAST[] = ctx.observed
        Finding[]
    end
    ArchCheck.kinds(::Keep) = (:kept_observation => :advisory,)
    ArchCheck.phase(::Keep) = :workload
end

# `gate` over a workload, returning its findings and what the workload observed.
function observed_gate(pkg; checks = (), options...)
    kept = (checks..., Observed.Keep())
    findings = gate_findings(pkg; checks = kept, options...)
    observed = Observed.LAST[]
    (; findings, observed)
end

# Findings as sorted rows of kind, symbol, and the named evidence values.
function evidence_rows(found, keys::Symbol...)
    rows = [(f.kind, f.symbol, (ev(f, key) for key in keys)...) for f in found]
    sort!(rows)
end

# Each indexed file's scan, by file name.
file_scans(ctx) = Dict(file.name => file.scan for file in ctx.index.files)

function syntax_nodes(node)
    children = Base.JuliaSyntax.children(node)
    isnothing(children) && return 1
    total = 1
    for child in children
        total += syntax_nodes(child)
    end
    total
end

# Syntax nodes in the body of the first method `source` defines, counted from the parse rather than by a check.
function body_nodes(source)
    tree = Base.JuliaSyntax.parseall(Base.JuliaSyntax.SyntaxNode, source)
    top = Base.JuliaSyntax.children(tree)
    method = top[1]
    parts = Base.JuliaSyntax.children(method)
    body = parts[2]
    syntax_nodes(body)
end

# every engine check at its declared severity, with no consumer promotion
function default_severity()
    engine = (ArchCheck.CHECKS..., ReaderSet(Any, ()))
    Dict(kind => severity for check in engine for (kind, severity) in ArchCheck.kinds(check))
end

# n files, random defs, random cross-file calls, and a random include order, as a package's spine and sources.
# The generator's edge set, `truth`, is the oracle for the back-edge and index checks.
function random_module(rng)
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
    spine = join(["include(\"$n\")" for n in order], "\n")
    sources = [n => join(bodies[n], "\n") for n in names]
    rank = Dict(n => i for (i, n) in enumerate(order))
    (; truth, rank, files = names, spine, sources)
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
