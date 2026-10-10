# ArchCheck holds itself to its own gate: every check it ships, configured for this package, finds nothing.

gate_file = joinpath(@__DIR__, "..", "self_gate.jl")
if !isdefined(@__MODULE__, :self_checks)
    include(gate_file)
end

@testset "self-check: ArchCheck's full gate on ArchCheck finds nothing" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    self_gate(; report_path = report, io = devnull)
    @test readlines(report) == String[]
end

@testset "self-check: Fatou's lint of the repository finds nothing" begin
    linter = Sys.which("fatou")
    @test !isnothing(linter)
    if !isnothing(linter)
        root = pkgdir(ArchCheck)
        output = IOBuffer()
        command = Cmd(`$linter lint --color never --quiet .`; dir = root)
        unchecked = ignorestatus(command)
        piped = pipeline(unchecked; stdout = output, stderr = output)
        finished = run(piped)
        report = String(take!(output))
        @test finished.exitcode == 0
        finished.exitcode == 0 || println(report)
    end
end

@testset "self-check: the self-gate's probes report a second parse of the same files" begin
    parse_twice = function ()
        Context(Nested)
        Context(Nested)
    end
    checks = (Rebuilds(),)
    probes = self_probes()
    found = gate_findings(ArchCheck; checks, probes, workload = parse_twice)
    rebuilt = Set(finding.symbol for finding in found)
    @test "parse_file" in rebuilt
end

@testset "self-check: every exported check is run or named inapplicable" begin
    held = Set{Any}()
    for pair in NOT_APPLICABLE
        push!(held, pair[1])
    end
    unlisted = String[]
    for name in names(ArchCheck)
        value = getfield(ArchCheck, name)
        body = value isa UnionAll ? Base.unwrap_unionall(value) : value
        body isa DataType || continue
        body <: Check || continue
        isabstracttype(body) && continue
        ran = false
        for check in self_checks()
            if check isa value
                ran = true
            end
        end
        ran && continue
        value in held && continue
        push!(unlisted, string(name))
    end
    sort!(unlisted)
    @test unlisted == String[]
end

@testset "an exported check type carries a docstring" begin
    undocumented = String[]
    for name in names(ArchCheck)
        isdefined(ArchCheck, name) || continue
        value = getfield(ArchCheck, name)
        body = value isa UnionAll ? Base.unwrap_unionall(value) : value
        body isa DataType || continue
        body <: Check || continue
        isabstracttype(body) && continue
        binding = Base.Docs.Binding(ArchCheck, name)
        documented = haskey(Base.Docs.meta(ArchCheck), binding)
        documented && continue
        push!(undocumented, string(name))
    end
    sort!(undocumented)
    @test undocumented == String[]
end
