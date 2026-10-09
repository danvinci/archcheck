# Method-grain calls: inference resolves a concrete call to one method, and a call it cannot
# resolve stays a name. A generator records the edges it writes, so the oracle is that source.

module MGConcrete
    leaf(x::Int) = x
    calls(x::Int) = leaf(x)
end

module MGWide
    wide(x::Integer) = dest(x)
    dest(x::Int8) = x
    dest(x::Int16) = x
    dest(x::Int32) = x
    dest(x::Int64) = x
    anycall(x) = dest(x)
    dyn(f, x::Int) = f(x)
end

module MGKw
    add(x::Int; y::Int) = x
    use(x::Int) = add(x; y = 2)
end

module MGKwWhere
    scaled(xs::Vector{T}; scale::T = one(T)) where {T<:Real} = xs .* scale
    use(xs::Vector{Float64}) = scaled(xs; scale = 2.0)
end

module MGClose
    leaf(x::Int) = x
    function outer(x::Int)
        inner(y::Int) = leaf(y)
        inner(x)
    end
    function anon(x::Int)
        (y -> leaf(y))(x)
    end
end

module MGForms
    leaf(x::Int) = x
    function added(x::Int; y::Int = 1)
        (z -> leaf(z + y))(x)
    end
end

module MGSplit
    wide(x::Integer) = dest(x)
    dest(x::Int8) = x
    dest(x::Int16) = x
    dest(x::Int32) = x
end

module MGDrop
    leaf(x::Int) = x
    function calls(x::Int)
        leaf(x)
        1
    end
end

module MGRec
    self(x::Int) = x <= 0 ? x : self(x - 1)
    odd(x::Int) = x <= 0 ? x : even(x - 1)
    even(x::Int) = odd(x - 1)
end

module MGOut
    hidden(x::Int) = x
    leaf(x::Int) = hidden(x)
end

module MGIn
    using ..MGOut: leaf
    go(x::Int) = leaf(x)
end

module MGOver
    g(x::Int) = x
    h(x::String) = x
    f(x::Int) = g(x)
    f(x::String) = h(x)
end

@testset "method graph: a concrete call is one edge" begin
    graph = ArchCheck.method_graph(((MGConcrete.calls, Tuple{Int}),), (MGConcrete,))
    caller = only(methods(MGConcrete.calls))
    callee = only(methods(MGConcrete.leaf))
    @test graph.edges[caller] == Set([callee])
end

@testset "method graph: three matching methods are edges and four stay a name" begin
    rows = (
        (func = MGSplit.wide, dest = MGSplit.dest, mod = MGSplit, is_resolved = true),
        (func = MGWide.wide, dest = MGWide.dest, mod = MGWide, is_resolved = false),
    )
    for row in rows
        graph = ArchCheck.method_graph(((row.func, Tuple{Integer}),), (row.mod,))
        caller = only(methods(row.func))
        if row.is_resolved
            callees = Set(methods(row.dest))
            @test graph.edges[caller] == callees
            @test !haskey(graph.unresolved, caller)
        else
            @test graph.unresolved[caller] == Set([:dest])
            @test !haskey(graph.edges, caller)
        end
    end
end

@testset "method graph: an Any or dynamic call stays an unresolved name" begin
    any_entry = (MGWide.anycall, Tuple{Any})
    dyn_entry = (MGWide.dyn, Tuple{Any,Int})
    graph = ArchCheck.method_graph((any_entry, dyn_entry), (MGWide,))
    rows = (
        (func = MGWide.anycall, name = :dest),
        (func = MGWide.dyn, name = :f),
    )
    for row in rows
        caller = only(methods(row.func))
        @test graph.unresolved[caller] == Set([row.name])
    end
end

@testset "method graph: a call whose result is unused stays an edge" begin
    graph = ArchCheck.method_graph(((MGDrop.calls, Tuple{Int}),), (MGDrop,))
    caller = only(methods(MGDrop.calls))
    leaf = only(methods(MGDrop.leaf))
    @test leaf in graph.edges[caller]
end

@testset "method graph: a recursive call is an edge" begin
    self_entry = (MGRec.self, Tuple{Int})
    odd_entry = (MGRec.odd, Tuple{Int})
    graph = ArchCheck.method_graph((self_entry, odd_entry), (MGRec,))
    self_method = only(methods(MGRec.self))
    odd_method = only(methods(MGRec.odd))
    even_method = only(methods(MGRec.even))
    @test self_method in graph.edges[self_method]
    @test even_method in graph.edges[odd_method]
    @test odd_method in graph.edges[even_method]
end

@testset "method graph: a method outside the modules is an edge and is not expanded" begin
    graph = ArchCheck.method_graph(((MGIn.go, Tuple{Int}),), (MGIn,))
    caller = only(methods(MGIn.go))
    leaf = only(methods(MGOut.leaf))
    hidden = only(methods(MGOut.hidden))
    @test leaf in graph.edges[caller]
    @test all(callees -> !(hidden in callees), values(graph.edges))
end

# Each method writes two to four ordinary calls, cycles included. One method stays unreached.
# A return path keeps every call in the inference edges, including a discarded result.
function method_source(index, targets)
    lines = String[]
    push!(lines, "function m$(index)(x::Int)")
    push!(lines, "    x <= 0 && return x")
    for target in targets
        line = "    m$(target)(x - 1)"
        push!(lines, line)
    end
    push!(lines, "end")
    join(lines, "\n")
end

function reachable_indexes(calls, entry_indexes)
    reached = Set{Int}()
    pending = collect(entry_indexes)
    while !isempty(pending)
        index = pop!(pending)
        index in reached && continue
        push!(reached, index)
        for target in calls[index]
            push!(pending, target)
        end
    end
    reached
end

function ensure_outside_call(calls, entry_indexes, outside)
    reached = reachable_indexes(calls, entry_indexes)
    for index in outside
        index in reached && return calls
    end
    updated = Dict{Int,Vector{Int}}()
    for (index, targets) in calls
        updated[index] = copy(targets)
    end
    origin = entry_indexes[1]
    current = updated[origin]
    linked = outside[1]
    if length(current) >= 4
        kept = current[1:end - 1]
        updated[origin] = push!(copy(kept), linked)
    else
        updated[origin] = push!(copy(current), linked)
    end
    updated
end

function edges_in(graph, mod)
    kept = Dict{Method,Set{Method}}()
    for (caller, callees) in graph.edges
        caller.module === mod || continue
        owned = Set{Method}()
        for callee in callees
            callee.module === mod || continue
            push!(owned, callee)
        end
        isempty(owned) && continue
        kept[caller] = owned
    end
    kept
end

function reachable_edges(calls, methods_by_index, entry_indexes)
    reached = reachable_indexes(calls, entry_indexes)
    expected = Dict{Method,Set{Method}}()
    for index in reached
        caller = methods_by_index[index]
        callees = Set{Method}()
        for target in calls[index]
            callee = methods_by_index[target]
            push!(callees, callee)
        end
        expected[caller] = callees
    end
    expected
end

function random_targets(rng, call_count, pool)
    targets = Int[]
    span = length(pool)
    for _step in 1:call_count
        choice = rand(rng, 1:span)
        target = pool[choice]
        push!(targets, target)
    end
    targets
end

function generated_method_module(rng, count)
    order = randperm(rng, count)
    pool = order[1:count - 1]
    unreached = order[count]
    entry_count = rand(rng, 1:length(pool) - 1)
    entry_indexes = pool[1:entry_count]
    outside = pool[entry_count + 1:end]
    calls = Dict{Int,Vector{Int}}()
    for index in 1:count
        call_count = rand(rng, 2:4)
        if index == unreached
            targets = random_targets(rng, call_count, order)
        else
            targets = random_targets(rng, call_count, pool)
        end
        calls[index] = targets
    end
    calls = ensure_outside_call(calls, entry_indexes, outside)
    lines = String[]
    for index in 1:count
        push!(lines, method_source(index, calls[index]))
    end
    source = "module Generated\n" * join(lines, "\n") * "\nend\n"
    parent = Module()
    expr = Meta.parse(source)
    mod = Core.eval(parent, expr)
    methods_by_index = Dict{Int,Method}()
    for index in 1:count
        name = Symbol("m", index)
        func = Base.invokelatest(getfield, mod, name)
        methods_by_index[index] = only(methods(func))
    end
    entries = Tuple[]
    for index in entry_indexes
        name = Symbol("m", index)
        func = Base.invokelatest(getfield, mod, name)
        push!(entries, (func, Tuple{Int}))
    end
    expected = reachable_edges(calls, methods_by_index, entry_indexes)
    (mod = mod, entries = entries, expected = expected)
end

function closure_in(callees, written, mod)
    found = nothing
    for callee in callees
        callee === written && continue
        callee.module === mod || continue
        found = callee
    end
    found
end

@testset "method graph: a keyword call credits the method the source wrote" begin
    rows = (
        (mod = MGKw, use = MGKw.use, written = MGKw.add, argument = Int),
        (mod = MGKwWhere, use = MGKwWhere.use, written = MGKwWhere.scaled, argument = Vector{Float64}),
    )
    for row in rows
        graph = ArchCheck.method_graph(((row.use, Tuple{row.argument}),), (row.mod,))
        caller = only(methods(row.use))
        written = only(methods(row.written))
        owned = edges_in(graph, row.mod)
        @test get(owned, caller, Set{Method}()) == Set([written])
    end
end

@testset "method graph: a closure's call is an edge from that closure" begin
    rows = (
        (func = MGClose.outer, mod = MGClose, leaf = MGClose.leaf),
        (func = MGClose.anon, mod = MGClose, leaf = MGClose.leaf),
        (func = MGForms.added, mod = MGForms, leaf = MGForms.leaf),
    )
    for row in rows
        graph = ArchCheck.method_graph(((row.func, Tuple{Int}),), (row.mod,))
        written = only(methods(row.func))
        leaf = only(methods(row.leaf))
        closure = closure_in(graph.edges[written], written, row.mod)
        owned = edges_in(graph, row.mod)
        @test get(owned, closure, Set{Method}()) == Set([leaf])
    end
end

@testset "method graph: a generated call graph matches the edges the generator wrote" begin
    for seed in 1:8
        rng = Xoshiro(seed)
        spec = generated_method_module(rng, 6)
        graph = ArchCheck.method_graph(spec.entries, (spec.mod,))
        owned = edges_in(graph, spec.mod)
        @test owned == spec.expected
    end
end

@testset "method graph: methods of one function stay distinct nodes" begin
    int_entry = (MGOver.f, Tuple{Int})
    string_entry = (MGOver.f, Tuple{String})
    graph = ArchCheck.method_graph((int_entry, string_entry), (MGOver,))
    int_method = only(method for method in methods(MGOver.f) if method.sig <: Tuple{Any,Int})
    string_method = only(method for method in methods(MGOver.f) if method.sig <: Tuple{Any,String})
    int_callee = only(methods(MGOver.g))
    string_callee = only(methods(MGOver.h))
    @test graph.edges[int_method] == Set([int_callee])
    @test graph.edges[string_method] == Set([string_callee])
end
