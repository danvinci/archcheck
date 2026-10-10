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
    @generated function zeros_of(::Type{S}) where {S}
        T = eltype(S)
        if T == Any
            T = Float64
        end
        items = [:(zero(\$T)) for _ in 1:2]
        :((\$(items...),))
    end
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

@testset "a boxed capture is found in the root, a submodule, another package's function, a generator, and code with no file" begin
    ctx = case_context(BOXED_REACH)
    found = ArchCheck.run(BoxedCaptures(), ctx)
    rows = sort([(f.mod, f.symbol) for f in found])
    expected = [(:BoxedReach, "at_root"), (:BoxedReach, "show"), (:BoxedReach, "unlocated"), (:BoxedReach, "zeros_of"),
                (:Inner, "own")]
    @test rows == expected
    unlocated = only(f for f in found if f.symbol == "unlocated")
    @test unlocated.file == "none"
    generated = only(f for f in found if f.symbol == "zeros_of")
    @test (generated.file, generated.line) == ("src/BoxedReach.jl", 20)
    @test ev(generated, :runs_at) == "compile time"
    at_root = only(f for f in found if f.symbol == "at_root")
    @test ev(at_root, :runs_at) == "call time"
end
