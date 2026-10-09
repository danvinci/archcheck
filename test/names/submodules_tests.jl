# A nested package is visible to every check, at the rank its wrapper declares.
@testset "submodules: every check reads the nested package" begin
    readers = ReaderSet(Nested.Geo.Curves.Shape, ((Nested.Geo.Curves.perimeter, Tuple{}),))
    report = joinpath(mktempdir(), "architecture.jsonl")
    blocked = try
        ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks = (CHECKS..., readers))
        false
    catch err
        err isa ErrorException || rethrow()
        true
    end
    records = [JSON.parse(line) for line in eachline(report)]
    held(kind, mod, symbol) = any(r -> r["kind"] == kind && r["module"] == mod && r["symbol"] == symbol, records)

    # module zoom: a submodule sits at its parent's rank, then at its place in the parent's include order
    @test blocked
    back = only(r for r in records if r["kind"] == "back_edge")
    @test back["module"] == "Geo.Curves" && back["symbol"] == "Geo.Cuts"
    @test back["evidence"]["include_order"] == "3.1->3.2"
    @test !any(r -> r["kind"] == "unranked_module", records)

    # file zoom: a submodule's files rank by its own wrapper
    file_back = only(r for r in records if r["kind"] == "file_backedge")
    @test file_back["module"] == "Geo.Cuts"
    @test endswith(file_back["file"], "ring.jl") && endswith(file_back["symbol"], "measure.jl")

    # the reflection checks and the reader set see submodule definitions
    @test held("abstract_field", "Geo.Curves", "OpenBox.held")
    @test held("stale_export", "Geo.Curves", "vanished")
    @test held("reader_set", "Geo.Cuts", "Ring.perimeter")
    @test held("reaches_internal", "Geo.Curves", "Geo.Curves._secret")
    @test held("module_piracy", "Hi", "_lowpriv")
    # the root module is checked too: as the owner a submodule extends, and as the home extending a submodule
    @test held("module_piracy", "Hi", "root_measure")
    @test held("module_piracy", "Nested", "lowf")
    sink = only(r for r in records if r["kind"] == "sinkable" && r["symbol"] == "box_contents")
    @test sink["module"] == "Geo.Cuts" && sink["evidence"]["sinks_to"] == "Geo.Curves"

    # an import clause naming another module's underscore name, at either nesting, reports and lets the run pass
    private = filter(r -> r["kind"] == "private_import", records)
    @test Set((r["module"], r["symbol"]) for r in private) ==
          Set([("Geo.Curves", "Low._lowpriv"), ("Geo.Cuts", "Geo.Curves._secret")])
    @test all(r -> r["severity"] == "advisory", private)
end
