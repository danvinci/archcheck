# Expression clones and tolerance search. The node count is read from the syntax tree itself.

expression_nodes(expr) = body_nodes("f(v1, v2, v3, v4) = " * expr)

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
    pairs = ["v$slot" => name for (slot, name) in enumerate(names)]
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

function clone_case(name, filename, source)
    spine = "include(\"$filename\")\n"
    files = [filename => source]
    load_package(name, spine, files)
end

function clone_found(case, min_nodes)
    ctx = case_context(case)
    check = ExpressionClones(; min_nodes = min_nodes)
    ArchCheck.run(check, ctx)
end

function search_record(finding)
    search = ev(finding, :search)
    tolerance = ev(finding, :tolerance)
    (finding.symbol, search, tolerance)
end

function expr_lines()
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
    source = join(lines, "\n") * "\n"
    (; source, nodes, labels)
end

const CLONE_EXPR_BUILT = expr_lines()
const CLONE_EXPR = clone_case("CloneExpr", "expr.jl", CLONE_EXPR_BUILT.source)

const CLONE_FIELD_NODES = expression_nodes("axis.axis + axis.axis")
const CLONE_FIELD = clone_case("CloneField", "field.jl",
    "east(axis) = axis.axis + axis.axis\n" *
    "west(width) = width.axis + width.axis\n" *
    "south(width) = width.other + width.other\n")

function nest_built()
    rng = Xoshiro(12)
    inner_core = random_core(rng, 3)
    inner = "(" * inner_core * " + v1 + 5)"
    outer = "hold(" * inner * ", KEEPER)"
    inner_nodes = expression_nodes(inner)
    outer_nodes = expression_nodes(outer)
    lines = String[]
    push_method!(lines, "outer_a", rng, outer)
    push_method!(lines, "outer_b", rng, outer)
    source = join(lines, "\n") * "\n"
    (; source, inner_nodes, outer_nodes)
end

const CLONE_NEST_BUILT = nest_built()
const CLONE_NEST = clone_case("CloneNest", "nest.jl", CLONE_NEST_BUILT.source)

# Two expressions one node apart, so a threshold between them separates the pairs.
function bound_source()
    small = "v1 + KEEPER + 1 + 1"
    large = "v1 + KEEPER + 1 + 1 + 1"
    small_nodes = expression_nodes(small)
    large_nodes = expression_nodes(large)
    @assert large_nodes == small_nodes + 1
    large_p = apply_locals(large, ["v1" => "p"])
    large_q = apply_locals(large, ["v1" => "q"])
    small_p = apply_locals(small, ["v1" => "p"])
    small_q = apply_locals(small, ["v1" => "q"])
    source = "big_a(p) = " * large_p * "\n" *
             "big_b(q) = " * large_q * "\n" *
             "small_a(p) = " * small_p * "\n" *
             "small_b(q) = " * small_q * "\n"
    (; source, small_nodes, large_nodes)
end

const CLONE_BOUND_BUILT = bound_source()
const CLONE_BOUND = clone_case("CloneBound", "bound.jl", CLONE_BOUND_BUILT.source)

const CLONE_ONCE_NODES = expression_nodes("v1 + KEEPER + 41")
const CLONE_ONCE = clone_case("CloneOnce", "once.jl",
    "only(v1) = (v1 + KEEPER + 41) + (v1 + KEEPER + 41)\n")

const CLONE_TOL = clone_case("CloneTol", "tol.jl", """
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
""")

@testset "renamed locals are one clone, and a changed literal, operator, free name, or field is not" begin
    nodes = CLONE_EXPR_BUILT.nodes
    found = clone_found(CLONE_EXPR, nodes)
    group = only(found)
    @test group.kind === :expression_clone
    @test group.mod === :CloneExpr
    @test ev(group, :nodes) == string(nodes)
    @test ev(group, :methods) == join(CLONE_EXPR_BUILT.labels, " ")
    field_found = clone_found(CLONE_FIELD, CLONE_FIELD_NODES)
    field_group = only(field_found)
    @test ev(field_group, :methods) == "src/field.jl:east src/field.jl:west"
end

@testset "a clone nested in a larger one reports the larger" begin
    found = clone_found(CLONE_NEST, CLONE_NEST_BUILT.inner_nodes)
    group = only(found)
    @test ev(group, :nodes) == string(CLONE_NEST_BUILT.outer_nodes)
    @test ev(group, :methods) == "src/nest.jl:outer_a src/nest.jl:outer_b"
end

@testset "min_nodes holds at n - 1 and at n" begin
    small_nodes = CLONE_BOUND_BUILT.small_nodes
    large_nodes = CLONE_BOUND_BUILT.large_nodes
    at_n = clone_found(CLONE_BOUND, large_nodes)
    reported = only(at_n)
    @test ev(reported, :nodes) == string(large_nodes)
    methods = ev(reported, :methods)
    @test !occursin("small_", methods)
    at_prev = clone_found(CLONE_BOUND, small_nodes)
    sizes = Set(ev(group, :nodes) for group in at_prev)
    small_label = string(small_nodes)
    large_label = string(large_nodes)
    expected_sizes = Set([small_label, large_label])
    @test sizes == expected_sizes
end

@testset "two copies in one method are not a clone group" begin
    found = clone_found(CLONE_ONCE, CLONE_ONCE_NODES)
    @test isempty(found)
end

@testset "a search that reaches a configured tolerance is a finding, and one that does not is not" begin
    ctx = case_context(CLONE_TOL)
    check = ToleranceSearch((:GEOM_EPS,))
    found = ArchCheck.run(check, ctx)
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
    @test all(f -> f.kind === :tolerance_search && f.mod === :CloneTol, found)
end
