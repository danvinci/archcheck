# A declared producer's calls record hash(key(args...; kwargs...)). Equal geometry behind two pointers
# stays quiet until the producer declares a key over the numbers.

const HANDLE_WIDTH = 3.0
const HANDLE_HEIGHT = 4.0
const SCALE_MATCHED = 2.0
const SCALE_OTHER = 3.0
const POINTER_LEFT = 11
const POINTER_RIGHT = 29
const OTHER_SAMPLE = [1, 2, 3]

const KEYED_SOURCE = """
mutable struct Handle
    width::Float64
    height::Float64
    solid::Ptr{Cvoid}
end

function build(handle::Handle; scale::Float64 = 1.0)
    Ref(handle.width * scale)
end

function other(xs)
    xs
end

function geometry_key(handle::Handle; scale::Float64 = 1.0)
    (handle.width * scale, handle.height)
end

function separating_key(handle::Handle; scale::Float64 = 1.0)
    (handle.width, handle.height, scale, UInt(handle.solid))
end

function breaking_key(handle::Handle; scale::Float64 = 1.0)
    error("broken key")
end
"""

function load_keyed()
    directory = mktempdir()
    src = joinpath(directory, "src")
    mkdir(src)
    path = joinpath(src, "KeyedHandles.jl")
    write(path, KEYED_SOURCE)
    mod = Module(:KeyedHandles)
    Base.include(mod, path)
    layout = ArchCheck.package_layout(path, :KeyedHandles)
    rank = layout[1]
    dir2mod = layout[2]
    index = build_source_index(src, rank, dir2mod; root = :KeyedHandles)
    ctx = Context(index, mod, Module[mod])
    (; mod, ctx, index)
end

function keyed_context(loaded, derived)
    Context(loaded.index, loaded.mod, Module[loaded.mod]; derived = derived)
end

function handle_pair(mod)
    left = mod.Handle(HANDLE_WIDTH, HANDLE_HEIGHT, Ptr{Cvoid}(POINTER_LEFT))
    right = mod.Handle(HANDLE_WIDTH, HANDLE_HEIGHT, Ptr{Cvoid}(POINTER_RIGHT))
    (; left, right)
end

function trace_calls(body, ctx, probes)
    armed = ArchCheck.arm!(probes, ctx)
    local traced
    local returned
    try
        returned = body()
    finally
        traced = ArchCheck.disarm!(armed)
    end
    (; records = traced.records, returned)
end

function rebuild_findings(ctx, records)
    reached = Set{Method}()
    waits = WaitRecord[]
    observed = Observation(reached, records, waits, 1.0)
    ran = Context(ctx; observed)
    ArchCheck.run(Rebuilds(), ran)
end

function call_builds(mod, handles, scale)
    Base.invokelatest(mod.build, handles.left; scale = scale)
    Base.invokelatest(mod.build, handles.right; scale = scale)
    nothing
end

function findings_named(findings, symbol)
    matched = Finding[]
    for finding in findings
        finding.symbol == symbol || continue
        push!(matched, finding)
    end
    matched
end

function records_named(records, name::Symbol)
    matched = ProbeRecord[]
    for record in records
        record.name === name || continue
        push!(matched, record)
    end
    matched
end

@testset "keyed: an undeclared producer keeps the content hash and stays quiet" begin
    loaded = load_keyed()
    mod = loaded.mod
    handles = handle_pair(mod)
    probes = Probes(; functions = (mod.build,), slow_s = 0.0)
    traced = trace_calls(loaded.ctx, probes) do
        call_builds(mod, handles, SCALE_MATCHED)
    end
    quiet = rebuild_findings(loaded.ctx, traced.records)
    @test isempty(quiet)
    built = records_named(traced.records, :build)
    @test length(built) == 2
    @test built[1].arguments != built[2].arguments

    bare = (Derived(mod.build),)
    ctx = keyed_context(loaded, bare)
    plain = trace_calls(ctx, probes) do
        call_builds(mod, handles, SCALE_MATCHED)
    end
    still = rebuild_findings(ctx, plain.records)
    @test isempty(still)
end

@testset "keyed: a key over the geometry numbers fires, and a different keyword stays quiet" begin
    loaded = load_keyed()
    mod = loaded.mod
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.geometry_key),)
    ctx = keyed_context(loaded, declared)
    probes = Probes(; functions = (mod.other,), slow_s = 0.0)
    traced = trace_calls(ctx, probes) do
        call_builds(mod, handles, SCALE_MATCHED)
        call_builds(mod, handles, SCALE_OTHER)
        Base.invokelatest(mod.other, OTHER_SAMPLE)
        Base.invokelatest(mod.other, [1, 2, 3])
    end
    built = records_named(traced.records, :build)
    @test length(built) == 4
    matched = hash((HANDLE_WIDTH * SCALE_MATCHED, HANDLE_HEIGHT))
    other_scale = hash((HANDLE_WIDTH * SCALE_OTHER, HANDLE_HEIGHT))
    @test built[1].arguments == matched
    @test built[2].arguments == matched
    @test built[3].arguments == other_scale
    @test built[4].arguments == other_scale
    others = records_named(traced.records, :other)
    @test length(others) == 2
    @test others[1].arguments == others[2].arguments
    fired = rebuild_findings(ctx, traced.records)
    build_hits = findings_named(fired, "build")
    build_hit = only(build_hits)
    @test ev(build_hit, :function) == "build"
    # Two scales each repeat once. One shared hash would count the later three calls.
    @test ev(build_hit, :repeats) == "2"
    other_hits = findings_named(fired, "other")
    @test length(other_hits) == 1
    @test ev(other_hits[1], :repeats) == "1"
end

@testset "keyed: a key that separates the two calls stays quiet" begin
    loaded = load_keyed()
    mod = loaded.mod
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.separating_key),)
    ctx = keyed_context(loaded, declared)
    probes = Probes(; functions = (), slow_s = 0.0)
    traced = trace_calls(ctx, probes) do
        call_builds(mod, handles, SCALE_MATCHED)
    end
    quiet = rebuild_findings(ctx, traced.records)
    @test isempty(quiet)
end

function thrown_key(mod, handle)
    try
        Base.invokelatest(mod.build, handle; scale = SCALE_MATCHED)
        nothing
    catch err
        return err
    end
end

@testset "keyed: a key that throws names the producer and the key" begin
    loaded = load_keyed()
    mod = loaded.mod
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.breaking_key),)
    ctx = keyed_context(loaded, declared)
    probes = Probes(; functions = (), slow_s = 0.0)
    traced = trace_calls(ctx, probes) do
        thrown_key(mod, handles.left)
    end
    thrown = traced.returned
    @test thrown isa ArgumentError
    text = sprint(showerror, thrown)
    @test occursin("breaking_key", text)
    @test occursin("producer build", text)
end
