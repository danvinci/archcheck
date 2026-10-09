# The report: a kind's severity, and the delta against the previous run.

# A consumer check whose declaration leaves out the kind its run emits.
module FConsumer
    using ArchCheck
    struct Undeclared <: ArchCheck.Check end
    ArchCheck.run(::Undeclared, ctx) = [Finding(:M, :uncounted_drop, "a.jl", "g", "guard")]
    ArchCheck.kinds(::Undeclared) = ()
end

@testset "severity: a kind its check does not declare is refused" begin
    @test_throws ArgumentError ArchCheck.run_checks(nothing, (FConsumer.Undeclared(),))
end

@testset "severity: error_kinds promotes a consumer's kinds" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.StaleExports(),)
    passed = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    @test any(f -> f.kind === :stale_export, passed)
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                                error_kinds = (:stale_export,))
    records = [JSON.parse(line) for line in eachline(report)]
    @test all(r -> r["severity"] == "error", records)
    # a kind no running check declares is a typo, so it throws
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                               error_kinds = (:stale_exprt,))
end

@testset "delta vs the previous run" begin
    old = [Finding(:Geo, :tuple_return, "a.jl", "wide", 10, "3 slots"),
           Finding(:Geo, :dead_code, "a.jl", "gone", 20, "unused")]
    # same finding, moved down the file: the line drifts, the ArchCheck.fingerprint does not
    moved = Finding(:Geo, :tuple_return, "a.jl", "wide", 99, "3 slots")
    fresh = Finding(:Aero, :file_backedge, "solve.jl", "model.jl", 0, "up-rank")

    severity = default_severity()
    mktempdir() do dir
        path = joinpath(dir, "architecture.jsonl")
        @test isnothing(ArchCheck.previous_fingerprints(path))        # no previous run -> nothing is new

        open(io -> emit_jsonl(io, old, severity), path, "w")
        prev = ArchCheck.previous_fingerprints(path)
        @test isempty(ArchCheck.new_findings([moved], prev))       # same finding, drifted line -> not new

        # a kind absent from the previous run belongs to a check added since: its findings enter
        # as standing, so adding a check leaves that kind off the new-finding list
        @test isempty(ArchCheck.new_findings([fresh], prev))
        withknown = vcat(old, fresh)
        open(io -> emit_jsonl(io, withknown, severity), path, "w")
        prev2 = ArchCheck.previous_fingerprints(path)
        later = Finding(:Aero, :file_backedge, "solve.jl", "influence.jl", 0, "up-rank")
        @test [f.symbol for f in ArchCheck.new_findings([fresh, later], prev2)] == ["influence.jl"]

        current = Set(ArchCheck.fingerprint(f) for f in [moved, fresh])
        @test length(setdiff(prev, current)) == 1        # dead_code disappeared -> fixed
    end

    # the report prints the delta in full and the standing set as counts
    io = IOBuffer()
    print_architecture(io, [moved, fresh], [fresh], 1, Dict(:Aero => [1], :Geo => [2]), severity)
    out = String(take!(io))
    @test occursin("new 1", out) && occursin("fixed 1", out) && occursin("standing 1", out)
    @test occursin("NEW", out) && occursin("solve.jl", out)   # new one named
    @test occursin("tuple_return 1", out) && !occursin("wide", out)   # standing counted, not listed
end
