# One scope model, and whether a call's value is read.

function probe_source(body)
    "function probe()\n" * body * "\nend\n"
end

function renamed_marker(source)
    replace(source, "marker" => "other")
end

function function_kids(source)
    tree = parse_file(source, "probe.jl")
    func = first(ArchCheck.child_nodes(tree))
    ArchCheck.child_nodes(func)
end

function digest_stable(source)
    kids = function_kids(source)
    bound = ArchCheck.body_locals(kids[1], kids[2], Set{Symbol}())
    original = ArchCheck.digest_of(kids[2], bound)
    other_kids = function_kids(renamed_marker(source))
    other_bound = ArchCheck.body_locals(other_kids[1], other_kids[2], Set{Symbol}())
    renamed = ArchCheck.digest_of(other_kids[2], other_bound)
    original == renamed
end

function marker_is_ref(source)
    scan = scan_defs(source)
    :marker in scan.refs[:probe]
end

const SCOPE_BODIES = [
    ("for header", "for marker in f(marker)\n    g(marker)\nend"),
    ("for second header", "for i in xs, marker in f(marker)\n    g(marker)\nend"),
    ("for body", "for i in xs\n    marker = 1\n    f(marker)\nend"),
    ("while header", "while f(marker)\n    marker = 1\nend"),
    ("while body", "while flag\n    marker = 1\n    f(marker)\nend"),
    ("comprehension iterator", "f([i for marker in f(marker)])"),
    ("comprehension filter", "f([marker for marker in xs if f(marker)])"),
    ("comprehension element", "f([marker for i in xs])"),
    ("generator assign", "f([begin\n    marker = 1\n    marker\nend for i in xs])"),
    ("closure", "map(marker -> f(marker), xs)"),
    ("let body", "let marker = 1\n    f(marker)\nend"),
    ("let next binding", "let marker = 1, y = f(marker)\n    y\nend"),
    ("let rhs", "let x = f(marker)\n    x\nend"),
    ("try body", "try\n    f(marker)\ncatch err\n    g(err)\nend"),
    ("catch body", "try\n    f()\ncatch marker\n    g(marker)\nend"),
    ("catch hidden from try", "try\n    f(marker)\ncatch marker\n    g()\nend"),
    ("finally separate", "try\n    marker = 1\nfinally\n    f(marker)\nend"),
    ("nested function", "function inner(marker)\n    f(marker)\nend"),
    ("nested default", "function inner(x = marker)\n    marker = 1\n    x\nend"),
]

@testset "locals agree: $label" for (label, body) in SCOPE_BODIES
    source = probe_source(body)
    stable = digest_stable(source)
    referenced = marker_is_ref(source)
    @test stable == !referenced
end

function scope_leaf(rng)
    choice = rand(rng, 1:2)
    if choice == 1
        return "f(marker)"
    end
    "marker = 1\n    f(marker)"
end

function wrap_scope(body, choice)
    if choice == 1
        return "for i in xs\n    $body\nend"
    elseif choice == 2
        return "let marker = 1\n    $body\nend"
    elseif choice == 3
        return "try\n    $body\ncatch err\n    g(err)\nend"
    elseif choice == 4
        return "while flag\n    $body\nend"
    elseif choice == 5
        return "f([begin\n    $body\nend for i in xs])"
    end
    "function inner(a)\n    $body\nend"
end

function generated_scope(rng)
    body = scope_leaf(rng)
    levels = rand(rng, 2:3)
    placed = 0
    while placed < levels
        placed += 1
        choice = rand(rng, 1:6)
        body = wrap_scope(body, choice)
    end
    body
end

function marker_referenced(source)
    scan = scan_defs(source)
    for names in values(scan.refs)
        :marker in names && return true
    end
    false
end

@testset "generated scope walks agree, seed $seed" for seed in 1:12
    rng = Xoshiro(seed)
    body = generated_scope(rng)
    source = probe_source(body)
    stable = digest_stable(source)
    referenced = marker_referenced(source)
    @test stable == !referenced
end

function used_pairs(source)
    scan = scan_defs(source)
    site = MethodSite(:probe, 1)
    calls = scan.callsites[site]
    pairs = Tuple{Symbol,Bool}[]
    for call in calls
        push!(pairs, (call.callee, call.is_used))
    end
    pairs
end

const USED_CASES = [
    (
        label = "statement call",
        source = "function probe()\n    g()\n    h()\nend\n",
        expected = [(:g, false), (:h, true)],
    ),
    (
        label = "last expression of a function",
        source = "function probe()\n    h()\nend\n",
        expected = [(:h, true)],
    ),
    (
        label = "assigned",
        source = "function probe()\n    x = g()\n    x\nend\n",
        expected = [(:g, true)],
    ),
    (
        label = "argument",
        source = "function probe()\n    h(g())\nend\n",
        expected = [(:h, true), (:g, true)],
    ),
    (
        label = "returned",
        source = "function probe()\n    return g()\nend\n",
        expected = [(:g, true)],
    ),
    (
        label = "condition",
        source = "function probe()\n    if g()\n        h()\n    end\n    0\nend\n",
        expected = [(:g, true), (:h, false)],
    ),
    (
        label = "sync block kept",
        source = "function probe()\n    @sync begin\n        work()\n    end\nend\n",
        expected = [(:work, true)],
    ),
    (
        label = "sync block body",
        source = "function probe()\n    @sync begin\n        work()\n    end\n    nothing\nend\n",
        expected = [(:work, false)],
    ),
    (
        label = "fetch discarded",
        source = "function probe(t)\n    fetch(t)\n    nothing\nend\n",
        expected = [(:fetch, false)],
    ),
    (
        label = "fetch kept",
        source = "function probe(t)\n    fetch(t)\nend\n",
        expected = [(:fetch, true)],
    ),
]

@testset "call value is read: $(case.label)" for case in USED_CASES
    got = used_pairs(case.source)
    @test got == case.expected
end
