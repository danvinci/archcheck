# A call is an edge to each method it can land on: the one inference resolved, or each its inferred types match.
# A generator records the edges it writes, so the oracle is that source.

function graph_of(case, entries)
    ctx = case_context(case; entries)
    ctx.methods
end

const CONCRETE_CALL = load_package("ConcreteCall", """
    leaf(x::Int) = x
    calls(x::Int) = leaf(x)
    """)

const WIDE_DISPATCH = load_package("WideDispatch", """
    wide(x::Integer) = dest(x)
    dest(x::Int8) = x
    dest(x::Int16) = x
    dest(x::Int32) = x
    dest(x::Int64) = x
    anycall(x) = dest(x)
    dyn(f, x::Int) = f(x)
    splat(xs::Vector{Any}) = dest(xs...)
    const HELD = (anycall,)
    """)

const NARROW_DISPATCH = load_package("NarrowDispatch", """
    wide(x::Integer) = dest(x)
    dest(x::Int8) = x
    dest(x::Int16) = x
    dest(x::Int32) = x
    """)

const KEYWORD_CREDIT = load_package("KeywordCredit", """
    add(x::Int; y::Int) = x
    use(x::Int) = add(x; y = 2)
    """)

const KEYWORD_WHERE = load_package("KeywordWhere", """
    scaled(xs::Vector{T}; scale::T = one(T)) where {T<:Real} = xs .* scale
    use(xs::Vector{Float64}) = scaled(xs; scale = 2.0)
    """)

const CLOSURE_CALL = load_package("ClosureCall", """
    leaf(x::Int) = x
    function outer(x::Int)
        inner(y::Int) = leaf(y)
        inner(x)
    end
    function anon(x::Int)
        (y -> leaf(y))(x)
    end
    """)

const CLOSURE_FORM = load_package("ClosureForm", """
    leaf(x::Int) = x
    function added(x::Int; y::Int = 1)
        (z -> leaf(z + y))(x)
    end
    """)

const UNUSED_RESULT = load_package("UnusedResult", """
    leaf(x::Int) = x
    function calls(x::Int)
        leaf(x)
        1
    end
    """)

const RECURSIVE_CALL = load_package("RecursiveCall", """
    self(x::Int) = x <= 0 ? x : self(x - 1)
    odd(x::Int) = x <= 0 ? x : even(x - 1)
    even(x::Int) = odd(x - 1)
    """)

# No file places a module evaluated from an expression, so its methods sit outside the modules the graph expands.
const OUTSIDE_CALL = load_package("OutsideCall", """
    Core.eval(@__MODULE__, :(module LeafMod
    hidden(x::Int) = x
    leaf(x::Int) = hidden(x)
    end))
    using .LeafMod: leaf
    go(x::Int) = leaf(x)
    """)

const OVERLOAD_PAIR = load_package("OverloadPair", """
    g(x::Int) = x
    h(x::String) = x
    f(x::Int) = g(x)
    f(x::String) = h(x)
    """)

const PASSED_HELPER = load_package("PassedHelper", """
    helper(x::Int) = x
    wrap(xs::Vector{Int}) = map(x -> helper(x), xs)
    named(xs::Vector{Int}) = map(helper, xs)
    captured(xs::Vector{Int}, k::Int) = map(x -> helper(x) + k, xs)
    """)

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
        pop!(current)
    end
    push!(current, linked)
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

function generated_case(rng, count, name)
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
    body = join(lines, "\n")
    case = load_package(name, body)
    mod = case.pkg
    methods_by_index = Dict{Int,Method}()
    for index in 1:count
        func_name = Symbol("m", index)
        func = Base.invokelatest(getfield, mod, func_name)
        methods_by_index[index] = only(methods(func))
    end
    entries = Tuple[]
    for index in entry_indexes
        func_name = Symbol("m", index)
        func = Base.invokelatest(getfield, mod, func_name)
        push!(entries, (func, Tuple{Int}))
    end
    expected = reachable_edges(calls, methods_by_index, entry_indexes)
    (; case, entries, expected, mod)
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

function reaches_method(graph, origin, goal)
    seen = Set{Method}()
    pending = Method[origin]
    while !isempty(pending)
        caller = pop!(pending)
        caller in seen && continue
        push!(seen, caller)
        caller === goal && return true
        callees = get(graph.edges, caller, nothing)
        isnothing(callees) && continue
        for callee in callees
            push!(pending, callee)
        end
    end
    false
end

@testset "a concrete call is one edge" begin
    pkg = CONCRETE_CALL.pkg
    entry = (pkg.calls, Tuple{Int})
    entries = (entry,)
    graph = graph_of(CONCRETE_CALL, entries)
    caller = only(methods(pkg.calls))
    callee = only(methods(pkg.leaf))
    @test graph.edges[caller] == Set([callee])
end

@testset "a call inference splits, or leaves to runtime dispatch, is an edge to each method its types match" begin
    for case in (NARROW_DISPATCH, WIDE_DISPATCH)
        pkg = case.pkg
        entry = (pkg.wide, Tuple{Integer})
        entries = (entry,)
        graph = graph_of(case, entries)
        caller = only(methods(pkg.wide))
        @test graph.edges[caller] == Set(methods(pkg.dest))
    end
end

@testset "an Any or splatted argument lands on each method its types match, and an unknown callee on functions held as values" begin
    pkg = WIDE_DISPATCH.pkg
    any_entry = (pkg.anycall, Tuple{Any})
    dyn_entry = (pkg.dyn, Tuple{Any,Int})
    splat_entry = (pkg.splat, Tuple{Vector{Any}})
    entries = (any_entry, dyn_entry, splat_entry)
    graph = graph_of(WIDE_DISPATCH, entries)
    anycall = only(methods(pkg.anycall))
    dyn = only(methods(pkg.dyn))
    splat = only(methods(pkg.splat))
    every_dest = Set(methods(pkg.dest))
    @test graph.edges[anycall] == every_dest
    @test graph.edges[dyn] == Set([anycall])
    @test graph.edges[splat] == every_dest
end

@testset "a call whose result is unused stays an edge" begin
    pkg = UNUSED_RESULT.pkg
    entry = (pkg.calls, Tuple{Int})
    entries = (entry,)
    graph = graph_of(UNUSED_RESULT, entries)
    caller = only(methods(pkg.calls))
    leaf = only(methods(pkg.leaf))
    @test leaf in graph.edges[caller]
end

@testset "a recursive call is an edge" begin
    pkg = RECURSIVE_CALL.pkg
    self_entry = (pkg.self, Tuple{Int})
    odd_entry = (pkg.odd, Tuple{Int})
    entries = (self_entry, odd_entry)
    graph = graph_of(RECURSIVE_CALL, entries)
    self_method = only(methods(pkg.self))
    odd_method = only(methods(pkg.odd))
    even_method = only(methods(pkg.even))
    @test self_method in graph.edges[self_method]
    @test even_method in graph.edges[odd_method]
    @test odd_method in graph.edges[even_method]
end

@testset "a method in a module outside the ranked modules is an edge and stays unexpanded" begin
    pkg = OUTSIDE_CALL.pkg
    entry = (pkg.go, Tuple{Int})
    entries = (entry,)
    graph = graph_of(OUTSIDE_CALL, entries)
    caller = only(methods(pkg.go))
    leaf = only(methods(pkg.LeafMod.leaf))
    hidden = only(methods(pkg.LeafMod.hidden))
    @test leaf in graph.edges[caller]
    @test all(callees -> !(hidden in callees), values(graph.edges))
end

@testset "a keyword call credits the method the source wrote" begin
    rows = (
        (case = KEYWORD_CREDIT, written = KEYWORD_CREDIT.pkg.add, argument = Int),
        (case = KEYWORD_WHERE, written = KEYWORD_WHERE.pkg.scaled, argument = Vector{Float64}),
    )
    for row in rows
        pkg = row.case.pkg
        entry = (pkg.use, Tuple{row.argument})
        entries = (entry,)
        graph = graph_of(row.case, entries)
        caller = only(methods(pkg.use))
        written = only(methods(row.written))
        owned = edges_in(graph, pkg)
        @test get(owned, caller, Set{Method}()) == Set([written])
    end
end

@testset "a closure's call is an edge from that closure" begin
    rows = (
        (case = CLOSURE_CALL, func = CLOSURE_CALL.pkg.outer),
        (case = CLOSURE_CALL, func = CLOSURE_CALL.pkg.anon),
        (case = CLOSURE_FORM, func = CLOSURE_FORM.pkg.added),
    )
    for row in rows
        entry = (row.func, Tuple{Int})
        entries = (entry,)
        graph = graph_of(row.case, entries)
        written = only(methods(row.func))
        leaf = only(methods(row.case.pkg.leaf))
        closure = closure_in(graph.edges[written], written, row.case.pkg)
        owned = edges_in(graph, row.case.pkg)
        @test get(owned, closure, Set{Method}()) == Set([leaf])
    end
end

@testset "a generated call graph matches the edges the generator wrote" begin
    for seed in 1:8
        rng = Xoshiro(seed)
        name = "GeneratedCalls" * string(seed)
        spec = generated_case(rng, 6, name)
        graph = graph_of(spec.case, spec.entries)
        owned = edges_in(graph, spec.mod)
        @test owned == spec.expected
    end
end

@testset "a function passed to an outside call reaches the function it calls" begin
    pkg = PASSED_HELPER.pkg
    helper = only(methods(pkg.helper))
    rows = (
        (func = pkg.wrap, argument = Tuple{Vector{Int}}),
        (func = pkg.captured, argument = Tuple{Vector{Int},Int}),
    )
    for row in rows
        entry = (row.func, row.argument)
        entries = (entry,)
        graph = graph_of(PASSED_HELPER, entries)
        caller = only(methods(row.func))
        callees = get(graph.edges, caller, Set{Method}())
        closure = closure_in(callees, caller, pkg)
        @test reaches_method(graph, closure, helper)
    end
    named_entry = (pkg.named, Tuple{Vector{Int}})
    named_entries = (named_entry,)
    named_graph = graph_of(PASSED_HELPER, named_entries)
    named = only(methods(pkg.named))
    @test helper in get(named_graph.edges, named, Set{Method}())
end

@testset "methods of one function stay distinct nodes" begin
    pkg = OVERLOAD_PAIR.pkg
    int_entry = (pkg.f, Tuple{Int})
    string_entry = (pkg.f, Tuple{String})
    entries = (int_entry, string_entry)
    graph = graph_of(OVERLOAD_PAIR, entries)
    int_method = only(method for method in methods(pkg.f) if method.sig <: Tuple{Any,Int})
    string_method = only(method for method in methods(pkg.f) if method.sig <: Tuple{Any,String})
    int_callee = only(methods(pkg.g))
    string_callee = only(methods(pkg.h))
    @test graph.edges[int_method] == Set([int_callee])
    @test graph.edges[string_method] == Set([string_callee])
end
