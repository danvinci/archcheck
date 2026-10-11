# An argument or local no read resolves to, and a position every method of a function leaves unread. Julia's scope
# rules decide which binding a name resolves to.

const UNUSED_REACH = load_package("UnusedReach", """
    plain(x, y) = x
    keyed(x; k = 1, extra = 2) = x + k
    defaulted(x; k = x) = k
    padded(x, y = 2) = x
    mapped(xs) = map(item -> 1, xs)
    function assigns(a)
        spare = 3
        for step in 1:2
            a += 1
        end
        a
    end
    macro passed(ex, extra)
        esc(ex)
    end
    @generated function picked(a, b)
        (kind = a; :(a))
    end
    picks(flag, x::Int) = x
    picks(flag, x::Float64) = 2x
    routes(x, ::Int) = 1
    routes(x, ::String) = 2
    for T in (Int, Float64)
        @eval looped(x::\$T, y) = x
    end
    quiet(_unused, n) = n
    required(x; req) = (x, req)
    rounds(a; inner = map(k -> 1, a)) = inner
    hinted(@nospecialize(a), b) = b
    @generated function filled(rng, n)
        items = [:(rng) for _ in 1:2]
        :((\$(items...),))
    end
    function reuses(a)
        total = 0
        for v in a
            total = v
        end
        total
    end
    function shadows()
        kept = 1
        let
            local kept = 2
        end
        kept
    end
    counter = 0
    function bumps()
        counter = 1
        nothing
    end
    macro drop(code)
        esc(code)
    end
    dropped(y::Int) = @drop 1
    dropped(y::Float64) = @drop y
    macro symbolic(name::Symbol)
        esc(name)
    end
    function quoted()
        spare = 1
        :(@symbolic 1)
    end
    function pretty(xs)
        spare = 1
        round.(xs, sigdigits=3)
        round(xs, digits=2)
    end
    module Sub
    macro void()
        nothing
    end
    end
    @eval Sub dropped_sub(y) = @void()
    """)

@testset "an unread argument or local is found, including one a package macro's expansion drops; underscore names, unnamed arguments, and a name the expansion holds are exempt" begin
    ctx = case_context(UNUSED_REACH)
    found = ArchCheck.run(UnusedBindings(), ctx)
    rows = sort([(f.kind, f.symbol, f.line) for f in found if f.kind !== :ignored_parameter])
    expected = [
        (:unused_argument, "@passed:extra", 14),
        (:unused_argument, "dropped:y", 57),
        (:unused_argument, "hinted:a", 30),
        (:unused_argument, "keyed:extra", 3),
        (:unused_argument, "looped:y", 25),
        (:unused_argument, "mapped:item", 6),
        (:unused_argument, "padded:y", 5),
        (:unused_argument, "picks:flag", 20),
        (:unused_argument, "picks:flag", 21),
        (:unused_argument, "plain:y", 2),
        (:unused_argument, "rounds:k", 29),
        (:unused_argument, "routes:x", 22),
        (:unused_argument, "routes:x", 23),
        (:unused_local, "assigns:spare", 8),
        (:unused_local, "assigns:step", 9),
        (:unused_local, "bumps:counter", 51),
        (:unused_local, "picked:kind", 18),
        (:unused_local, "pretty:spare", 67),
        (:unused_local, "quoted:spare", 63),
        (:unused_local, "shadows:kept", 45),
    ]
    @test !any(finding -> endswith(finding.symbol, ":sigdigits"), found)
    @test !any(finding -> endswith(finding.symbol, ":digits"), found)
    @test rows == expected
    picked = only(f for f in found if f.symbol == "picked:kind")
    @test ev(picked, :runs_at) == "compile time"
    plain = only(f for f in found if f.symbol == "plain:y")
    @test ev(plain, :runs_at) == "call time"
end

@testset "a position every method leaves unread under one declared type is ignored, its macros expanded where the method is defined; a position whose type dispatches is not" begin
    ctx = case_context(UNUSED_REACH)
    found = ArchCheck.run(UnusedBindings(), ctx)
    ignored = [f for f in found if f.kind === :ignored_parameter]
    rows = evidence_rows(ignored, :position, :methods)
    expected = [
        (:ignored_parameter, "dropped_sub:1", "1", "1"),
        (:ignored_parameter, "hinted:1", "1", "1"),
        (:ignored_parameter, "looped:2", "2", "2"),
        (:ignored_parameter, "picks:1", "1", "2"),
        (:ignored_parameter, "plain:2", "2", "1"),
        (:ignored_parameter, "quiet:1", "1", "1"),
        (:ignored_parameter, "routes:1", "1", "2"),
    ]
    @test rows == expected
end
