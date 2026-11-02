# A top-level function whose returned value is a generator hands its caller a generator to nest in another. A
# collection returned, a generator consumed inside, and a generator a closure or local method returns are none

const LAZY = load_package("Lazy", """
include("returns.jl")
""", [
    "returns.jl" => """
    doubled(items) = (item * 2 for item in items)
    filtered(items) = (item for item in items if item > 0)
    function early(items, stop::Bool)
        stop && return (item for item in items)
        Int[]
    end
    function branched(flag::Bool, items)
        if flag
            (item for item in items)
        else
            (item + 1 for item in items)
        end
    end
    eager(items) = [item for item in items]
    summed(items) = sum(item for item in items)
    counted(n) = ntuple(position -> position, n)
    function wrapped(items)
        each = () -> (item for item in items)
        collect(each())
    end
    function outer(items)
        inner() = (item for item in items)
        collect(inner())
    end
    """,
])

@testset "a top-level function returning a generator is a finding once, and a collection returned is none" begin
    ctx = case_context(LAZY)
    found = ArchCheck.run(GeneratorReturns(), ctx)
    rows = evidence_rows(found, :returns)
    @test rows == [(:generator_return, "branched", "item for item in items"),
                   (:generator_return, "doubled", "item * 2 for item in items"),
                   (:generator_return, "early", "item for item in items"),
                   (:generator_return, "filtered", "item for item in items if item > 0")]
    lines = Dict(f.symbol => f.line for f in found)
    @test lines["branched"] == 7
    @test (:generator_return => :advisory) in ArchCheck.kinds(GeneratorReturns())
end
