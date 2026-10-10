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

const SHARED_HUB = load_package("SharedHub", """
    include("hub.jl")
    include("c.jl")
    include("b.jl")
    include("a.jl")
    """, [
    "hub.jl" => "hub_fn() = 1\n",
    "c.jl" => "leaf_fn() = 1\nfrom_c() = hub_fn()\n",
    "b.jl" => "from_b() = hub_fn()\n",
    "a.jl" => "from_a() = hub_fn()\nstray() = leaf_fn()\n",
])

@testset "a callee file more than half the module reaches is shared vocabulary" begin
    ctx = case_context(SHARED_HUB)
    found = ArchCheck.run(FileSinkable(), ctx)
    @test evidence_rows(found, :callees_in, :files_using_it) == [(:file_sinkable, "stray", "c.jl", "1/4")]
end
