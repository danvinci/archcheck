# A wide anonymous tuple return is a finding. A named tuple is a record.

const TUPLE_BODIES = load_package("TupleBodies", """
include("body.jl")
""", [
    "body.jl" => """
    three() = (a, b, c)
    pair() = (a, b)
    named() = (x = a, y = b, z = c)
    blocky() = begin
        q = 1
        return (a, b, c, d)
    end
    """,
])

@testset "a wide anonymous tuple return is a finding and a named tuple is a record" begin
    ctx = case_context(TUPLE_BODIES)
    found = ArchCheck.run(TupleReturns(), ctx)
    rows = evidence_rows(found, :slots)
    @test rows == [(:tuple_return, "blocky", "4"), (:tuple_return, "three", "3")]
    @test (:tuple_return => :advisory) in ArchCheck.kinds(TupleReturns())
end
