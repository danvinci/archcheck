# Overlapping calls and kept builders, over synthetic modules and a generated reach oracle.

function write_tree(dir, files)
    src = joinpath(dir, "src")
    mkpath(src)
    for (relative, source) in files
        path = joinpath(src, relative)
        mkpath(dirname(path))
        write(path, source)
    end
    joinpath(src, files[1][1])
end

function index_tree(dir, name)
    src = joinpath(dir, "src")
    spine = joinpath(src, name * ".jl")
    root = Symbol(name)
    layout = ArchCheck.package_layout(spine, root)
    rank = layout[1]
    dir2mod = layout[2]
    ArchCheck.build_source_index(src, rank, dir2mod)
end

function typed_entry(mod, name, argument)
    func = getfield(mod, name)
    (func, Tuple{argument})
end

function overlap_records(findings)
    found = Set{Tuple{String,String,String}}()
    for finding in findings
        calls = ev(finding, :calls)
        reaches = ev(finding, :reaches)
        push!(found, (finding.symbol, calls, reaches))
    end
    found
end

function record_symbols(records)
    found = Set{String}()
    for record in records
        push!(found, record[1])
    end
    found
end

function release_dir(dir)
    rm(dir; force = true, recursive = true)
end

const CALL_SOURCE = """
module CallProbe
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
end
"""

const BRANCH_ARGUMENTS = Tuple{Int,Vector{Int},Int,Int}
const BRANCH_NAMES = (:child_locals, :arm_pair, :returned_twice, :same_arm, :falls_through)

const CALL_DIR = mktempdir()
const CALL_SPINE = write_tree(CALL_DIR, (("CallProbe.jl", CALL_SOURCE),))
include(CALL_SPINE)
const CALL_INDEX = index_tree(CALL_DIR, "CallProbe")

function call_entries()
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
        push!(entries, typed_entry(CallProbe, name, argument))
    end
    for name in BRANCH_NAMES
        func = getfield(CallProbe, name)
        push!(entries, (func, BRANCH_ARGUMENTS))
    end
    entries
end

function call_findings()
    check = ArchCheck.OverlappingCalls()
    entries = call_entries()
    modules = (CallProbe,)
    graph = ArchCheck.method_graph(entries, modules)
    ctx = ArchCheck.Context(CALL_INDEX, CallProbe, [CallProbe]; methods = graph)
    ArchCheck.run_checks(ctx, (check,))
end

function ensure_target(targets, callee)
    found = Int[]
    for target in targets
        push!(found, target)
    end
    callee in found && return found
    push!(found, callee)
    found
end

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
    forced = ensure_target(edges[2], 1)
    edges[2] = forced
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

function oracle_source(name, edges, loops)
    lines = String[]
    push!(lines, "module $name")
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
    names = String[]
    for index in path
        push!(names, "m$(index)")
    end
    join(names, " ")
end

function index_costs(edges, loops, start)
    frontier = Int[start]
    seen = Set{Int}()
    depth = 0
    while depth <= 2 && !isempty(frontier)
        nxt = Int[]
        for node in frontier
            node in seen && continue
            push!(seen, node)
            if loops[node]
                return true
            end
            depth == 2 && continue
            for callee in edges[node]
                push!(nxt, callee)
            end
        end
        frontier = nxt
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

function prepare_oracle(seed)
    count = 4
    rng = Xoshiro(seed)
    loops = Bool[]
    for index in 1:count
        forced = index == 1
        picked = forced || rand(rng, Bool)
        push!(loops, picked)
    end
    edges = random_edges(rng, count)
    name = "Oracle$(seed)"
    source = oracle_source(name, edges, loops)
    dir = mktempdir()
    spine = write_tree(dir, (("$(name).jl", source),))
    include(spine)
    mod = Base.invokelatest(getfield, Main, Symbol(name))
    index = index_tree(dir, name)
    expected = expected_overlaps(edges, loops)
    (dir = dir, mod = mod, index = index, expected = expected)
end

function oracle_entries(mod, count)
    names = Symbol[]
    push!(names, :ask_twice)
    push!(names, :ask_bang)
    push!(names, :reach_all)
    for left in 1:(count - 1)
        for right in (left + 1):count
            push!(names, Symbol("ask_$(left)_$(right)"))
        end
    end
    entries = Tuple[]
    for name in names
        func = Base.invokelatest(getfield, mod, name)
        push!(entries, (func, Tuple{Int}))
    end
    entries
end

function oracle_records(spec)
    check = ArchCheck.OverlappingCalls()
    entries = oracle_entries(spec.mod, 4)
    modules = (spec.mod,)
    graph = ArchCheck.method_graph(entries, modules)
    ctx = ArchCheck.Context(spec.index, spec.mod, [spec.mod]; methods = graph)
    found = ArchCheck.run_checks(ctx, (check,))
    overlap_records(found)
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

function kept_spine(name)
    "module $name\ninclude(\"vendor/open.jl\")\ninclude(\"use.jl\")\nend\n"
end

function load_kept(name, vendor, use)
    dir = mktempdir()
    spine_source = kept_spine(name)
    files = (("$(name).jl", spine_source), ("vendor/open.jl", vendor), ("use.jl", use))
    spine = write_tree(dir, files)
    include(spine)
    index = index_tree(dir, name)
    (dir = dir, index = index)
end

const KEEP_LOADED = load_kept("KeepProbe", KEPT_VENDOR, KEPT_USE)
const BARE_LOADED = load_kept("KeepBare", BARE_VENDOR, BARE_USE)

function run_kept(loaded, root, check)
    nested = ArchCheck.submodules(root)
    mods = [root; nested]
    ctx = ArchCheck.Context(loaded.index, root, mods)
    ArchCheck.run_checks(ctx, (check,))
end

@testset "calls" begin
    @testset "a helper that reaches the repeated callee fires, and one that does not stays quiet" begin
        found = call_findings()
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
        found = call_findings()
        got = overlap_records(found)
        symbols = record_symbols(got)
        quiet = ("ask_plain", "ask_store", "ask_twice_store", "ask_map", "ask_leaf")
        for symbol in quiet
            @test !(symbol in symbols)
        end
    end

    @testset "keywords that differ are two questions, and equal keywords are one" begin
        found = call_findings()
        got = overlap_records(found)
        symbols = record_symbols(got)
        same = ("ask_same", "via(xs; factor = 1) scaled(xs; factor = 1)", "via scaled")
        @test same in got
        @test !("ask_differ" in symbols)
    end

    @testset "one call written twice fires when it costs work, and a three-hop repeat stays quiet" begin
        found = call_findings()
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
        got = overlap_records(call_findings())
        symbols = record_symbols(got)
        for symbol in ("child_locals", "arm_pair", "returned_twice")
            @test !(symbol in symbols)
        end
        helpers = "for_child(kids, index, outer) while_child(kids, index, outer)"
        @test ("same_arm", helpers, "for_child while_child") in got
        @test ("falls_through", helpers, "for_child while_child") in got
    end

    @testset "overlapping calls need entries" begin
        ctx = ArchCheck.Context(CALL_INDEX, CallProbe, [CallProbe])
        check = (ArchCheck.OverlappingCalls(),)
        @test_throws ArgumentError("OverlappingCalls needs entries") ArchCheck.run_checks(ctx, check)
    end

    @testset "a generated call graph matches the reach the generator recorded" begin
        for seed in 1:3
            spec = prepare_oracle(seed)
            got = Base.invokelatest(oracle_records, spec)
            @test got == spec.expected
            symbols = record_symbols(got)
            @test !("ask_bang" in symbols)
            release_dir(spec.dir)
        end
    end

    @testset "a kept builder, a forward to one, and an unkept builder" begin
        check = ArchCheck.KeptBuilders(:(OpenCascade.Shape); exempt_dirs = ("src/vendor",))
        found = run_kept(KEEP_LOADED, KeepProbe, check)
        @test length(found) == 2
        forms = Set{String}()
        for finding in found
            @test finding.kind === :kept_builder
            @test finding.symbol == "Shape"
            @test finding.mod === :KeepProbe
            @test endswith(finding.file, "use.jl")
            @test !occursin("vendor", finding.file)
            @test ev(finding, :builder) == "OpenCascade.Shape"
            push!(forms, ev(finding, :form))
        end
        @test "x + 1.0" in forms
        @test "get!(x, :k, x)" in forms
    end

    @testset "a forward with no keeper is a finding" begin
        check = ArchCheck.KeptBuilders(:(OpenCascade.Shape); exempt_dirs = ("src/vendor",))
        found = run_kept(BARE_LOADED, KeepBare, check)
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

release_dir(CALL_DIR)
release_dir(KEEP_LOADED.dir)
release_dir(BARE_LOADED.dir)
