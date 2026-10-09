# Expression clones and tolerance search, over generated trees.

let path = joinpath(pkgdir(ArchCheck), "src", "checks_clones.jl")
    isdefined(ArchCheck, :ExpressionClones) || Base.include(ArchCheck, path)
end

const CLONE_JS = ArchCheck.JS

function count_syntax(node)
    kids = CLONE_JS.children(node)
    isnothing(kids) && return 1
    total = 1
    for child in kids
        total += count_syntax(child)
    end
    total
end

# Node count of `expr` as a short-form method body. Independent of the check.
function expression_nodes(expr)
    source = "f(v1, v2, v3, v4) = " * expr
    tree = parse_file(source, "count.jl")
    method = CLONE_JS.children(tree)[1]
    body = CLONE_JS.children(method)[2]
    count_syntax(body)
end

function apply_locals(expr, pairs)
    renamed = expr
    for (from, to) in pairs
        pattern = Regex("\\b" * from * "\\b")
        renamed = replace(renamed, pattern => to)
    end
    renamed
end

function local_pairs(rng)
    pool = ["aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj", "kk", "ll",
            "mm", "nn", "oo", "pp", "qq", "rr", "ss", "tt"]
    picked = shuffle(rng, pool)
    names = picked[1:4]
    pairs = ["v1" => names[1], "v2" => names[2], "v3" => names[3], "v4" => names[4]]
    (names, pairs)
end

function method_line(name, params, expr)
    header = name * "(" * join(params, ", ") * ")"
    header * " = " * expr
end

function push_method!(lines, name, rng, expr)
    params, pairs = local_pairs(rng)
    renamed = apply_locals(expr, pairs)
    line = method_line(name, params, renamed)
    push!(lines, line)
end

function random_core(rng, depth)
    roll_leaf = rand(rng, 1:20)
    leaf = depth == 0 || roll_leaf <= 7
    if leaf
        roll = rand(rng, 1:4)
        roll == 1 && return "MOD"
        roll == 2 && return string(rand(rng, 1:8))
        slot = rand(rng, 1:4)
        return "v" * string(slot)
    end
    op = rand(rng, ("+", "-", "*"))
    left = random_core(rng, depth - 1)
    right = random_core(rng, depth - 1)
    "(" * left * " " * op * " " * right * ")"
end

function clones_index(dir, filename, source)
    src = joinpath(dir, "src")
    mkpath(src)
    spine = "module Flat\ninclude(\"$filename\")\nend\n"
    write(joinpath(src, "Flat.jl"), spine)
    write(joinpath(src, filename), source)
    layout = ArchCheck.package_layout(joinpath(src, "Flat.jl"), :Flat)
    rank = layout[1]
    dir2mod = layout[2]
    build_source_index(src, rank, dir2mod)
end

function clone_findings(index; min_nodes)
    check = ArchCheck.ExpressionClones(; min_nodes = min_nodes)
    run_checks((index = index,), (check,))
end

function search_record(finding)
    search = ev(finding, :search)
    tolerance = ev(finding, :tolerance)
    (finding.symbol, search, tolerance)
end

@testset "renamed locals are one clone, and a changed literal, operator, free name, or field is not" begin
    rng = Xoshiro(11)
    core = random_core(rng, 4)
    full = "(" * core * " + v1 + KEEPER + 41)"
    nodes = expression_nodes(full)
    near = "(" * core * " + v1 + KEEPER + 43)"
    other = "(" * core * " + v1 + OTHER + 41)"
    flipped = "(" * core * " - v1 + KEEPER + 41)"
    lines = String[]
    labels = String[]
    for name in ("alpha", "beta", "gamma")
        push_method!(lines, name, rng, full)
        label = "src/expr.jl:" * name
        push!(labels, label)
    end
    push_method!(lines, "near", rng, near)
    push_method!(lines, "other", rng, other)
    push_method!(lines, "flipped", rng, flipped)
    mktempdir() do dir
        source = join(lines, "\n") * "\n"
        index = clones_index(dir, "expr.jl", source)
        found = clone_findings(index; min_nodes = nodes)
        group = only(found)
        @test group.kind === :expression_clone
        @test group.mod === :Flat
        @test ev(group, :nodes) == string(nodes)
        @test ev(group, :methods) == join(labels, " ")
    end
    field_nodes = expression_nodes("axis.axis + axis.axis")
    field_source = "east(axis) = axis.axis + axis.axis\n" *
                   "west(width) = width.axis + width.axis\n" *
                   "south(width) = width.other + width.other\n"
    mktempdir() do dir
        index = clones_index(dir, "field.jl", field_source)
        found = clone_findings(index; min_nodes = field_nodes)
        group = only(found)
        @test ev(group, :methods) == "src/field.jl:east src/field.jl:west"
    end
end

@testset "a clone nested in a larger one reports the larger" begin
    rng = Xoshiro(12)
    inner_core = random_core(rng, 3)
    inner = "(" * inner_core * " + v1 + 5)"
    outer = "hold(" * inner * ", KEEPER)"
    inner_nodes = expression_nodes(inner)
    outer_nodes = expression_nodes(outer)
    lines = String[]
    push_method!(lines, "outer_a", rng, outer)
    push_method!(lines, "outer_b", rng, outer)
    mktempdir() do dir
        source = join(lines, "\n") * "\n"
        index = clones_index(dir, "nest.jl", source)
        found = clone_findings(index; min_nodes = inner_nodes)
        group = only(found)
        @test ev(group, :nodes) == string(outer_nodes)
        @test ev(group, :methods) == "src/nest.jl:outer_a src/nest.jl:outer_b"
    end
end

@testset "min_nodes holds at n - 1 and at n" begin
    function chain(extra)
        parts = String["v1", "KEEPER"]
        for _ in 1:extra
            push!(parts, "1")
        end
        join(parts, " + ")
    end
    small = chain(2)
    large = chain(3)
    small_nodes = expression_nodes(small)
    large_nodes = expression_nodes(large)
    @test large_nodes == small_nodes + 1
    large_p = apply_locals(large, ["v1" => "p"])
    large_q = apply_locals(large, ["v1" => "q"])
    small_p = apply_locals(small, ["v1" => "p"])
    small_q = apply_locals(small, ["v1" => "q"])
    source = "big_a(p) = " * large_p * "\n" *
             "big_b(q) = " * large_q * "\n" *
             "small_a(p) = " * small_p * "\n" *
             "small_b(q) = " * small_q * "\n"
    mktempdir() do dir
        index = clones_index(dir, "bound.jl", source)
        at_n = clone_findings(index; min_nodes = large_nodes)
        reported = only(at_n)
        @test ev(reported, :nodes) == string(large_nodes)
        methods = ev(reported, :methods)
        @test !occursin("small_", methods)
        at_prev = clone_findings(index; min_nodes = small_nodes)
        sizes = Set(ev(group, :nodes) for group in at_prev)
        small_label = string(small_nodes)
        large_label = string(large_nodes)
        expected_sizes = Set([small_label, large_label])
        @test sizes == expected_sizes
    end
end

@testset "two copies in one method are not a clone group" begin
    nodes = expression_nodes("v1 + KEEPER + 41")
    source = "only(v1) = (v1 + KEEPER + 41) + (v1 + KEEPER + 41)\n"
    mktempdir() do dir
        index = clones_index(dir, "once.jl", source)
        found = clone_findings(index; min_nodes = nodes)
        @test isempty(found)
    end
end

@testset "a search that reaches a configured tolerance is a finding, and one that does not is not" begin
    source = """
    function direct(xs, target)
        findfirst(x -> abs(x - target) < GEOM_EPS, xs)
    end
    function from_end(xs, target)
        findlast(x -> abs(x - target) <= GEOM_EPS, xs)
    end
    function every_hit(xs, target)
        findall(x -> isapprox(x, target; atol = GEOM_EPS), xs)
    end
    function by_local(xs, target)
        close(x) = abs(x - target) < GEOM_EPS
        findfirst(close, xs)
    end
    function by_chain(xs, target)
        nearer(x) = abs(x - target) < GEOM_EPS
        close(x) = nearer(x)
        findfirst(close, xs)
    end
    function by_block(xs, target)
        findfirst(xs) do x
            abs(x - target) < GEOM_EPS
        end
    end
    function validate_all(xs, target)
        all(x -> abs(x - target) < GEOM_EPS, xs)
    end
    function validate_any(xs, target)
        any(x -> abs(x - target) < GEOM_EPS, xs)
    end
    function exact(xs, target)
        findfirst(x -> x == target, xs)
    end
    function other_tol(xs, target)
        findfirst(x -> abs(x - target) < OTHER_EPS, xs)
    end
    function bare_approx(xs, target)
        findfirst(x -> isapprox(x, target), xs)
    end
    """
    mktempdir() do dir
        index = clones_index(dir, "tol.jl", source)
        check = ArchCheck.ToleranceSearch((:GEOM_EPS,))
        found = run_checks((index = index,), (check,))
        got = Set(search_record(finding) for finding in found)
        expected = Set([
            ("direct", "findfirst", "GEOM_EPS"),
            ("from_end", "findlast", "GEOM_EPS"),
            ("every_hit", "findall", "GEOM_EPS"),
            ("by_local", "findfirst", "GEOM_EPS"),
            ("by_chain", "findfirst", "GEOM_EPS"),
            ("by_block", "findfirst", "GEOM_EPS"),
        ])
        @test got == expected
        @test all(f -> f.kind === :tolerance_search && f.mod === :Flat, found)
    end
end
