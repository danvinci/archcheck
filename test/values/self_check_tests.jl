# ArchCheck holds itself to its own gate: every check it ships, every kind promoted to error.

@testset "self-check: ArchCheck's gate passes on ArchCheck with every kind an error" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    every_kind = Tuple(keys(ArchCheck.severities(CHECKS)))
    passes = try
        ArchCheck.gate(ArchCheck; report_path = report, io = IOBuffer(), error_kinds = every_kind)
        true
    catch err
        err isa ErrorException || rethrow()
        false
    end
    # the self-standard lane brings the standing findings to zero and turns this into a plain test
    @test_broken passes
end
