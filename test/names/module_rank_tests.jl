# Module rank: include order, the edges between modules, and a cycle in that graph.

const FORWARD_CALL = load_package("ForwardCall", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => """
    module Aa
    climb() = Bb.later()
    self() = Aa.climb()
    quiet() = SomePkg.foo()
    end
    """,
    "bb/Bb.jl" => "module Bb\nlater() = 1\nend\n",
])

const DOWNWARD_CALL = load_package("DownwardCall", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\nf() = 1\nend\n",
    "bb/Bb.jl" => "module Bb\ng() = Aa.f()\nend\n",
])

const MUTUAL_CALL = load_package("MutualCall", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\nf() = Bb.g()\nend\n",
    "bb/Bb.jl" => "module Bb\ng() = Aa.f()\nend\n",
])

const FORWARD_CHAIN = load_package("ForwardChain", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
include("cc/Cc.jl")
using .Cc
""", [
    "aa/Aa.jl" => "module Aa\nf() = Bb.g()\nend\n",
    "bb/Bb.jl" => "module Bb\ng() = Cc.h()\nend\n",
    "cc/Cc.jl" => "module Cc\nh() = 1\nend\n",
])

const STRAY_CHILD = load_package("StrayChild", """
include("inner/Inner.jl")
using .Inner
""", [
    "inner/Inner.jl" => """
    module Inner
    include("deep/Deep.jl")
    using .Deep
    Core.eval(@__MODULE__, :(module Stray end))
    end
    """,
    "inner/deep/Deep.jl" => "module Deep\nend\n",
])

# A module block in an included file: under a directory module, and under a one-module package's root.
const INLINE_CHILD = load_package("InlineChild", """
include("aa/Aa.jl")
using .Aa
""", [
    "aa/Aa.jl" => "module Aa\ninclude(\"parts.jl\")\nend\n",
    "aa/parts.jl" => """
    helper() = 1
    module Inline
    climb() = Aa.helper()
    end
    """,
])

const INLINE_ROOT = load_package("InlineRoot", """
include("tokens.jl")
grow() = 1
""", [
    "tokens.jl" => "module Tokens\nclimb() = InlineRoot.grow()\nend\n",
])

# A spine with one directory module and plain files at two include depths, one holding a module block, and a
# module file behind a version check that fails, as an extension's fallback include is on current Julia.
const SPINE_FILES = load_package("SpineFiles", """
include("pkg/Versions.jl")
using .Versions
include("utils.jl")
@static if false
    include("guarded.jl")
end
""", [
    "guarded.jl" => "module Guarded\nend\n",
    "pkg/Versions.jl" => "module Versions\nend\n",
    "utils.jl" => """
    include("deeper.jl")
    unused_util() = 1
    module Piracy
    unused_piracy() = 1
    end
    """,
    "deeper.jl" => "unused_deeper() = 1\n",
])

function module_edge_rows(case)
    ctx = case_context(case)
    found = ArchCheck.run(ModuleBackEdges(), ctx)
    evidence_rows(found, :include_order, :via)
end

# A random package nested two deep. Finish order, children before the parent, is the back-edge oracle.
function random_package(rng)
    modules = String[]
    children = Dict{String,Vector{String}}("" => String[])
    function grow!(parent, name, depth)
        key = isempty(parent) ? name : "$parent.$name"
        push!(modules, key)
        push!(children[parent], key)
        children[key] = String[]
        depth < 2 || return
        for j in 1:rand(rng, 0:2)
            child = "$(name)s$j"
            grow!(key, child, depth + 1)
        end
    end
    for i in 1:rand(rng, 2:4)
        grow!("", "T$i", 0)
    end
    for kids in values(children)
        shuffle!(rng, kids)
    end

    finished = String[]
    function load!(key)
        foreach(load!, children[key])
        push!(finished, key)
    end
    foreach(load!, children[""])
    position = Dict(key => i for (i, key) in enumerate(finished))

    leaf(key) = String(last(split(key, '.')))
    function relative_wrapper(key)
        segments = lowercase.(split(key, '.'))
        name = leaf(key)
        joinpath(segments..., name * ".jl")
    end
    function include_spec(parent, kid)
        full = relative_wrapper(kid)
        isempty(parent) && return full
        parent_segments = lowercase.(split(parent, '.'))
        parent_dir = joinpath(parent_segments...)
        relpath(full, parent_dir)
    end
    function include_lines(parent, kids)
        lines = String[]
        for kid in kids
            spec = include_spec(parent, kid)
            name = leaf(kid)
            push!(lines, "include(\"$spec\")\nusing .$name")
        end
        join(lines, "\n")
    end

    files = Pair{String,String}[]
    truth = Set{Tuple{String,String}}()
    for key in modules
        calls = String[]
        for _ in 1:rand(rng, 0:3)
            target = rand(rng, modules)
            target == key && continue
            push!(calls, "$target.f()")
            push!(truth, (key, target))
        end
        body = isempty(calls) ? "1" : join(calls, " + ")
        nested = include_lines(key, children[key])
        name = leaf(key)
        source = "module $name\n$nested\nf() = $body\nend\n"
        push!(files, relative_wrapper(key) => source)
    end
    spine = include_lines("", children[""])
    (; modules, truth, position, spine, files)
end

@testset "a reference to a later module is a back edge and a self or external name is not" begin
    forward = module_edge_rows(FORWARD_CALL)
    @test (:back_edge, "Bb", "1->2", "qualified") in forward
    @test !any(row -> row[2] == "Aa", forward)
    @test !any(row -> row[2] == "SomePkg", forward)
    down = module_edge_rows(DOWNWARD_CALL)
    @test isempty(down)
end

@testset "a mutual reference is a cycle and a forward chain is not" begin
    cycle_ctx = case_context(MUTUAL_CALL)
    cycles = ArchCheck.run(ModuleCycles(), cycle_ctx)
    cycle = only(cycles)
    @test cycle.kind === :cycle
    loop = ev(cycle, :loop)
    @test loop == "Aa->Bb->Aa" || loop == "Bb->Aa->Bb"
    chain_ctx = case_context(FORWARD_CHAIN)
    chain = ArchCheck.run(ModuleCycles(), chain_ctx)
    @test isempty(chain)
    chain_edges = ArchCheck.run(ModuleBackEdges(), chain_ctx)
    @test !isempty(chain_edges)
end

function back_edge_pairs(check, ctx)
    found = ArchCheck.run(check, ctx)
    Set((string(finding.mod), finding.symbol) for finding in found)
end

@testset "nested module back edges match the generated finish order, and a reference to an enclosing module counts only when strict" begin
    for seed in 1:40
        rng = Xoshiro(seed)
        spec = random_package(rng)
        case_name = "RankOrder$seed"
        case = load_package(case_name, spec.spine, spec.files)
        ctx = Base.invokelatest(case_context, case)
        rank_names = Set(string(key) for key in keys(ctx.index.rank))
        @test rank_names == Set(spec.modules)
        layered = Set((from, to) for (from, to) in spec.truth if spec.position[to] >= spec.position[from])
        @test back_edge_pairs(ModuleBackEdges(strict = true), ctx) == layered
        outward = Set((from, to) for (from, to) in layered if !startswith(from, to * "."))
        @test back_edge_pairs(ModuleBackEdges(), ctx) == outward
    end
end

@testset "an inline module is ranked and owns its own code" begin
    cases = ((INLINE_CHILD, Symbol("Aa.Inline"), "Aa"), (INLINE_ROOT, :Tokens, "InlineRoot"))
    for (case, inline, parent) in cases
        ctx = case_context(case)
        corpus = ArchCheck.run(Corpus(), ctx)
        @test !any(finding -> finding.kind === :unranked_module, corpus)
        @test isempty(ArchCheck.run(ModuleBackEdges(), ctx))
        found = ArchCheck.run(ModuleBackEdges(strict = true), ctx)
        climb = only(found)
        @test climb.mod === inline
        @test climb.symbol == parent
        @test ev(climb, :include_order) == "1.1->1"
    end
end

@testset "the root owns every file its spine includes outside a module directory, loaded or not" begin
    ctx = case_context(SPINE_FILES)
    corpus = ArchCheck.run(Corpus(), ctx)
    @test isempty(corpus)
    dead = ArchCheck.run(DeadCode(), ctx)
    rows = Set((finding.mod, finding.file, finding.symbol) for finding in dead)
    expected = Set([
        (:SpineFiles, "src/utils.jl", "unused_util"),
        (:SpineFiles, "src/deeper.jl", "unused_deeper"),
        (:Piracy, "src/utils.jl", "unused_piracy"),
    ])
    @test rows == expected
end

@testset "a loaded submodule no file places is unranked" begin
    ctx = case_context(STRAY_CHILD)
    found = ArchCheck.run(Corpus(), ctx)
    stray = only(finding for finding in found if finding.kind === :unranked_module)
    @test stray.mod === :Inner
    @test stray.symbol == "Stray"
    @test !any(finding -> finding.symbol == "Deep", found)
end
