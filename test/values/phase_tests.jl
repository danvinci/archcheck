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

@testset "phase: every check runs before or after the workload" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    @test ArchCheck.phase(ArchCheck.Corpus()) === :static
    # a check reading what the workload did, with no workload declared
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = quiet,
                                               checks = (FPhase.AfterRun(),))
    # probes with nothing to observe
    probes = Probes(functions = ())
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = quiet,
                                               checks = (ArchCheck.Corpus(),), probes)
    # a phase the gate does not know is a typo
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = quiet,
                                               checks = (FPhase.Misplaced(),))
end
