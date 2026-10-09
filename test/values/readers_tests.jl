# A declared value reaches only its readers and its converters.

const WRAPPED_BOUND = load_package("WrappedBound", """
    struct Bound
        meters::Float64
    end
    function distance(a::Float64, b::Float64)
        meters = min(a, b)
        Bound(meters)
    end
    consume(x::Bound) = x.meters
    bridge(x::Bound) = x.meters
    other(x::Bound) = x.meters
    wants(x::Float64) = x
    function pass_consumer(a::Float64, b::Float64)
        bound = distance(a, b)
        consume(bound)
    end
    function pass_other(a::Float64, b::Float64)
        bound = distance(a, b)
        other(bound)
    end
    function pass_bridge(a::Float64, b::Float64)
        bound = distance(a, b)
        bare = bridge(bound)
        wants(bare)
    end
    function pass_miss(a::Float64, b::Float64)
        bound = distance(a, b)
        wants(bound)
    end
    function pass_homonym(a::Float64, b::Float64)
        bound = distance(a, b)
        OtherConsume.consume(bound)
    end
    module OtherConsume
    using ..WrappedBound: Bound
    consume(x::Bound) = x.meters
    end
    """)

const BARE_BOUND = load_package("BareBound", """
    lower_bound(a::Float64, b::Float64) = min(a, b)
    consume(x::Float64) = x
    bridge(x::Float64) = x
    function kept(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        consume(bound)
    end
    function leaked(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        solver(; margin = bound)
    end
    solver(; margin::Float64) = margin
    function bridged(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        bare = bridge(bound)
        solver(; margin = bare)
    end
    function returned(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        return bound
    end
    function returned_bridged(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        bridge(bound)
        return bound
    end
    function stored(obj, a::Float64, b::Float64)
        bound = lower_bound(a, b)
        obj.field = bound
    end
    function splatted(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        tuple(bound...)
    end
    function broadcasted(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        bound .+ 1
    end
    function shadowed(a::Float64, b::Float64)
        bound = lower_bound(a, b)
        reader = bound -> solver(bound)
        return bound
    end
    """)

const FIELD_OUTSIDE = load_package("FieldOutside", """
    struct Bound
        meters::Float64
    end
    function distance(a::Float64, b::Float64)
        Bound(min(a, b))
    end
    function build_inside()
        Bound(1.0)
    end
    include("outside/Outside.jl")
    using .Outside
    """, [
    "outside/Outside.jl" => """
        module Outside
        using ..FieldOutside: Bound
        function build()
            Bound(1.0)
        end
        function read_field(value::Bound)
            value.meters
            getfield(value, :meters)
        end
        end
        """,
])

function wrap_declared()
    pkg = WRAPPED_BOUND.pkg
    readers = (pkg.consume,)
    converters = (pkg.bridge,)
    Derived(pkg.distance; readers, converters)
end

function wrap_entries()
    pkg = WRAPPED_BOUND.pkg
    (
        (pkg.pass_consumer, Tuple{Float64,Float64}),
        (pkg.pass_other, Tuple{Float64,Float64}),
        (pkg.pass_bridge, Tuple{Float64,Float64}),
        (pkg.pass_miss, Tuple{Float64,Float64}),
        (pkg.pass_homonym, Tuple{Float64,Float64}),
    )
end

function reader_findings(case; entries = (), derived = ())
    ctx = case_context(case; entries, derived)
    check = DerivedReaders()
    ArchCheck.run(check, ctx)
end

@testset "a wrapper passed to a reader or a converter stays quiet" begin
    declared = (wrap_declared(),)
    entries = wrap_entries()
    found = reader_findings(WRAPPED_BOUND; entries, derived = declared)
    rows = evidence_rows(found, :callee, :via, :derived)
    @test rows == [
        (:unlisted_reader, "pass_homonym", "consume", "code_typed", "distance"),
        (:unlisted_reader, "pass_homonym", "consume", "parse", "distance"),
        (:unlisted_reader, "pass_miss", "wants", "code_typed", "distance"),
        (:unlisted_reader, "pass_miss", "wants", "parse", "distance"),
        (:unlisted_reader, "pass_other", "other", "code_typed", "distance"),
        (:unlisted_reader, "pass_other", "other", "parse", "distance"),
    ]
end

@testset "a wrapper with no method graph names the missing entries" begin
    declared = (wrap_declared(),)
    caught = try
        reader_findings(WRAPPED_BOUND; derived = declared)
        nothing
    catch err
        err
    end
    @test caught isa ArgumentError
    @test occursin("entries", caught.msg)
end

@testset "a bare number passed to an unlisted callee is reported" begin
    pkg = BARE_BOUND.pkg
    readers = (pkg.consume,)
    converters = (pkg.bridge,)
    declared = (Derived(pkg.lower_bound; readers, converters),)
    found = reader_findings(BARE_BOUND; derived = declared)
    rows = evidence_rows(found, :callee, :via, :derived)
    @test rows == [
        (:unlisted_reader, "broadcasted", "broadcast", "parse", "lower_bound"),
        (:unlisted_reader, "leaked", "solver", "parse", "lower_bound"),
        (:unlisted_reader, "returned", "return", "parse", "lower_bound"),
        (:unlisted_reader, "shadowed", "return", "parse", "lower_bound"),
        (:unlisted_reader, "splatted", "splat", "parse", "lower_bound"),
        (:unlisted_reader, "stored", "field", "parse", "lower_bound"),
    ]
end

@testset "a constructor or a field read outside the producer module is reported" begin
    pkg = FIELD_OUTSIDE.pkg
    declared = (Derived(pkg.distance),)
    entry = (pkg.distance, Tuple{Float64,Float64})
    entries = (entry,)
    found = reader_findings(FIELD_OUTSIDE; entries, derived = declared)
    rows = evidence_rows(found, :callee, :via, :derived)
    @test rows == [
        (:unlisted_reader, "build", "Bound", "field", "distance"),
        (:unlisted_reader, "read_field", "getfield", "field", "distance"),
        (:unlisted_reader, "read_field", "meters", "field", "distance"),
    ]
end
