# Call sites recorded on the scan: one vector per method, in source order.

function call_rows(calls)
    rows = Tuple{Symbol,String,String,String,Int,Int}[]
    for call in calls
        row = (call.callee, call.qualifier, call.arguments, call.keywords, call.line, call.loop_depth)
        push!(rows, row)
    end
    rows
end

function rows_of(scan, name, line)
    site = MethodSite(name, line)
    haskey(scan.callsites, site) || return Tuple{Symbol,String,String,String,Int,Int}[]
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

function random_probe(rng)
    lines = String["function probe()"]
    calls = Tuple{Symbol,String,String,String,Int,Int}[]
    count = rand(rng, 1:3)
    for _ in 1:count
        emit_stmt!(lines, calls, 0, rng)
    end
    push!(lines, "end")
    join(lines, "\n"), calls
end

@testset "generated call list matches the parse, seed $seed" for seed in 1:40
    rng = Xoshiro(seed)
    source, expected = random_probe(rng)
    scan = scan_defs(source)
    got = rows_by_site(scan)
    probe = MethodSite(:probe, 1)
    @test got == Dict(probe => expected)
end

@testset "a method's calls are keyed by its name and its line" begin
    cases = [
        (
            source = "f(x::Int) = g(x)\nf(x::String) = h(x)\n",
            expected = Dict(
                MethodSite(:f, 1) => [(:g, "", "x", "", 1, 0)],
                MethodSite(:f, 2) => [(:h, "", "x", "", 2, 0)],
            ),
        ),
        (
            source = """
            struct S
                x::Int
                S(x) = f(x)
                S(x, y) = g(x, y)
            end
            """,
            expected = Dict(
                MethodSite(:S, 3) => [(:f, "", "x", "", 3, 0)],
                MethodSite(:S, 4) => [(:g, "", "x, y", "", 4, 0)],
            ),
        ),
        (
            source = "(::T)(x) = f(x)\n",
            expected = Dict(
                MethodSite(:T, 1) => [(:f, "", "x", "", 1, 0)],
            ),
        ),
        (
            source = """
            function Base.show(io::IO, x::T)
                print(io, x)
            end
            """,
            expected = Dict(
                MethodSite(Symbol("Base.show"), 1) => [(:print, "", "io, x", "", 2, 0)],
            ),
        ),
    ]
    for case in cases
        scan = scan_defs(case.source)
        @test rows_by_site(scan) == case.expected
    end
end

@testset "default arguments belong to their method, ahead of the body" begin
    source = """
    function f(x = g(1); k = p(2))
        h(x)
    end
    """
    scan = scan_defs(source)
    got = rows_of(scan, :f, 1)
    expected = [
        (:g, "", "1", "", 1, 0),
        (:p, "", "2", "", 1, 0),
        (:h, "", "x", "", 2, 0),
    ]
    @test got == expected
end

@testset "a call inside a nested function or a do block belongs to the enclosing method" begin
    cases = [
        (
            source = """
            function outer(a)
                function inner(b)
                    f(b)
                end
                g(a)
            end
            """,
            expected = Dict(
                MethodSite(:outer, 1) => [
                    (:f, "", "b", "", 3, 0),
                    (:g, "", "a", "", 5, 0),
                ],
            ),
        ),
        (
            source = """
            function outer()
                f() do x
                    g(x)
                end
            end
            """,
            expected = Dict(
                MethodSite(:outer, 1) => [
                    (:f, "", "do x g(x) end", "", 2, 0),
                    (:g, "", "x", "", 3, 0),
                ],
            ),
        ),
    ]
    for case in cases
        scan = scan_defs(case.source)
        @test rows_by_site(scan) == case.expected
    end
end

@testset "a call in a for header stays at the enclosing depth" begin
    source = """
    function outer()
        for i in g()
            h(i)
        end
    end
    """
    scan = scan_defs(source)
    got = rows_of(scan, :outer, 1)
    expected = [
        (:g, "", "", "", 2, 0),
        (:h, "", "i", "", 3, 1),
    ]
    @test got == expected
end

@testset "a call whose head is not a name is skipped" begin
    source = """
    function outer()
        (f(x))(y)
        arr[i](z)
    end
    """
    scan = scan_defs(source)
    @test rows_of(scan, :outer, 1) == [(:f, "", "x", "", 2, 0)]
end

@testset "argument text drops comments and collapses whitespace, and a nested call is kept" begin
    source = """
    function outer()
        f(x + # hi
            1)
    end
    """
    scan = scan_defs(source)
    got = rows_of(scan, :outer, 1)
    expected = [
        (:f, "", "x + 1", "", 2, 0),
        (:+, "", "x, 1", "", 2, 0),
    ]
    @test got == expected
end

@testset "a call outside any method is not a call site" begin
    scan = scan_defs("const ready = f(1)\nfunction g end\n")
    @test isempty(scan.callsites)
end
