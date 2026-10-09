# Overlapping calls and kept builders, over synthetic modules and a generated reach oracle.

function overlap_records(findings)
    found = Set{Tuple{String,String,String}}()
    for finding in findings
        calls = ev(finding, :calls)
        reaches = ev(finding, :reaches)
        push!(found, (finding.symbol, calls, reaches))
    end
    found
end

record_symbols(records) = Set(record[1] for record in records)

const CALL_BODY = """
function inner(xs::Vector{Int})
    total = 0
    for x in xs
        total += x
    end
    total
end
helper(xs::Vector{Int}) = inner(xs)
ask(xs::Vector{Int}) = helper(xs) + inner(xs)
ask_twice(xs::Vector{Int}) = inner(xs) + inner(xs)
other(xs::Vector{Int}) = length(xs)
ask_miss(xs::Vector{Int}) = other(xs) + inner(xs)
plain(x::Int) = x + 1
wrap(x::Int) = plain(x)
ask_plain(x::Int) = wrap(x) + plain(x)
function store!(xs::Vector{Int})
    for i in eachindex(xs)
        xs[i] = 0
    end
    xs
end
prep(xs::Vector{Int}) = store!(xs)
ask_store(xs::Vector{Int}) = prep(xs) + store!(xs)
ask_twice_store(xs::Vector{Int}) = store!(xs) + store!(xs)
function scaled(xs::Vector{Int}; factor)
    total = 0
    for x in xs
        total += x * factor
    end
    total
end
via(xs::Vector{Int}; factor) = scaled(xs; factor)
ask_differ(xs::Vector{Int}) = via(xs; factor = 1) + scaled(xs; factor = 2)
ask_same(xs::Vector{Int}) = via(xs; factor = 1) + scaled(xs; factor = 1)
leaf(x::Int) = x + 1
function leaf(xs::Vector{Int})
    total = 0
    for x in xs
        total += x
    end
    total
end
around(x::Int) = leaf(x)
ask_leaf(x::Int) = around(x) + leaf(x)
function deep(xs::Vector{Int})
    total = 0
    for x in xs
        total += x
    end
    total
end
mid(xs::Vector{Int}) = deep(xs)
shallow(xs::Vector{Int}) = mid(xs)
shell(xs::Vector{Int}) = shallow(xs)
ask_near(xs::Vector{Int}) = shell(xs) + shallow(xs)
lower(xs::Vector{Int}) = mid(xs)
upper(xs::Vector{Int}) = lower(xs)
ask_far(xs::Vector{Int}) = upper(xs) + upper(xs)
ask_sum(xs::Vector{Int}) = sum(xs) + sum(xs)
ask_map(xs::Vector{Int}) = map!(identity, xs, xs) + map!(identity, xs, xs)
function while_child(kids::Vector{Int}, index::Int, outer::Int)
    total = 0
    for k in 1:index
        total += outer
    end
    total
end
for_child(kids::Vector{Int}, index::Int, outer::Int) = while_child(kids, index, outer)
function child_locals(kind::Int, kids::Vector{Int}, index::Int, outer::Int)
    if kind == 1
        return for_child(kids, index, outer)
    end
    if kind == 2
        return while_child(kids, index, outer)
    end
    outer
end
function arm_pair(kind::Int, kids::Vector{Int}, index::Int, outer::Int)
    if kind == 1
        for_child(kids, index, outer)
    elseif kind == 2
        while_child(kids, index, outer)
    else
        outer
    end
end
function returned_twice(kind::Int, kids::Vector{Int}, index::Int, outer::Int)
    if kind == 1
        return while_child(kids, index, outer)
    end
    if kind == 2
        return while_child(kids, index, outer)
    end
    outer
end
function same_arm(kind::Int, kids::Vector{Int}, index::Int, outer::Int)
    if kind == 1
        return for_child(kids, index, outer) + while_child(kids, index, outer)
    end
    outer
end
function falls_through(kind::Int, kids::Vector{Int}, index::Int, outer::Int)
    if kind == 1
        for_child(kids, index, outer)
    end
    while_child(kids, index, outer)
end
"""

const BRANCH_ARGUMENTS = Tuple{Int,Vector{Int},Int,Int}
const BRANCH_NAMES = (:child_locals, :arm_pair, :returned_twice, :same_arm, :falls_through)
const CALL_PROBE = load_package("CallProbe", CALL_BODY)

function call_entries(pkg)
    rows = (
        (:ask, Vector{Int}),
        (:ask_twice, Vector{Int}),
        (:ask_miss, Vector{Int}),
        (:ask_plain, Int),
        (:ask_store, Vector{Int}),
        (:ask_twice_store, Vector{Int}),
        (:ask_differ, Vector{Int}),
        (:ask_same, Vector{Int}),
        (:ask_leaf, Int),
        (:ask_near, Vector{Int}),
        (:ask_far, Vector{Int}),
        (:ask_sum, Vector{Int}),
        (:ask_map, Vector{Int}),
    )
    entries = Tuple[]
    for (name, argument) in rows
        func = getfield(pkg, name)
        push!(entries, (func, Tuple{argument}))
    end
    for name in BRANCH_NAMES
        func = getfield(pkg, name)
        push!(entries, (func, BRANCH_ARGUMENTS))
    end
    entries
end

function overlap_findings(case, entries)
    ctx = case_context(case; entries)
    ArchCheck.run(OverlappingCalls(), ctx)
end

const CALL_PROBE_ENTRIES = call_entries(CALL_PROBE.pkg)
const CALL_PROBE_FOUND = overlap_findings(CALL_PROBE, CALL_PROBE_ENTRIES)

# Methods m1 to m4 in the generated oracle; m1 loops, and m2 always calls m1.
const ORACLE_METHODS = 4

function random_edges(rng, count)
    edges = Dict{Int,Vector{Int}}()
    for index in 1:count
        targets = Int[]
        for other in 1:(index - 1)
            picked = rand(rng, Bool)
            picked && push!(targets, other)
        end
        edges[index] = targets
    end
    1 in edges[2] || push!(edges[2], 1)
    edges
end

function method_block(index, targets, has_loop)
    lines = String[]
    push!(lines, "function m$(index)(x::Int)")
    push!(lines, "    total = 0")
    if has_loop
        push!(lines, "    for k in 1:x")
        push!(lines, "        total += k")
        push!(lines, "    end")
    end
    for (slot, target) in enumerate(targets)
        push!(lines, "    total += m$(target)(x - $slot)")
    end
    push!(lines, "    total")
    push!(lines, "end")
    join(lines, "\n")
end

function oracle_body(edges, loops)
    lines = String[]
    count = length(loops)
    for index in 1:count
        block = method_block(index, edges[index], loops[index])
        push!(lines, block)
    end
    for left in 1:(count - 1)
        for right in (left + 1):count
            line = "ask_$(left)_$(right)(x::Int) = m$(left)(x) + m$(right)(x)"
            push!(lines, line)
        end
    end
    push!(lines, "ask_twice(x::Int) = m1(x) + m1(x)")
    push!(lines, "function bang!(x::Int)")
    push!(lines, "    total = 0")
    push!(lines, "    for k in 1:x")
    push!(lines, "        total += k")
    push!(lines, "    end")
    push!(lines, "    total")
    push!(lines, "end")
    push!(lines, "ask_bang(x::Int) = bang!(x) + bang!(x)")
    push!(lines, "function reach_all(x::Int)")
    for index in 1:count
        push!(lines, "    m$(index)(x - $index)")
    end
    push!(lines, "    x")
    push!(lines, "end")
    join(lines, "\n")
end

function sorted_targets(edges, index)
    targets = copy(edges[index])
    sort!(targets)
    targets
end

function rebuild_indexes(previous, start, goal)
    path = Int[]
    cursor = goal
    while true
        push!(path, cursor)
        cursor == start && break
        cursor = previous[cursor]
    end
    reverse!(path)
    path
end

function index_path(edges, start, goal)
    previous = Dict{Int,Int}()
    queue = Int[start]
    seen = Set{Int}([start])
    head = 1
    while head <= length(queue)
        current = queue[head]
        head += 1
        for callee in sorted_targets(edges, current)
            callee in seen && continue
            push!(seen, callee)
            previous[callee] = current
            if callee == goal
                return rebuild_indexes(previous, start, callee)
            end
            push!(queue, callee)
        end
    end
    nothing
end

function path_text(path)
    names = ["m$(index)" for index in path]
    join(names, " ")
end

function index_costs(edges, loops, start)
    frontier = Int[start]
    seen = Set{Int}()
    depth = 0
    while depth <= 2 && !isempty(frontier)
        next_frontier = Int[]
        for node in frontier
            node in seen && continue
            push!(seen, node)
            if loops[node]
                return true
            end
            depth == 2 && continue
            append!(next_frontier, edges[node])
        end
        frontier = next_frontier
        depth += 1
    end
    false
end

function expected_overlaps(edges, loops)
    expected = Set{Tuple{String,String,String}}()
    count = length(loops)
    for left in 1:(count - 1)
        for right in (left + 1):count
            symbol = "ask_$(left)_$(right)"
            left_path = index_path(edges, left, right)
            right_costs = index_costs(edges, loops, right)
            if !isnothing(left_path) && right_costs
                calls = "m$(left)(x) m$(right)(x)"
                push!(expected, (symbol, calls, path_text(left_path)))
            end
            right_path = index_path(edges, right, left)
            left_costs = index_costs(edges, loops, left)
            if !isnothing(right_path) && left_costs
                calls = "m$(right)(x) m$(left)(x)"
                push!(expected, (symbol, calls, path_text(right_path)))
            end
        end
    end
    if index_costs(edges, loops, 1)
        push!(expected, ("ask_twice", "m1(x)", "m1"))
    end
    expected
end

function load_oracle(seed)
    rng = Xoshiro(seed)
    loops = Bool[]
    for index in 1:ORACLE_METHODS
        forced = index == 1
        picked = forced || rand(rng, Bool)
        push!(loops, picked)
    end
    edges = random_edges(rng, ORACLE_METHODS)
    body = oracle_body(edges, loops)
    name = "Oracle" * string(seed)
    case = load_package(name, body)
    expected = expected_overlaps(edges, loops)
    (; case, expected)
end

function oracle_entries(pkg)
    names = [:ask_twice, :ask_bang, :reach_all]
    for left in 1:(ORACLE_METHODS - 1)
        for right in (left + 1):ORACLE_METHODS
            push!(names, Symbol("ask_$(left)_$(right)"))
        end
    end
    entries = Tuple[]
    for name in names
        func = getfield(pkg, name)
        push!(entries, (func, Tuple{Int}))
    end
    entries
end

const KEPT_VENDOR = """
module OpenCascade
\"\"\"kept\"\"\"
Shape(x::Int) = get!(x, :k) do
    x
end
end
"""

const KEPT_USE = """
OpenCascade.Shape(x::String) = OpenCascade.Shape(length(x))
OpenCascade.Shape(x::Float64) = x + 1.0
OpenCascade.Shape(x::UInt8) = begin
    y = x
    get!(y, :k) do
        y
    end
end
function OpenCascade.Shape(x::UInt16)
    return get!(x, :k) do
        x
    end
end
OpenCascade.Shape(x::Int16) = get!(x, :k, x)
"""

const BARE_VENDOR = """
module OpenCascade
Shape(x::Int) = x + 0
end
"""

const BARE_USE = """
OpenCascade.Shape(x::String) = OpenCascade.Shape(length(x))
OpenCascade.Shape(x::Float64) = x + 1.0
"""

function kept_case(name, vendor, use)
    spine = "include(\"vendor/OpenCascade.jl\")\nusing .OpenCascade\n" * use
    files = ["vendor/OpenCascade.jl" => vendor]
    load_package(name, spine, files)
end

const KEEP_PROBE = kept_case("KeepProbe", KEPT_VENDOR, KEPT_USE)
const KEEP_BARE = kept_case("KeepBare", BARE_VENDOR, BARE_USE)

@testset "calls" begin
    @testset "a helper that reaches the repeated callee fires, and one that does not stays quiet" begin
        found = CALL_PROBE_FOUND
        got = overlap_records(found)
        symbols = record_symbols(got)
        reached = ("ask", "helper(xs) inner(xs)", "helper inner")
        @test reached in got
        @test !("ask_miss" in symbols)
        for finding in found
            @test finding.kind === :overlapping_call
            @test finding.mod === :CallProbe
        end
    end

    @testset "a loop-free callee and a bang callee stay quiet" begin
        found = CALL_PROBE_FOUND
        got = overlap_records(found)
        symbols = record_symbols(got)
        quiet = ("ask_plain", "ask_store", "ask_twice_store", "ask_map", "ask_leaf")
        for symbol in quiet
            @test !(symbol in symbols)
        end
    end

    @testset "keywords that differ are two questions, and equal keywords are one" begin
        found = CALL_PROBE_FOUND
        got = overlap_records(found)
        symbols = record_symbols(got)
        same = ("ask_same", "via(xs; factor = 1) scaled(xs; factor = 1)", "via scaled")
        @test same in got
        @test !("ask_differ" in symbols)
    end

    @testset "one call written twice fires when it costs work, and a three-hop repeat stays quiet" begin
        found = CALL_PROBE_FOUND
        got = overlap_records(found)
        symbols = record_symbols(got)
        twice = ("ask_twice", "inner(xs)", "inner")
        summed = ("ask_sum", "sum(xs)", "sum")
        near = ("ask_near", "shell(xs) shallow(xs)", "shell shallow")
        @test twice in got
        @test summed in got
        @test near in got
        @test !("ask_far" in symbols)
    end

    @testset "calls in exclusive branches stay quiet, and calls on one path overlap" begin
        got = overlap_records(CALL_PROBE_FOUND)
        symbols = record_symbols(got)
        for symbol in ("child_locals", "arm_pair", "returned_twice")
            @test !(symbol in symbols)
        end
        helpers = "for_child(kids, index, outer) while_child(kids, index, outer)"
        @test ("same_arm", helpers, "for_child while_child") in got
        @test ("falls_through", helpers, "for_child while_child") in got
    end

    @testset "overlapping calls need entries" begin
        ctx = case_context(CALL_PROBE)
        check = OverlappingCalls()
        @test_throws ArgumentError("OverlappingCalls needs entries") ArchCheck.run(check, ctx)
    end

    @testset "a generated call graph matches the reach the generator recorded" begin
        for seed in 1:3
            loaded = load_oracle(seed)
            # The oracle package loaded after this testset began, so its methods are read in the latest world.
            found = Base.invokelatest() do
                entries = oracle_entries(loaded.case.pkg)
                overlap_findings(loaded.case, entries)
            end
            got = overlap_records(found)
            @test got == loaded.expected
        end
    end

    @testset "a builder kept by a get! do block or forwarding to a kept one stays quiet, and an unkept one fires" begin
        check = KeptBuilders(:(OpenCascade.Shape); exempt_dirs = ("src/vendor",))
        ctx = case_context(KEEP_PROBE)
        found = ArchCheck.run(check, ctx)
        @test length(found) == 2
        forms = Set{String}()
        for finding in found
            @test finding.kind === :kept_builder
            @test finding.symbol == "Shape"
            @test finding.mod === :KeepProbe
            @test endswith(finding.file, "KeepProbe.jl")
            @test !occursin("vendor", finding.file)
            @test ev(finding, :builder) == "OpenCascade.Shape"
            push!(forms, ev(finding, :form))
        end
        @test "x + 1.0" in forms
        @test "get!(x, :k, x)" in forms
    end

    @testset "a forward with no keeper is a finding" begin
        check = KeptBuilders(:(OpenCascade.Shape); exempt_dirs = ("src/vendor",))
        ctx = case_context(KEEP_BARE)
        found = ArchCheck.run(check, ctx)
        @test length(found) == 2
        forms = Set{String}()
        for finding in found
            push!(forms, ev(finding, :form))
            @test !occursin("vendor", finding.file)
        end
        @test any(form -> occursin("OpenCascade.Shape", form), forms)
        @test "x + 1.0" in forms
    end
end
