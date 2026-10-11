# A nested module keeps the rank its wrapper declares.

@testset "a nested module keeps the rank its wrapper declares" begin
    ctx = Context(Nested)
    backs = ArchCheck.run(ModuleBackEdges(), ctx)
    orders = evidence_rows(backs, :include_order)
    @test orders == [(:back_edge, "Geo.Cuts", "1.3.1->1.3.2")]

    corpus = ArchCheck.run(Corpus(), ctx)
    @test !any(finding -> finding.kind === :unranked_module, corpus)

    files = ArchCheck.run(FileBackEdges(), ctx)
    edges = Set((edge.mod, basename(edge.file), basename(edge.symbol)) for edge in files)
    @test edges == Set([(Symbol("Geo.Cuts"), "ring.jl", "measure.jl"), (Symbol("Geo.Curves"), "curve.jl", "Cuts.jl")])

    required = ((Nested.Geo.Curves.perimeter, Tuple{}),)
    readers = ReaderSet(Nested.Geo.Curves.Shape, required)
    read = ArchCheck.run(readers, ctx)
    ring = only(finding for finding in read if finding.symbol == "Ring.perimeter")
    @test ring.kind === :reader_set
    @test ev(ring, :reader) == "perimeter"
end
