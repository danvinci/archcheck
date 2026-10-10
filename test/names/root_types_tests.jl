# A package with submodules still defines types in its root module, and the checks that judge a type read them.

const ROOT_TYPES = load_package("RootTypes", """
    include("inner/Inner.jl")
    using .Inner
    abstract type Shape end
    struct Loose <: Shape
        value::Real
    end
    """, [
    "inner/Inner.jl" => """
    module Inner
    struct InnerLoose
        value::Real
    end
    end
    """,
])

@testset "the root module's types are judged beside a submodule's" begin
    ctx = case_context(ROOT_TYPES)
    fields = ArchCheck.run(AbstractFields(), ctx)
    field_rows = sort([(f.mod, f.symbol) for f in fields])
    @test field_rows == [(:Inner, "InnerLoose.value"), (:RootTypes, "Loose.value")]
    shape = ROOT_TYPES.pkg.Shape
    readers = ArchCheck.run(ReaderSet(shape, ((length, Tuple{}),)), ctx)
    reader_rows = [(f.mod, f.symbol) for f in readers]
    @test reader_rows == [(:RootTypes, "Loose.length")]
end
