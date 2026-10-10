# A closure that assigns a captured local boxes it, wherever the method sits: the root module of a package with
# submodules, a submodule, another package's function, or code evaluated with no file, reported as Julia recorded it.

const BOXED_REACH = load_package("BoxedReach", """
    include("inner/Inner.jl")
    using .Inner
    struct Shown end
    function Base.show(io::IO, ::Shown)
        count = 0
        bump = () -> (count += 1)
        bump()
        count = 2
        print(io, count)
    end
    function at_root()
        total = 0
        add = () -> (total += 1)
        add()
        total = 5
        total
    end
    unboxed(x) = map(y -> y + x, (1, 2))
    eval(Base.remove_linenums!(:(function unlocated()
        tally = 0
        step = () -> (tally += 1)
        step()
        tally = 4
        tally
    end)))
    """, [
    "inner/Inner.jl" => """
    module Inner
    function own()
        n = 0
        f = () -> (n += 1)
        f()
        n = 3
        n
    end
    end
    """,
])

@testset "a boxed capture is found in the root, a submodule, another package's function, and code with no file" begin
    ctx = case_context(BOXED_REACH)
    found = ArchCheck.run(BoxedCaptures(), ctx)
    rows = sort([(f.mod, f.symbol) for f in found])
    @test rows == [(:BoxedReach, "at_root"), (:BoxedReach, "show"), (:BoxedReach, "unlocated"), (:Inner, "own")]
    unlocated = only(f for f in found if f.symbol == "unlocated")
    @test unlocated.file == "none"
end
