# A closure that assigns a captured local boxes it, wherever the method sits: the root module of a package with
# submodules, a submodule, or another package's function.

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

@testset "a boxed capture is found in the root, a submodule, and a method on another package's function" begin
    ctx = case_context(BOXED_REACH)
    found = ArchCheck.run(BoxedCaptures(), ctx)
    rows = sort([(f.mod, f.symbol) for f in found])
    @test rows == [(:BoxedReach, "at_root"), (:BoxedReach, "show"), (:Inner, "own")]
end
