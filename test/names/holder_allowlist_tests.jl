# A struct field whose stored type holds a listed type, directly or as an element or parameter, belongs to a struct
# the type's list allows

const HOLDERS = load_package("Holders", """
include("shapes.jl")
include("Kept.jl")
""", [
    "shapes.jl" => """
    abstract type Surface end
    struct Patch <: Surface
        n::Int   # sample count
    end
    struct Law
        surface::Patch   # the one surface the law carries
    end
    struct Fit{T}
        payload::T              # free parameter
        parts::Vector{Patch}    # surfaces the fit is built from
    end
    struct Stray
        kept::Surface   # a surface by its abstract type
    end
    struct Maybe
        held::Union{Nothing,Patch}   # a surface or none
    end
    struct Many
        held::Tuple{Vararg{Patch}}   # surfaces in a row
    end
    struct Nested
        held::Dict{Symbol,Vector{Surface}}   # surfaces by name
    end
    struct Bounded{S<:Surface}
        held::S   # a parameter bounded by the type
    end
    struct Clean
        n::Int                 # count
        values::Vector{Float64}   # samples
    end
    const FitPatch = Fit{Patch}
    """,
    "Kept.jl" => """
    module Kept
    import ..Holders
    struct Inner
        surface::Holders.Patch   # a surface in a nested module
    end
    end
    """,
])

@testset "a field holding a listed type belongs to a struct its list allows" begin
    ctx = case_context(HOLDERS)
    package = HOLDERS.pkg
    check = HolderAllowlist(package.Surface => (package.Law,))
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :holds)
    @test rows == [(:unlisted_holder, "Bounded.held", "Holders.Surface"),
                   (:unlisted_holder, "Fit.parts", "Holders.Surface"),
                   (:unlisted_holder, "Inner.surface", "Holders.Surface"),
                   (:unlisted_holder, "Many.held", "Holders.Surface"),
                   (:unlisted_holder, "Maybe.held", "Holders.Surface"),
                   (:unlisted_holder, "Nested.held", "Holders.Surface"),
                   (:unlisted_holder, "Stray.kept", "Holders.Surface")]
    stray = only(finding for finding in found if finding.symbol == "Stray.kept")
    @test (stray.file, stray.line) == ("src/shapes.jl", 12)
    inner = only(finding for finding in found if finding.symbol == "Inner.surface")
    @test inner.mod === :Kept
    widened = HolderAllowlist(package.Surface => (package.Law, package.Fit, package.Kept.Inner, package.Stray,
                                                  package.Maybe, package.Many, package.Nested, package.Bounded))
    @test isempty(ArchCheck.run(widened, ctx))
    @test (:unlisted_holder => :advisory) in ArchCheck.kinds(check)
    @test_throws ArgumentError HolderAllowlist()
    @test_throws ArgumentError HolderAllowlist(package.Surface => (1,))
end
