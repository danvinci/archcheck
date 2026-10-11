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

# Every `holds` method matches the wide method's signature, and the more specific ones call `holds` dynamically.
const SHARED_SIGNATURE = load_package("SharedSignature", """
    holds(@nospecialize(type), wrapper) = type === wrapper
    holds(type::Union, wrapper) = holds(type.a, wrapper) || holds(type.b, wrapper)
    function holds(@nospecialize(type::Type), wrapper)
        type === wrapper && return true
        body = Base.unwrap_unionall(type)
        body isa DataType || return false
        for param in body.parameters
            holds(param, wrapper) && return true
        end
        false
    end
    scan(types::Vector{Any}, wrapper::DataType) = any(t -> holds(t, wrapper), types)
    """)

# A keyword call through a splat, and one to a callee unknown at its site; only `shifted` is held as a value.
const KEYWORD_SPREAD = load_package("KeywordSpread", """
    scaled(x::Int; scale::Int = 1) = x * scale
    shifted(x::Int; shift::Int = 0) = x + shift
    forward(args::Vector{Any}, options) = scaled(args...; options...)
    pass(func, x::Int) = func(x; scale = 2)
    const HELD = (shifted,)
    """)

# A type held as a value, and one the source only defines and annotates.
const TYPE_CALLEE = load_package("TypeCallee", """
    struct Kept
        x::Float64
    end
    struct Hidden
        x::Float64
    end
    make(maker::DataType) = maker(0.5)
    hide(hidden::Hidden) = hidden.x
    const MAKERS = (Kept,)
    """)

# `relay` inlines into `start`, carrying its call to `finish` along; more `finish` methods than inference splits a
# call over leave that call to runtime dispatch.
const INLINED_RELAY = load_package("InlinedRelay", """
    finish(x::Int8) = x
    finish(x::Int16) = x
    finish(x::Int32) = x
    finish(x::Int64) = x
    @inline relay(items::Vector{Any}) = finish(items[1])
    start(items::Vector{Any}) = relay(items)
    """)

const PASSED_HELPER = load_package("PassedHelper", """
    helper(x::Int) = x
    wrap(xs::Vector{Int}) = map(x -> helper(x), xs)
    named(xs::Vector{Int}) = map(helper, xs)
    captured(xs::Vector{Int}, k::Int) = map(x -> helper(x) + k, xs)
    """)

# Calls the walk's inference judges: one no method takes, one into a stub, a keyword forward, a dropped pure value,
# a guard kept for its exception, a stateful call written twice and a pure one written twice.
const CALL_FACTS = load_package("CallFacts", """
    function hook end
    pair(x::Int, y::Int) = x + y
    fails(x::Int) = pair(x)
    stubbed(x::Int) = hook(x)
    plain(x::Int) = x
    forwards(x::Int, options) = plain(x; options...)
    function drops(x::Int)
        x == 3
        x
    end
    kept(x) = true
    function abstract_drops(x::Real)
        kept(x)
        x
    end
    struct Hue end
    shade(a::Float64, b::Float64, w) = (1.0 - w) * a + w * b
    any_shade(w) = shade(1.0, 2.0, w)
    hue_shade(w::Hue) = shade(1.0, 2.0, w)
    checked(x::Int) = x > 0 ? x : throw(ArgumentError("not positive"))
    function guards(x::Int)
        checked(x)
        x
    end
    admits(kind) = kind === Int || throw(ArgumentError("unsupported kind"))
    function read_as(x; kind::Type = Int)
        admits(kind)
        x
    end
    function advance(counter::Vector{Int})
        for _step in 1:3
            counter[1] += 1
        end
        counter[1]
    end
    advances(counter::Vector{Int}) = advance(counter) + advance(counter)
    function summed(n::Int)
        total = 0
        for step in 1:n
            total += step
        end
        total
    end
    sums(n::Int) = summed(n) + summed(n)
    dest(x::Int8) = x
    dest(x::Int16) = x
    dest(x::Int32) = x
    dest(x::Int64) = x
    function wide_spread(xs::Union{Tuple{Int8,Int8},Tuple{Integer}})
        dest(xs...)
    end
    function open_spread(xs)
        dest(xs...)
    end
    short_spread(xs::Tuple{Int}) = pair(xs...)
    struct Box{T}
        value::T
    end
    function mid(box::Box{T}, alpha = 0.5) where {T<:AbstractFloat}
        box.value + alpha
    end
    allocate(nbits::Int) = BigInt(; nbits = nbits)
    # `dest(x)` matches more methods than inference records, so stored to a local it still vetoes the line's failure.
    function beside(x)
        y = dest(x); dest(1, 2)
        y
    end
    """)

function call_facts_context()
    pkg = CALL_FACTS.pkg
    rows = (
        (pkg.fails, Tuple{Int}),
        (pkg.stubbed, Tuple{Int}),
        (pkg.forwards, Tuple{Int,Any}),
        (pkg.drops, Tuple{Int}),
        (pkg.abstract_drops, Tuple{Real}),
        (pkg.guards, Tuple{Int}),
        (pkg.any_shade, Tuple{Any}),
        (pkg.hue_shade, Tuple{pkg.Hue}),
        (pkg.advances, Tuple{Vector{Int}}),
        (pkg.sums, Tuple{Int}),
        (pkg.wide_spread, Tuple{Union{Tuple{Int8,Int8},Tuple{Integer}}}),
        (pkg.open_spread, Tuple{Tuple{Integer}}),
        (pkg.open_spread, Tuple{Tuple{String}}),
        (pkg.short_spread, Tuple{Tuple{Int}}),
        (pkg.beside, Tuple{Any}),
        (pkg.read_as, Tuple{Any}),
    )
    case_context(CALL_FACTS; entries = rows)
end

# The walk pops entries last first, so one order reaches `compares` at `Int` before its declared signature.
const ENTRY_ORDER = load_package("EntryOrder", """
    same(a, b) = a === b
    function compares(x)
        same(x, 1)
        x
    end
    reaches_compare(y::Int) = compares(y)
    """)

const CALL_FACTS_CONTEXT = call_facts_context()
const CALL_FACTS_FOUND = ArchCheck.run(InferredCalls(), CALL_FACTS_CONTEXT)

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

@testset "a keyword call lands on the function it calls, splatted or held as a value" begin
    pkg = KEYWORD_SPREAD.pkg
    forward_entry = (pkg.forward, Tuple{Vector{Any},Any})
    pass_entry = (pkg.pass, Tuple{Any,Int})
    entries = (forward_entry, pass_entry)
    graph = graph_of(KEYWORD_SPREAD, entries)
    owned = edges_in(graph, pkg)
    forward = only(methods(pkg.forward))
    pass = only(methods(pkg.pass))
    scaled = only(methods(pkg.scaled))
    shifted = only(methods(pkg.shifted))
    @test owned[forward] == Set([scaled])
    @test owned[pass] == Set([shifted])
end

@testset "a callee held in a DataType lands on the constructors of types held as values" begin
    pkg = TYPE_CALLEE.pkg
    entry = (pkg.make, Tuple{DataType})
    entries = (entry,)
    graph = graph_of(TYPE_CALLEE, entries)
    make = only(methods(pkg.make))
    owned = edges_in(graph, pkg)
    landed = get(owned, make, Set{Method}())
    kept = Set(methods(pkg.Kept))
    hidden = Set(methods(pkg.Hidden))
    @test !isempty(landed)
    @test issubset(landed, kept)
    @test isdisjoint(landed, hidden)
end

@testset "a call inlined from a package method stays that method's edge" begin
    pkg = INLINED_RELAY.pkg
    entry = (pkg.start, Tuple{Vector{Any}})
    entries = (entry,)
    graph = graph_of(INLINED_RELAY, entries)
    start = only(methods(pkg.start))
    relay = only(methods(pkg.relay))
    every_finish = Set(methods(pkg.finish))
    owned = edges_in(graph, pkg)
    @test owned[start] == Set([relay])
    @test owned[relay] == every_finish
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

@testset "a method whose signature other methods match keeps only its own calls" begin
    pkg = SHARED_SIGNATURE.pkg
    entry = (pkg.scan, Tuple{Vector{Any},DataType})
    entries = (entry,)
    graph = graph_of(SHARED_SIGNATURE, entries)
    every_holds = Set(methods(pkg.holds))
    wide = only(method for method in every_holds if method.sig == Tuple{typeof(pkg.holds),Any,Any})
    on_union = only(method for method in every_holds if method.sig == Tuple{typeof(pkg.holds),Union,Any})
    owned = edges_in(graph, pkg)
    @test get(owned, wide, Set{Method}()) == Set{Method}()
    @test owned[on_union] == every_holds
end

@testset "a call no method takes fails, and a call left without call info stays quiet" begin
    failing = filter(finding -> finding.kind === :failing_call, CALL_FACTS_FOUND)
    rows = evidence_rows(failing, :callee, :via, :signature)
    @test rows == [
        (:failing_call, "fails", "pair", "call", "concrete"),
        (:failing_call, "short_spread", "pair", "apply", "concrete"),
    ]
end

@testset "a dropped pure value is a finding at every argument its method accepts, and a guard a default passes stays quiet" begin
    dropped = filter(finding -> finding.kind === :dropped_value, CALL_FACTS_FOUND)
    rows = evidence_rows(dropped, :returns)
    @test rows == [(:dropped_value, "abstract_drops", "Bool"), (:dropped_value, "drops", "Bool")]
end

@testset "the order of the entries does not change the findings" begin
    pkg = ENTRY_ORDER.pkg
    entries = [(pkg.compares, Tuple{Any}), (pkg.reaches_compare, Tuple{Int})]
    forward_context = case_context(ENTRY_ORDER; entries)
    backward_context = case_context(ENTRY_ORDER; entries = reverse(entries))
    forward = ArchCheck.run(InferredCalls(), forward_context)
    backward = ArchCheck.run(InferredCalls(), backward_context)
    @test evidence_rows(forward, :returns) == [(:dropped_value, "compares", "Bool")]
    @test evidence_rows(backward, :returns) == evidence_rows(forward, :returns)
end

@testset "a stateful call written twice stays quiet, and a pure one carries its effects" begin
    found = ArchCheck.run(OverlappingCalls(), CALL_FACTS_CONTEXT)
    symbols = Set(finding.symbol for finding in found)
    @test !("advances" in symbols)
    @test "sums" in symbols
    for finding in found
        effects = ev(finding, :effects)
        @test startswith(effects, "+c,+e")
    end
end

# A default argument lowers to a call of the full method. At an empty parameter that signature is `Union{}`.
@testset "a call proved unreachable still builds the graph" begin
    pkg = CALL_FACTS.pkg
    entry = (pkg.mid, Tuple{pkg.Box{Union{}}})
    entries = (entry,)
    graph = graph_of(CALL_FACTS, entries)
    caller = which(pkg.mid, (pkg.Box{Union{}},))
    @test haskey(graph.edges, caller)
end

# Allocating a `BigInt` inlines a foreign call whose library name is a call nested in argument position.
@testset "a foreign call whose name is a nested call still builds the graph" begin
    pkg = CALL_FACTS.pkg
    entry = (pkg.allocate, Tuple{Int})
    entries = (entry,)
    graph = graph_of(CALL_FACTS, entries)
    caller = only(methods(pkg.allocate))
    @test haskey(graph.edges, caller)
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
