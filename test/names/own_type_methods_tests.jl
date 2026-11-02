# A method a listed module owns takes only the module's own types. A constructor, a method on another module's
# function and a method another module adds stay unjudged

const OWN_TYPES = load_package("OwnTypes", """
include("terms/Terms.jl")
using .Terms
Terms.pure(n::Int) = n
outside(n::Int) = n
""", [
    "terms/Terms.jl" => """
    module Terms
    struct Seam
        n::Int   # sample count
    end
    struct Edge
        n::Int   # edge count
    end
    Seam(edge::Edge) = Seam(edge.n)
    pure(seam::Seam) = seam.n
    paired(seam::Seam, edge::Edge) = seam.n + edge.n
    bounded(seam::S) where {S<:Seam} = seam.n
    either(part::Union{Seam,Edge}) = part.n
    keyed(seam::Seam; scale = 1) = seam.n * scale
    counted(seam::Seam, n::Int) = seam.n + n
    bare() = 1
    named(::Type{Seam}) = 1
    loose(part::Union{Seam,Int}) = 1
    defaults(seam::Seam, n::Int = 1) = seam.n + n
    listed(seams::Vector{Seam}) = length(seams)
    Base.length(seam::Seam) = seam.n
    end
    """,
])

@testset "a method a listed module owns takes only the module's own types" begin
    ctx = case_context(OWN_TYPES)
    terms = OWN_TYPES.pkg.Terms
    found = ArchCheck.run(OwnTypeMethods(terms), ctx)
    rows = evidence_rows(found, :takes)
    @test rows == [(:foreign_argument, "bare", ""),
                   (:foreign_argument, "counted", "Int64"),
                   (:foreign_argument, "defaults", "Int64"),
                   (:foreign_argument, "listed", "Array{OwnTypes.Terms.Seam, 1}"),
                   (:foreign_argument, "loose", "Union{Int64, OwnTypes.Terms.Seam}"),
                   (:foreign_argument, "named", "TypeEq{OwnTypes.Terms.Seam}")]
    @test all(finding -> finding.mod === :Terms, found)
    counted = only(finding for finding in found if finding.symbol == "counted")
    @test (counted.file, counted.line) == ("src/terms/Terms.jl", 14)
    @test (:foreign_argument => :advisory) in ArchCheck.kinds(OwnTypeMethods(terms))
    @test_throws ArgumentError OwnTypeMethods()
    @test_throws ArgumentError ArchCheck.run(OwnTypeMethods(Base), ctx)
end
