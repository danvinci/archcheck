# A check runs before the workload or after it; the gate refuses a run that cannot place every check.

module PhaseChecks
    using ArchCheck
    struct AfterRun <: Check end
    ArchCheck.run(::AfterRun, ctx) = Finding[]
    ArchCheck.kinds(::AfterRun) = (:after_run => :advisory,)
    ArchCheck.phase(::AfterRun) = :workload
    struct Misplaced <: Check end
    ArchCheck.run(::Misplaced, ctx) = Finding[]
    ArchCheck.kinds(::Misplaced) = (:misplaced => :advisory,)
    ArchCheck.phase(::Misplaced) = :later
    struct Stray <: Check end
    function ArchCheck.run(::Stray, ctx)
        found = Finding(:Nested, :stray_kind, "x.jl", "x", 1, "a kind this check does not declare")
        Finding[found]
    end
    ArchCheck.kinds(::Stray) = (:kept_kind => :advisory,)
end

@testset "the gate refuses a run that cannot place every check" begin
    # a workload check with no workload; probes with no workload; an unknown phase;
    # a finding kind outside the kinds the check declares
    refusals = (
        ((PhaseChecks.AfterRun(),), nothing),
        ((Corpus(),), Probes(functions = ())),
        ((PhaseChecks.Misplaced(),), nothing),
        ((PhaseChecks.Stray(),), nothing),
    )
    for (checks, probes) in refusals
        @test_throws ArgumentError gate_findings(Nested; checks, probes)
    end
end
