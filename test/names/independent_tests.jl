# Members of an independent set do not reference one another.

const EARLIER_SHARED = load_package("EarlierShared", """
include("shared/Shared.jl")
using .Shared
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "shared/Shared.jl" => "module Shared\nf() = 1\nend\n",
    "aa/Aa.jl" => "module Aa\nusing ..Shared\nend\n",
    "bb/Bb.jl" => "module Bb\ng() = Shared.f()\nend\n",
])

const SIBLING_PAIR = load_package("SiblingPair", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\nuse() = Bb.f()\nend\n",
    "bb/Bb.jl" => "module Bb\nf() = 1\nend\n",
])

@testset "members of an independent set do not reference one another" begin
    nested = Context(Nested)
    curves = Symbol("Geo.Curves")
    cuts = Symbol("Geo.Cuts")

    apart = Independent(:Contracts, :Geo)
    apart_found = ArchCheck.run(apart, nested)
    @test isempty(apart_found)

    between_check = Independent(curves, cuts)
    between = ArchCheck.run(between_check, nested)
    qualified = only(finding for finding in between if ev(finding, :via) == "qualified")
    @test qualified.kind === :sibling_edge
    @test qualified.mod === curves
    @test (qualified.file, qualified.line) == ("src/geo/curves/curve.jl", 15)
    @test (ev(qualified, :from), ev(qualified, :to)) == ("Geo.Curves", "Geo.Cuts")

    through_check = Independent(:Low, :Geo)
    through = ArchCheck.run(through_check, nested)
    inner = only(finding for finding in through if finding.mod === curves && ev(finding, :via) == "using")
    @test (inner.file, inner.line) == ("src/geo/curves/Curves.jl", 3)
    @test (ev(inner, :from), ev(inner, :to)) == ("Geo", "Low")

    into_check = Independent(:Hi, :Geo)
    into = ArchCheck.run(into_check, nested)
    @test any(finding -> finding.symbol == "Geo.Curves" && ev(finding, :to) == "Geo", into)

    lower_ctx = case_context(EARLIER_SHARED)
    lower_check = Independent(:Aa, :Bb)
    lower = ArchCheck.run(lower_check, lower_ctx)
    @test isempty(lower)

    sibling_ctx = case_context(SIBLING_PAIR)
    sibling_check = Independent(:Aa, :Bb)
    siblings = ArchCheck.run(sibling_check, sibling_ctx)
    @test any(finding -> finding.kind === :sibling_edge, siblings)

    @test_throws ArgumentError Independent(:Geo)
    @test_throws ArgumentError Independent(:Geo, curves)
    misspelled = Independent(:Contracts, :Goe)
    @test_throws ArgumentError ArchCheck.run(misspelled, nested)
end
