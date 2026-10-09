# A declared producer's calls record hash(key(args...; kwargs...)). Equal geometry behind two pointers
# stays quiet until the producer declares a key over the numbers.

const HANDLE_WIDTH = 3.0
const HANDLE_HEIGHT = 4.0
const SCALE_MATCHED = 2.0
const SCALE_OTHER = 3.0
const POINTER_LEFT = 11
const POINTER_RIGHT = 29
const OTHER_SAMPLE = [1, 2, 3]

const KEYED_HANDLE = load_package("KeyedHandle", """
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
    """)

function handle_pair(mod)
    left = mod.Handle(HANDLE_WIDTH, HANDLE_HEIGHT, Ptr{Cvoid}(POINTER_LEFT))
    right = mod.Handle(HANDLE_WIDTH, HANDLE_HEIGHT, Ptr{Cvoid}(POINTER_RIGHT))
    (; left, right)
end

function records_named(records, name::Symbol)
    matched = ProbeRecord[]
    for record in records
        record.name === name || continue
        push!(matched, record)
    end
    matched
end

function call_builds(mod, handles, scale)
    mod.build(handles.left; scale = scale)
    mod.build(handles.right; scale = scale)
    nothing
end

@testset "an undeclared producer keeps the content hash and stays quiet" begin
    mod = KEYED_HANDLE.pkg
    handles = handle_pair(mod)
    probes = Probes(; functions = (mod.build,), slow_s = 0.0)
    matched_builds = function ()
        call_builds(mod, handles, SCALE_MATCHED)
    end
    quiet_run = observed_gate(mod; checks = (Rebuilds(),), probes,
                              workload = matched_builds, derived = ())
    @test isempty(quiet_run.findings)
    built = records_named(quiet_run.observed.records, :build)
    @test length(built) == 2
    @test built[1].arguments != built[2].arguments

    bare = (Derived(mod.build),)
    plain_run = observed_gate(mod; checks = (Rebuilds(),), probes,
                              workload = matched_builds, derived = bare)
    @test isempty(plain_run.findings)
    plain_built = records_named(plain_run.observed.records, :build)
    @test length(plain_built) == 2
    @test plain_built[1].arguments != plain_built[2].arguments
end

@testset "a key over the geometry numbers fires, and a different keyword stays quiet" begin
    mod = KEYED_HANDLE.pkg
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.geometry_key),)
    probes = Probes(; functions = (mod.other,), slow_s = 0.0)
    mixed_calls = function ()
        call_builds(mod, handles, SCALE_MATCHED)
        call_builds(mod, handles, SCALE_OTHER)
        mod.other(OTHER_SAMPLE)
        mod.other([1, 2, 3])
    end
    fired_run = observed_gate(mod; checks = (Rebuilds(),), probes,
                              workload = mixed_calls, derived = declared)
    built = records_named(fired_run.observed.records, :build)
    @test length(built) == 4
    matched = hash((HANDLE_WIDTH * SCALE_MATCHED, HANDLE_HEIGHT))
    other_scale = hash((HANDLE_WIDTH * SCALE_OTHER, HANDLE_HEIGHT))
    @test built[1].arguments == matched
    @test built[2].arguments == matched
    @test built[3].arguments == other_scale
    @test built[4].arguments == other_scale
    others = records_named(fired_run.observed.records, :other)
    @test length(others) == 2
    @test others[1].arguments == others[2].arguments
    rows = evidence_rows(fired_run.findings, :function, :repeats)
    @test rows == [
        (:rebuild, "build", "build", "2"),
        (:rebuild, "other", "other", "1"),
    ]
end

@testset "a key that separates the two calls stays quiet" begin
    mod = KEYED_HANDLE.pkg
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.separating_key),)
    probes = Probes(; functions = (), slow_s = 0.0)
    separated_builds = function ()
        call_builds(mod, handles, SCALE_MATCHED)
    end
    quiet_run = observed_gate(mod; checks = (Rebuilds(),), probes,
                              workload = separated_builds, derived = declared)
    built = records_named(quiet_run.observed.records, :build)
    @test length(built) == 2
    @test built[1].arguments != built[2].arguments
    @test isempty(quiet_run.findings)
end

@testset "a key that throws names the producer and the key" begin
    mod = KEYED_HANDLE.pkg
    handles = handle_pair(mod)
    declared = (Derived(mod.build; key = mod.breaking_key),)
    probes = Probes(; functions = (), slow_s = 0.0)
    caught = Ref{Any}(nothing)
    breaking_build = function ()
        try
            mod.build(handles.left; scale = SCALE_MATCHED)
            caught[] = nothing
        catch err
            caught[] = err
        end
    end
    observed_gate(mod; checks = (Rebuilds(),), probes,
                  workload = breaking_build, derived = declared)
    thrown = caught[]
    @test thrown isa ArgumentError
    text = sprint(showerror, thrown)
    @test occursin("breaking_key", text)
    @test occursin("producer build", text)
end
