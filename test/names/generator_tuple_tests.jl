# `Tuple` built from a generator or comprehension has a length inference cannot know. `ntuple`, a Tuple of a tuple or
# a named vector, and a generator handed to another call are none

const GENERATED = load_package("Generated", """
include("tuples.jl")
""", [
    "tuples.jl" => """
    from_generator(items) = Tuple(item + 1 for item in items)
    from_filter(items) = Tuple(item for item in items if item > 0)
    from_comprehension(items) = Tuple([item for item in items])
    from_typed(items) = Tuple(Int[item for item in items])
    counted(n) = ntuple(position -> position, n)
    copied(pair::Tuple{Int,Int}) = Tuple(pair)
    from_vector(items::Vector{Int}) = Tuple(items)
    summed(items) = sum(item for item in items)
    """,
])

@testset "Tuple of a generator or comprehension is a finding and ntuple is none" begin
    ctx = case_context(GENERATED)
    found = ArchCheck.run(GeneratorTuples(), ctx)
    rows = evidence_rows(found, :argument)
    @test rows == [(:generator_tuple, "from_comprehension", "[item for item in items]"),
                   (:generator_tuple, "from_filter", "item for item in items if item > 0"),
                   (:generator_tuple, "from_generator", "item + 1 for item in items"),
                   (:generator_tuple, "from_typed", "Int[item for item in items]")]
    @test (:generator_tuple => :advisory) in ArchCheck.kinds(GeneratorTuples())
end
