# The package spine is the root module's file: its methods are indexed, and a workload probe records them.

const SPINE_ROOT = load_package("SpineRoot", """
include("child/Child.jl")
using .Child
spine_only(x) = x + 1
""", [
    "child/Child.jl" => """
    module Child
    child_only(x) = x
    end
    """,
])

@testset "a method in the spine is indexed and probed" begin
    ctx = case_context(SPINE_ROOT)
    spine_file = only(file for file in ctx.index.files if file.name == "SpineRoot.jl")
    @test spine_file.mod === :SpineRoot
    dead = ArchCheck.run(DeadCode(), ctx)
    planted = filter(f -> f.symbol == "spine_only", dead)
    finding = only(planted)
    @test finding.kind === :dead_code
    @test finding.mod === :SpineRoot
    @test endswith(finding.file, joinpath("src", "SpineRoot.jl"))
    corpus = ArchCheck.run(Corpus(), ctx)
    hole = any(f -> f.kind === :unranked_file && endswith(f.file, "SpineRoot.jl"), corpus)
    @test !hole
    uses_child = any(ref -> ref.to === :Child && ref.via === :using, ctx.index.refs)
    @test uses_child
    target = SPINE_ROOT.pkg.spine_only
    probes = Probes(; functions = (target,), slow_s = 0.0)
    workload = () -> target(2)
    watched = observed_gate(SPINE_ROOT.pkg; workload, probes)
    names = [record.name for record in watched.observed.records]
    @test names == [:spine_only]
end

@testset "a spine using an outside package and importing its child by the package name indexes" begin
    ctx = Context(SpineNamed)
    outside = any(ref -> ref.to === :Printf, ctx.index.refs)
    @test !outside
    imported = count(ref -> ref.via === :import && ref.to === :Child, ctx.index.refs)
    @test imported == 1
    dead = ArchCheck.run(DeadCode(), ctx)
    planted = filter(f -> f.symbol == "spine_only" && f.mod === :SpineNamed, dead)
    @test length(planted) == 1
end
