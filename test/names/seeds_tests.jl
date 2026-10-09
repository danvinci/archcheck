# A fixed integer grid on a parameter is a finding.
@testset "fixed sample seeds" begin
    mktempdir() do root
        geometry = joinpath(root, "geo")
        other = joinpath(root, "other")
        mkpath(geometry)
        mkpath(other)
        write(joinpath(geometry, "Geo.jl"), "include(\"counts.jl\")\ninclude(\"seeds.jl\")")
        write(joinpath(geometry, "counts.jl"), "const GRID_COUNT = 12\nconst ITER_CAP = 64")
        write(joinpath(geometry, "seeds.jl"), """
        by_const() = [k / GRID_COUNT for k in 0:GRID_COUNT]
        literal() = [k / 16 for k in 0:16]
        by_range() = range(0.0, 1.0; length=GRID_COUNT)
        by_linrange() = LinRange(0.0, 1.0, GRID_COUNT)
        span_grid(lo, hi) = range(lo, hi; length=GRID_COUNT)
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
            [k / (count - 1) for k in 0:count-1]
        end
        caller_grid(count) = [k / count for k in 0:count]
        shadowed(GRID_COUNT) = [k / GRID_COUNT for k in 0:GRID_COUNT]
        native_breaks(knots) = [refine(knots[k], knots[k+1]) for k in 1:length(knots)-1]
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
        """)
        write(joinpath(other, "Other.jl"), "include(\"seeds.jl\")")
        write(joinpath(other, "seeds.jl"), """
        const OWN_COUNT = 20
        separate() = [k / OWN_COUNT for k in 0:OWN_COUNT]
        unknown() = [k / GRID_COUNT for k in 0:GRID_COUNT]
        """)
        index = ArchCheck.build_source_index(root, Dict(:Geo => 1, :Other => 2),
                                   Dict("geo" => :Geo, "other" => :Other))
        found = ArchCheck.check_scan_seeds(index; directories=(geometry,))
        expected = Set(["by_const", "literal", "by_range", "by_linrange", "span_grid",
                        "local_grid", "step_grid", "adjacent_grid", "quotes_equals"])
        @test Set(finding.symbol for finding in found) == expected
        @test all(finding -> finding.kind === :scan_seed, found)
        @test length(unique(ArchCheck.fingerprint.(found))) == length(found)
        together = ArchCheck.check_scan_seeds(index; directories=(geometry, other))
        @test Set(finding.symbol for finding in together) == union(expected, Set(["separate"]))
    end
end
