# Members of an independent set do not reference one another.
@testset "independent modules: no member of the set references another" begin
    src = joinpath(pkgdir(Nested), "src")
    graph = ArchCheck.build_module_graph(src, joinpath(src, "Nested.jl"))
    edges(modules...) = ArchCheck.run_checks((graph = graph,), (Independent(modules...),))
    curves = Symbol("Geo.Curves")
    cuts = Symbol("Geo.Cuts")

    # Geo reaches Low, which is outside the set; Contracts reaches nothing
    @test isempty(edges(:Contracts, :Geo))

    # Curves calls `Cuts.cut_only` by its qualified name
    between = edges(curves, cuts)
    qualified = only(f for f in between if ev(f, :via) == "qualified")
    @test qualified.kind === :sibling_edge && qualified.mod === curves
    @test (qualified.file, qualified.line) == ("src/geo/curves/curve.jl", 15)
    @test (ev(qualified, :from), ev(qualified, :to)) == ("Geo.Curves", "Geo.Cuts")

    # Geo.Curves imports Low from inside Geo, apart from Geo's own `using ..Low`
    through = edges(:Low, :Geo)
    inner = only(f for f in through if f.mod === curves && ev(f, :via) == "using")
    @test (inner.file, inner.line) == ("src/geo/curves/Curves.jl", 3)
    @test (ev(inner, :from), ev(inner, :to)) == ("Geo", "Low")
    # and Hi's `Geo.Curves._secret` reaches into Geo's tree
    into = edges(:Hi, :Geo)
    @test any(f -> f.symbol == "Geo.Curves" && ev(f, :to) == "Geo", into)

    # both reach Shared, which sits below the set
    rank = Dict(:Shared => [1], :A => [2], :B => [3])
    dir2mod = Dict("shared" => :Shared, "a" => :A, "b" => :B)
    refs = [ArchCheck.ModRef(:A, :Shared, "src/a/a.jl", 1, :using), ArchCheck.ModRef(:B, :Shared, "src/b/b.jl", 2, :qualified)]
    lower = ArchCheck.ModuleGraph(rank, dir2mod, refs)
    @test isempty(ArchCheck.run_checks((graph = lower,), (Independent(:A, :B),)))

    # a set that cannot constrain anything, or names a module the graph lacks, is refused
    @test_throws ArgumentError Independent(:Geo)
    @test_throws ArgumentError Independent(:Geo, curves)
    @test_throws ArgumentError edges(:Contracts, :Goe)
end
