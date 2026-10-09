# Call sites recorded on the scan: one vector per method, in source order.

# callee, qualifier, arguments, keywords, line, loop depth
const CallRow = Tuple{Symbol,String,String,String,Int,Int}

function call_rows(calls)
    rows = CallRow[]
    for call in calls
        row = (call.callee, call.qualifier, call.arguments, call.keywords, call.line, call.loop_depth)
        push!(rows, row)
    end
    rows
end

function rows_of(scan, name, line)
    site = MethodSite(name, line)
    call_rows(scan.callsites[site])
end

function rows_by_site(scan)
    pairs = [site => call_rows(calls) for (site, calls) in scan.callsites]
    Dict(pairs)
end

function leaf_spec(rng)
    if rand(rng) < 0.5
        kw_source = "b = 1, a = 2"
    else
        kw_source = "a = 2, b = 1"
    end
    zeta = "zeta(x; $kw_source)"
    templates = [
        (source = "alpha(x)", callee = :alpha, qualifier = "", arguments = "x", keywords = ""),
        (source = "beta(x, y)", callee = :beta, qualifier = "", arguments = "x, y", keywords = ""),
        (source = "M.gamma(x)", callee = :gamma, qualifier = "M", arguments = "x", keywords = ""),
        (source = "A.B.delta(x)", callee = :delta, qualifier = "A.B", arguments = "x", keywords = ""),
        (source = "epsilon.(x)", callee = :epsilon, qualifier = "", arguments = "x", keywords = ""),
        (source = "x .+ y", callee = :+, qualifier = "", arguments = "x, y", keywords = ""),
        (source = "x + y", callee = :+, qualifier = "", arguments = "x, y", keywords = ""),
        (source = "!flag", callee = :!, qualifier = "", arguments = "flag", keywords = ""),
        (source = "alpha(xs...)", callee = :alpha, qualifier = "", arguments = "xs...", keywords = ""),
        (source = zeta, callee = :zeta, qualifier = "", arguments = "x", keywords = "a = 2, b = 1"),
    ]
    templates[rand(rng, eachindex(templates))]
end

function emit_leaf!(lines, calls, depth, rng)
    spec = leaf_spec(rng)
    push!(lines, spec.source)
    line = length(lines)
    row = (spec.callee, spec.qualifier, spec.arguments, spec.keywords, line, depth)
    push!(calls, row)
    spec
end

function emit_comp!(lines, calls, depth, rng)
    spec = leaf_spec(rng)
    push!(lines, "[$(spec.source) for i in xs]")
    line = length(lines)
    row = (spec.callee, spec.qualifier, spec.arguments, spec.keywords, line, depth + 1)
    push!(calls, row)
end

function emit_closure!(lines, calls, depth, rng)
    spec = leaf_spec(rng)
    push!(lines, "map(i -> $(spec.source), xs)")
    line = length(lines)
    arguments = "i -> $(spec.source), xs"
    push!(calls, (:map, "", arguments, "", line, depth))
    row = (spec.callee, spec.qualifier, spec.arguments, spec.keywords, line, depth)
    push!(calls, row)
end

function emit_stmt!(lines, calls, depth, rng)
    if depth >= 3 || rand(rng) < 0.5
        emit_leaf!(lines, calls, depth, rng)
        return
    end
    choice = rand(rng, 1:4)
    if choice == 1
        push!(lines, "for i in xs")
        emit_stmt!(lines, calls, depth + 1, rng)
        if rand(rng) < 0.5
            emit_stmt!(lines, calls, depth + 1, rng)
        end
        push!(lines, "end")
    elseif choice == 2
        push!(lines, "while flag")
        emit_stmt!(lines, calls, depth + 1, rng)
        push!(lines, "end")
    elseif choice == 3
        emit_comp!(lines, calls, depth, rng)
    else
        emit_closure!(lines, calls, depth, rng)
    end
end

function random_probe(rng, name)
    lines = String["function " * name * "()"]
    calls = CallRow[]
    count = rand(rng, 1:3)
    for _ in 1:count
        emit_stmt!(lines, calls, 0, rng)
    end
    push!(lines, "end")
    join(lines, "\n"), calls
end

function callsite_generated()
    files = Pair{String,String}[]
    expected = Dict{String,Vector{CallRow}}()
    includes = String[]
    for seed in 1:40
        rng = Xoshiro(seed)
        name = "probe_" * string(seed, pad = 2)
        source, calls = random_probe(rng, name)
        filename = "p" * string(seed, pad = 2) * ".jl"
        push!(files, filename => source)
        expected[filename] = calls
        push!(includes, "include(\"$filename\")")
    end
    spine = join(includes, "\n")
    case = load_package("CallGenerated", spine, files)
    (; case, expected)
end

const CALL_GENERATED = callsite_generated()
const CALL_GENERATED_CTX = case_context(CALL_GENERATED.case)
const CALL_GENERATED_SCANS = file_scans(CALL_GENERATED_CTX)

const CALL_HAND_FILES = [
    "keyed_f.jl" => "f(x::Int) = g(x)\nf(x::String) = h(x)\n",
    "keyed_s.jl" => """
    struct S
        x::Int
        S(x) = f(x)
        S(x, y) = g(x, y)
    end
    """,
    "keyed_t.jl" => "(::T)(x) = f(x)\n",
    "keyed_show.jl" => """
    function Base.show(io::IO, x::T)
        print(io, x)
    end
    """,
    "defaults.jl" => """
    function f(x = g(1); k = p(2))
        h(x)
    end
    """,
    "nested_fn.jl" => """
    function outer(a)
        function inner(b)
            f(b)
        end
        g(a)
    end
    """,
    "nested_do.jl" => """
    function do_outer()
        f() do x
            g(x)
        end
    end
    """,
    "header.jl" => """
    function header_outer()
        for i in g()
            h(i)
        end
    end
    """,
    "skip.jl" => """
    function skip_outer()
        (f(x))(y)
        arr[i](z)
    end
    """,
    "text.jl" => """
    function text_outer()
        f(x + # hi
            1)
    end
    """,
    "outside.jl" => "ready_fn(x) = identity(x)\nconst ready = ready_fn(1)\nfunction stub end\n",
]

function callsite_hand()
    includes = String["struct T end"]
    for (filename, _) in CALL_HAND_FILES
        push!(includes, "include(\"$filename\")")
    end
    spine = join(includes, "\n")
    load_package("CallHand", spine, CALL_HAND_FILES)
end

const CALL_HAND = callsite_hand()
const CALL_HAND_CTX = case_context(CALL_HAND)
const CALL_HAND_SCANS = file_scans(CALL_HAND_CTX)

@testset "generated call list matches the parse, seed $seed" for seed in 1:40
    filename = "p" * string(seed, pad = 2) * ".jl"
    scan = CALL_GENERATED_SCANS[filename]
    got = rows_by_site(scan)
    probe_name = Symbol("probe_" * string(seed, pad = 2))
    probe = MethodSite(probe_name, 1)
    expected = CALL_GENERATED.expected[filename]
    @test got == Dict(probe => expected)
end

@testset "a method's calls are keyed by its name and its line" begin
    expected_f = Dict(
        MethodSite(:f, 1) => [(:g, "", "x", "", 1, 0)],
        MethodSite(:f, 2) => [(:h, "", "x", "", 2, 0)],
    )
    expected_s = Dict(
        MethodSite(:S, 3) => [(:f, "", "x", "", 3, 0)],
        MethodSite(:S, 4) => [(:g, "", "x, y", "", 4, 0)],
    )
    expected_t = Dict(
        MethodSite(:T, 1) => [(:f, "", "x", "", 1, 0)],
    )
    expected_show = Dict(
        MethodSite(Symbol("Base.show"), 1) => [(:print, "", "io, x", "", 2, 0)],
    )
    @test rows_by_site(CALL_HAND_SCANS["keyed_f.jl"]) == expected_f
    @test rows_by_site(CALL_HAND_SCANS["keyed_s.jl"]) == expected_s
    @test rows_by_site(CALL_HAND_SCANS["keyed_t.jl"]) == expected_t
    @test rows_by_site(CALL_HAND_SCANS["keyed_show.jl"]) == expected_show
end

@testset "default arguments belong to their method, ahead of the body" begin
    got = rows_of(CALL_HAND_SCANS["defaults.jl"], :f, 1)
    expected = [
        (:g, "", "1", "", 1, 0),
        (:p, "", "2", "", 1, 0),
        (:h, "", "x", "", 2, 0),
    ]
    @test got == expected
end

@testset "a call inside a nested function or a do block belongs to the enclosing method" begin
    expected_fn = Dict(
        MethodSite(:outer, 1) => [
            (:f, "", "b", "", 3, 0),
            (:g, "", "a", "", 5, 0),
        ],
    )
    expected_do = Dict(
        MethodSite(:do_outer, 1) => [
            (:f, "", "do x g(x) end", "", 2, 0),
            (:g, "", "x", "", 3, 0),
        ],
    )
    @test rows_by_site(CALL_HAND_SCANS["nested_fn.jl"]) == expected_fn
    @test rows_by_site(CALL_HAND_SCANS["nested_do.jl"]) == expected_do
end

@testset "a call in a for header stays at the enclosing depth" begin
    got = rows_of(CALL_HAND_SCANS["header.jl"], :header_outer, 1)
    expected = [
        (:g, "", "", "", 2, 0),
        (:h, "", "i", "", 3, 1),
    ]
    @test got == expected
end

@testset "a call whose head is not a name is skipped" begin
    got = rows_of(CALL_HAND_SCANS["skip.jl"], :skip_outer, 1)
    @test got == [(:f, "", "x", "", 2, 0)]
end

@testset "argument text drops comments and collapses whitespace, and a nested call is kept" begin
    got = rows_of(CALL_HAND_SCANS["text.jl"], :text_outer, 1)
    expected = [
        (:f, "", "x + 1", "", 2, 0),
        (:+, "", "x, 1", "", 2, 0),
    ]
    @test got == expected
end

@testset "a call outside any method is not a call site" begin
    got = rows_by_site(CALL_HAND_SCANS["outside.jl"])
    expected = Dict(MethodSite(:ready_fn, 1) => [(:identity, "", "x", "", 1, 0)])
    @test got == expected
end
