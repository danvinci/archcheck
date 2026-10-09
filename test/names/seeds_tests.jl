# A fixed integer grid on a parameter is a finding.

const GRID_SEED_COUNTS = """
const GRID_COUNT = 12
const ITER_CAP = 64
"""
const GRID_SEED_GEO = """
by_const() = [k / GRID_COUNT for k in 0:GRID_COUNT]
literal() = [k / 16 for k in 0:16]
by_range() = range(0.0, 1.0; length = GRID_COUNT)
by_linrange() = LinRange(0.0, 1.0, GRID_COUNT)
span_grid(lo, hi) = range(lo, hi; length = GRID_COUNT)
function local_grid()
    count = 32
    (0:count) ./ count
end
function step_grid()
    step = 1.0 / GRID_COUNT
    [k * step for k in 0:GRID_COUNT]
end
function adjacent_grid()
    count = 9
    [k / (count - 1) for k in 0:count - 1]
end
caller_grid(count) = [k / count for k in 0:count]
shadowed(GRID_COUNT) = [k / GRID_COUNT for k in 0:GRID_COUNT]
native_breaks(knots) = [refine(knots[k], knots[k + 1]) for k in 1:length(knots) - 1]
indices(vertices) = [vertices[k] for k in 1:3]
capped(x) = [iterate(x) for _ in 1:ITER_CAP]
midpoint(a, b) = (a + b) / 2
function rebound(xs)
    count = 16
    count = length(xs)
    (0:count) ./ count
end
function quotes_equals(head)
    head === :(=)
    count = 8
    (0:count) ./ count
end
"""
const GRID_SEED_OTHER = """
const OWN_COUNT = 20
separate() = [k / OWN_COUNT for k in 0:OWN_COUNT]
unknown() = [k / GRID_COUNT for k in 0:GRID_COUNT]
module Inner
const INNER_COUNT = 5
inner_grid() = [k / INNER_COUNT for k in 0:INNER_COUNT]
end
"""

const GRID_SEEDS = load_package("GridSeeds", """
include("geo/Geo.jl")
using .Geo
include("other/Other.jl")
using .Other
""", [
    "geo/Geo.jl" => "module Geo\ninclude(\"counts.jl\")\ninclude(\"seeds.jl\")\nend\n",
    "geo/counts.jl" => GRID_SEED_COUNTS,
    "geo/seeds.jl" => GRID_SEED_GEO,
    "other/Other.jl" => "module Other\ninclude(\"seeds.jl\")\nend\n",
    "other/seeds.jl" => GRID_SEED_OTHER,
])

@testset "a fixed integer grid on a parameter is a finding" begin
    geometry = joinpath(GRID_SEEDS.src, "geo")
    other = joinpath(GRID_SEEDS.src, "other")
    geo_check = ScanSeeds((geometry,))
    geo_ctx = case_context(GRID_SEEDS)
    found = ArchCheck.run(geo_check, geo_ctx)
    expected = Set([
        "by_const", "literal", "by_range", "by_linrange", "span_grid",
        "local_grid", "step_grid", "adjacent_grid", "quotes_equals",
    ])
    found_symbols = Set(finding.symbol for finding in found)
    @test found_symbols == expected
    @test all(finding -> finding.kind === :scan_seed, found)
    identities = Set((finding.kind, finding.symbol, finding.file) for finding in found)
    @test length(identities) == length(found)

    both_check = ScanSeeds((geometry, other))
    together = ArchCheck.run(both_check, geo_ctx)
    together_symbols = Set(finding.symbol for finding in together)
    with_other = union(expected, Set(["separate", "inner_grid"]))
    @test together_symbols == with_other
    inner = only(finding for finding in together if finding.symbol == "inner_grid")
    @test inner.mod === Symbol("Other.Inner")
end
