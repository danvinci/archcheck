# A declared role reaches only its readers and its converters.

module RoleWrap
    struct Bound
        meters::Float64   # wrapped distance, metres
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
        Main.RoleOther.consume(bound)
    end
end

module RoleOther
    consume(x::Main.RoleWrap.Bound) = x.meters
end

module RoleBare
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
end

function role_lines(lines)
    joined = join(lines, "\n")
    joined * "\n"
end

function role_index(files, rank, dir2mod)
    root = mktempdir()
    src = joinpath(root, "src")
    for pair in files
        rel = pair.first
        text = pair.second
        path = joinpath(src, rel)
        mkpath(dirname(path))
        write(path, text)
    end
    ArchCheck.build_source_index(src, rank, dir2mod)
end

function role_rows(found)
    rows = Tuple{String,String,String,String}[]
    for finding in found
        product = ev(finding, :derived)
        callee = ev(finding, :callee)
        via = ev(finding, :via)
        row = (finding.symbol, callee, via, product)
        push!(rows, row)
    end
    sort!(rows)
end

function wrap_files()
    lines = ["placeholder() = 1"]
    ["wrap/Wrap.jl" => role_lines(lines)]
end

function wrap_product()
    readers = (RoleWrap.consume,)
    converters = (RoleWrap.bridge,)
    Derived(RoleWrap.distance; readers, converters)
end

function wrap_entries()
    (
        (RoleWrap.pass_consumer, Tuple{Float64,Float64}),
        (RoleWrap.pass_other, Tuple{Float64,Float64}),
        (RoleWrap.pass_bridge, Tuple{Float64,Float64}),
        (RoleWrap.pass_miss, Tuple{Float64,Float64}),
        (RoleWrap.pass_homonym, Tuple{Float64,Float64}),
    )
end

function wrap_index()
    files = wrap_files()
    rank = Dict(:RoleWrap => 1)
    dirs = Dict("wrap" => :RoleWrap)
    role_index(files, rank, dirs)
end

@testset "a wrapper passed to a consumer or a bridge stays quiet" begin
    index = wrap_index()
    entries = wrap_entries()
    graph = ArchCheck.method_graph(entries, (RoleWrap,))
    product = wrap_product()
    derived = (product,)
    ctx = Context(index, Main, Module[]; methods = graph, derived)
    found = ArchCheck.run(ArchCheck.DerivedReaders(), ctx)
    rows = role_rows(found)
    expected = [
        ("pass_homonym", "consume", "code_typed", "distance"),
        ("pass_miss", "wants", "code_typed", "distance"),
        ("pass_other", "other", "code_typed", "distance"),
    ]
    @test rows == expected
end

@testset "a wrapper role with no method graph names the missing entries" begin
    index = wrap_index()
    product = wrap_product()
    derived = (product,)
    ctx = Context(index, Main, Module[]; derived)
    caught = try
        ArchCheck.run(ArchCheck.DerivedReaders(), ctx)
        nothing
    catch err
        err
    end
    @test caught isa ArgumentError
    @test occursin("entries", caught.msg)
end

@testset "no declared product is quiet" begin
    index = wrap_index()
    ctx = Context(index, Main, Module[])
    found = ArchCheck.run(ArchCheck.DerivedReaders(), ctx)
    @test isempty(found)
end

function bare_source()
    lines = [
        "lower_bound(a::Float64, b::Float64) = min(a, b)",
        "consume(x::Float64) = x",
        "bridge(x::Float64) = x",
        "function kept(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    consume(bound)",
        "end",
        "function leaked(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    solver(; margin = bound)",
        "end",
        "solver(; margin::Float64) = margin",
        "function bridged(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    bare = bridge(bound)",
        "    solver(; margin = bare)",
        "end",
        "function returned(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    return bound",
        "end",
        "function returned_bridged(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    bridge(bound)",
        "    return bound",
        "end",
        "function stored(obj, a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    obj.field = bound",
        "end",
        "function splatted(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    tuple(bound...)",
        "end",
        "function broadcasted(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    bound .+ 1",
        "end",
        "function shadowed(a::Float64, b::Float64)",
        "    bound = lower_bound(a, b)",
        "    reader = bound -> solver(bound)",
        "    return bound",
        "end",
    ]
    role_lines(lines)
end

@testset "a bare bound passed to a margin parameter is a leak" begin
    text = bare_source()
    files = ["bare/Bare.jl" => text]
    rank = Dict(:RoleBare => 1)
    dirs = Dict("bare" => :RoleBare)
    index = role_index(files, rank, dirs)
    readers = (RoleBare.consume,)
    converters = (RoleBare.bridge,)
    product = Derived(RoleBare.lower_bound; readers, converters)
    derived = (product,)
    ctx = Context(index, Main, Module[]; derived)
    found = ArchCheck.run(ArchCheck.DerivedReaders(), ctx)
    rows = role_rows(found)
    expected = [
        ("broadcasted", "broadcast", "parse", "lower_bound"),
        ("leaked", "solver", "parse", "lower_bound"),
        ("returned", "return", "parse", "lower_bound"),
        ("shadowed", "return", "parse", "lower_bound"),
        ("splatted", "splat", "parse", "lower_bound"),
        ("stored", "field", "parse", "lower_bound"),
    ]
    @test rows == expected
end

function outside_source()
    lines = [
        "function build()",
        "    Bound(1.0)",
        "end",
        "function read_field(value::Bound)",
        "    value.meters",
        "    getfield(value, :meters)",
        "end",
    ]
    role_lines(lines)
end

function inside_source()
    lines = [
        "function build_inside()",
        "    Bound(1.0)",
        "end",
    ]
    role_lines(lines)
end

@testset "a constructor or a field read outside the producer module is a leak" begin
    outside = outside_source()
    inside = inside_source()
    files = [
        "outside/Outside.jl" => outside,
        "owner/Owner.jl" => inside,
    ]
    rank = Dict(:RoleOutside => 1, :RoleWrap => 2)
    dirs = Dict("outside" => :RoleOutside, "owner" => :RoleWrap)
    index = role_index(files, rank, dirs)
    edges = Dict{Method,Set{Method}}()
    unresolved = Dict{Method,Set{Symbol}}()
    graph = ArchCheck.MethodGraph(edges, unresolved)
    product = wrap_product()
    derived = (product,)
    ctx = Context(index, Main, Module[]; methods = graph, derived)
    found = ArchCheck.run(ArchCheck.DerivedReaders(), ctx)
    rows = role_rows(found)
    expected = [
        ("build", "Bound", "field", "distance"),
        ("read_field", "getfield", "field", "distance"),
        ("read_field", "meters", "field", "distance"),
    ]
    @test rows == expected
end
