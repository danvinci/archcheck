# A renamed local clones at the whole body, and a renamed free name does not.
# A call's value is read when a later expression uses it.

function syntax_function(name, body)
    "function " * name * "()\n" * body * "\nend"
end

function syntax_pair_file(name, body)
    renamed_body = replace(body, "marker" => "other")
    original = syntax_function(name, body)
    renamed_name = name * "_renamed"
    renamed = syntax_function(renamed_name, renamed_body)
    original * "\n" * renamed * "\n"
end

function syntax_package(pkg_name, pairs)
    files = Pair{String,String}[]
    includes = String[]
    for (label, body) in pairs
        name = replace(label, " " => "_")
        filename = name * ".jl"
        source = syntax_pair_file(name, body)
        push!(files, filename => source)
        push!(includes, "include(\"$filename\")")
    end
    spine = join(includes, "\n")
    load_package(pkg_name, spine, files)
end

function syntax_scans(case)
    ctx = case_context(case)
    scans = file_scans(ctx)
    (; ctx, scans)
end

function syntax_method_names(finding)
    methods = ev(finding, :methods)
    labels = split(methods, " ")
    names = Set{String}()
    for label in labels
        pieces = split(label, ":")
        push!(names, string(last(pieces)))
    end
    names
end

# The renamed pair clones exactly when no method in its file references `marker` as a free name.
function syntax_agrees(scanned, name, body)
    source = syntax_function(name, body)
    nodes = body_nodes(source)
    check = ExpressionClones(; min_nodes = nodes)
    found = ArchCheck.run(check, scanned.ctx)
    wanted = Set([name, name * "_renamed"])
    cloned = any(finding -> syntax_method_names(finding) == wanted, found)
    scan = scanned.scans[name * ".jl"]
    referenced = any(used -> :marker in used, values(scan.refs))
    referenced == !cloned
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

function generated_scope_pairs()
    pairs = Pair{String,String}[]
    for seed in 1:12
        rng = Xoshiro(seed)
        body = generated_scope(rng)
        label = "seed_" * string(seed)
        push!(pairs, label => body)
    end
    pairs
end

const SCOPE_HANDS = syntax_package("ScopeHands", SCOPE_BODIES)
const SCOPE_HAND_READ = syntax_scans(SCOPE_HANDS)
const SCOPE_WALK_PAIRS = generated_scope_pairs()
const SCOPE_WALK = syntax_package("ScopeWalk", SCOPE_WALK_PAIRS)
const SCOPE_WALK_READ = syntax_scans(SCOPE_WALK)

@testset "locals agree: $label" for (label, body) in SCOPE_BODIES
    name = replace(label, " " => "_")
    @test syntax_agrees(SCOPE_HAND_READ, name, body)
end

@testset "generated scope walks agree, seed $seed" for seed in 1:12
    label = "seed_" * string(seed)
    body = SCOPE_WALK_PAIRS[seed][2]
    @test syntax_agrees(SCOPE_WALK_READ, label, body)
end

function syntax_used_pairs(scan, name)
    site = only(site for site in keys(scan.callsites) if site.name === name)
    [(call.callee, call.is_used) for call in scan.callsites[site]]
end

const USED_READ = load_package("UsedRead", """
function statement_call()
    g()
    h()
end
function last_call()
    h()
end
function assigned_call()
    x = g()
    x
end
function argument_call()
    h(g())
end
function returned_call()
    return g()
end
function condition_call()
    if g()
        h()
    end
    0
end
function sync_kept()
    @sync begin
        work()
    end
end
function sync_body()
    @sync begin
        work()
    end
    nothing
end
function fetch_dropped(t)
    fetch(t)
    nothing
end
function fetch_kept(t)
    fetch(t)
end
""")

const USED_CASES = [
    (label = "statement call", name = :statement_call, expected = [(:g, false), (:h, true)]),
    (label = "last expression of a function", name = :last_call, expected = [(:h, true)]),
    (label = "assigned", name = :assigned_call, expected = [(:g, true)]),
    (label = "argument", name = :argument_call, expected = [(:h, true), (:g, true)]),
    (label = "returned", name = :returned_call, expected = [(:g, true)]),
    (label = "condition", name = :condition_call, expected = [(:g, true), (:h, false)]),
    (label = "sync block kept", name = :sync_kept, expected = [(:work, true)]),
    (label = "sync block body", name = :sync_body, expected = [(:work, false)]),
    (label = "fetch discarded", name = :fetch_dropped, expected = [(:fetch, false)]),
    (label = "fetch kept", name = :fetch_kept, expected = [(:fetch, true)]),
]

const USED_SCAN = syntax_scans(USED_READ).scans["UsedRead.jl"]

@testset "call value is read: $(case.label)" for case in USED_CASES
    got = syntax_used_pairs(USED_SCAN, case.name)
    @test got == case.expected
end
