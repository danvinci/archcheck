# What one workload run compiled, and that a throwing workload still propagates.

module WorkedReach
    hit(x::Int) = x + 1
    miss(x::Int) = x + 2
    function keyed(x::Int; extra = 0)
        x + extra
    end
    onlykw(; extra = 0) = extra + 1
end

module WorkedEarly
    early(x::Int) = x + 3
    during(x::Int) = x + 4
end

module WorkedShow
    struct Mark end
    Base.show(io::IO, ::Mark) = print(io, "mark")
    other(x::Int) = x + 1
end

module FWorkload
    using ArchCheck
    struct SeesReached <: ArchCheck.Check end
    const REACHED = Ref{Union{Nothing,Set{Method}}}(nothing)
    function ArchCheck.run(::SeesReached, ctx)
        REACHED[] = ctx.observed.reached
        Finding[]
    end
    ArchCheck.kinds(::SeesReached) = (:seen_reached => :advisory,)
    ArchCheck.phase(::SeesReached) = :workload
end

function workload_context(root::Module)
    rank = Dict{Symbol,Vector{Int}}(nameof(root) => [1])
    dirs = Dict{String,Symbol}()
    files = FileNode[]
    refs = ModRef[]
    external = Set{Symbol}()
    unparsed = Tuple{Symbol,String}[]
    missing = Tuple{Symbol,String,String,Int}[]
    nonliteral = Tuple{Symbol,String,Int}[]
    index = SourceIndex("", rank, dirs, files, refs, external, unparsed, missing, nonliteral)
    Context(index, root, Module[root])
end

@testset "reached is exactly the methods compiled in the package, and records stay empty when nothing is probed" begin
    reach_ctx = workload_context(WorkedReach)
    function call_reached()
        WorkedReach.hit(1)
        WorkedReach.keyed(1; extra = 2)
        WorkedReach.onlykw(; extra = 4)
    end
    called = ArchCheck.observe(call_reached, nothing, reach_ctx)
    hit = only(methods(WorkedReach.hit))
    keyed = only(methods(WorkedReach.keyed))
    onlykw = only(methods(WorkedReach.onlykw))
    @test called.reached == Set([hit, keyed, onlykw])
    @test isempty(called.records)

    show_ctx = workload_context(WorkedShow)
    show_method = which(Base.show, (IO, WorkedShow.Mark))
    quiet = ArchCheck.observe(() -> WorkedShow.other(1), nothing, show_ctx)
    function show_mark()
        buffer = IOBuffer()
        show(buffer, WorkedShow.Mark())
    end
    shown = ArchCheck.observe(show_mark, nothing, show_ctx)

    early_ctx = workload_context(WorkedEarly)
    WorkedEarly.early(1)
    early = only(methods(WorkedEarly.early))
    compiled_before = ArchCheck.observe(() -> WorkedEarly.during(1), nothing, early_ctx)

    rows = (
        (reached = quiet.reached, method = show_method, is_in = false),
        (reached = shown.reached, method = show_method, is_in = true),
        (reached = compiled_before.reached, method = early, is_in = true),
    )
    for row in rows
        present = row.method in row.reached
        @test present == row.is_in
    end
end

@testset "a throwing workload propagates out of the gate" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    err = ErrorException("workload failed")
    checks = ()
    @test_throws err ArchCheck.gate(Nested; report_path = report, io = quiet, checks, workload = () -> throw(err))
end

@testset "a workload check reads the methods the workload reached" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    target = which(Nested.root_measure, (Int,))
    checks = (FWorkload.SeesReached(),)
    ArchCheck.gate(Nested; report_path = report, io = quiet, checks, workload = () -> Nested.root_measure(1))
    seen = FWorkload.REACHED[]
    @test target in seen
end
