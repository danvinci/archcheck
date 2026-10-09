# The report: a kind's severity, and the delta against the previous run.

struct UndeclaredDrop <: Check end

function ArchCheck.run(::UndeclaredDrop, ctx)
    [Finding(:M, :uncounted_drop, "a.jl", "g", "guard")]
end

function ArchCheck.kinds(::UndeclaredDrop)
    ()
end

struct ScriptedReport <: Check end

const SCRIPTED_FOUND = Ref{Vector{Finding}}(Finding[])

function ArchCheck.run(::ScriptedReport, ctx)
    SCRIPTED_FOUND[]
end

function ArchCheck.kinds(::ScriptedReport)
    (:tuple_return => :advisory, :dead_code => :advisory, :file_backedge => :advisory)
end

const REPORT_HOST = load_package("ReportHost", "ready() = 1\n")

function gate_scripted(found, report, io)
    SCRIPTED_FOUND[] = found
    ArchCheck.gate(REPORT_HOST.pkg; report_path = report, io, checks = (ScriptedReport(),))
end

@testset "a kind its check does not declare is refused" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    @test_throws ArgumentError ArchCheck.gate(REPORT_HOST.pkg; report_path = report,
                                              io = devnull, checks = (UndeclaredDrop(),))
end

@testset "error_kinds promotes a declared kind and refuses an unknown one" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (StaleExports(),)
    passed = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    @test any(finding -> finding.kind === :stale_export, passed)
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                                error_kinds = (:stale_export,))
    records = [JSON.parse(line) for line in eachline(report)]
    @test all(record -> record["severity"] == "error", records)
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                               error_kinds = (:stale_exprt,))
end

@testset "the report counts a moved finding as standing and a new symbol of a known kind as new" begin
    wide = Finding(:Geo, :tuple_return, "a.jl", "wide", 10, "3 slots")
    gone = Finding(:Geo, :dead_code, "a.jl", "gone", 20, "unused")
    moved = Finding(:Geo, :tuple_return, "a.jl", "wide", 99, "3 slots")
    fresh = Finding(:Aero, :file_backedge, "solve.jl", "model.jl", 0, "up-rank")
    later = Finding(:Aero, :file_backedge, "solve.jl", "influence.jl", 0, "up-rank")
    report = joinpath(mktempdir(), "architecture.jsonl")

    first_io = IOBuffer()
    gate_scripted([wide, gone], report, first_io)
    first_text = String(take!(first_io))
    @test occursin("new 0", first_text)
    @test occursin("fixed 0", first_text)
    @test occursin("standing 2", first_text)

    second_io = IOBuffer()
    gate_scripted([moved], report, second_io)
    second_text = String(take!(second_io))
    @test occursin("new 0", second_text)
    @test occursin("fixed 1", second_text)
    @test occursin("standing 1", second_text)

    third_io = IOBuffer()
    gate_scripted([moved, fresh], report, third_io)
    third_text = String(take!(third_io))
    @test !occursin("NEW", third_text)
    @test occursin("file_backedge 1", third_text)

    fourth_io = IOBuffer()
    gate_scripted([moved, fresh, later], report, fourth_io)
    fourth_text = String(take!(fourth_io))
    @test occursin("new 1", fourth_text)
    @test occursin("NEW", fourth_text)
    @test occursin("solve.jl", fourth_text)
    @test occursin("tuple_return 1", fourth_text)
    @test !occursin("wide", fourth_text)
end
