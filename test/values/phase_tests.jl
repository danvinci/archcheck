# A check runs before the workload or after it; the gate refuses a run that cannot place every check.

module FPhase
    using ArchCheck
    struct AfterRun <: ArchCheck.Check end
    ArchCheck.run(::AfterRun, ctx) = Finding[]
    ArchCheck.kinds(::AfterRun) = (:after_run => :advisory,)
    ArchCheck.phase(::AfterRun) = :workload
    struct Misplaced <: ArchCheck.Check end
    ArchCheck.run(::Misplaced, ctx) = Finding[]
    ArchCheck.kinds(::Misplaced) = (:misplaced => :advisory,)
    ArchCheck.phase(::Misplaced) = :later
end

@testset "the gate refuses a run that cannot place every check" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    # a workload check with no workload; probes with no workload; a phase the gate does not know
    refusals = (
        ((FPhase.AfterRun(),), nothing),
        ((ArchCheck.Corpus(),), Probes(functions = ())),
        ((FPhase.Misplaced(),), nothing),
    )
    for (checks, probes) in refusals
        @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = quiet,
                                                   checks, probes)
    end
end
