# A reader set names every method the workload requires.
# reader-set corpus: missing methods, a complete type, inherited generics, 2D and 3D shapes
module FReadMissing
    abstract type Comp end
    abstract type AbsOnly <: Comp end
    struct Point3D end
    struct Point2D end
    struct Bare <: Comp end
    struct Fam{T} <: Comp end
    struct Flat <: Comp end
    const Alias = Bare
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Flat, ::Point2D) = :inside
    section(::Flat, ::Float64) = nothing
    x_span(::Flat) = nothing
    triangles(::Flat) = nothing
end
module FReadComplete
    abstract type Comp end
    struct Point3D end
    struct Full <: Comp end
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Full, ::Point3D) = :inside
    section(::Full, ::Float64) = nothing
    x_span(::Full) = nothing
    triangles(::Full) = nothing
end
module FReadGeneric
    abstract type Comp end
    struct Point3D end
    struct Covered <: Comp end
    struct Param{T} <: Comp end
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Comp, ::Point3D) = :inside
    section(::Comp, ::Float64) = nothing
    x_span(::Comp) = nothing
    triangles(::Comp) = nothing
end

@testset "reader-set" begin
    missing_required = (
        (FReadMissing.classify, Tuple{FReadMissing.Point3D}),
        (FReadMissing.section, Tuple{Float64}),
        (FReadMissing.x_span, Tuple{}),
        (FReadMissing.triangles, Tuple{}),
    )
    missing = check_reader_set([FReadMissing], FReadMissing.Comp, missing_required; sites = NO_SITES)
    syms = Set(f.symbol for f in missing)
    @test syms == Set(["Bare.classify", "Bare.section", "Bare.x_span", "Bare.triangles",
                      "Fam.classify", "Fam.section", "Fam.x_span", "Fam.triangles", "Flat.classify"])
    @test ev(only(f for f in missing if f.symbol == "Bare.classify"), :reader) == "classify"
    @test length(unique(fingerprint.(missing))) == length(missing)

    complete_required = (
        (FReadComplete.classify, Tuple{FReadComplete.Point3D}),
        (FReadComplete.section, Tuple{Float64}),
        (FReadComplete.x_span, Tuple{}),
        (FReadComplete.triangles, Tuple{}),
    )
    @test isempty(check_reader_set([FReadComplete], FReadComplete.Comp, complete_required; sites = NO_SITES))

    generic_required = (
        (FReadGeneric.classify, Tuple{FReadGeneric.Point3D}),
        (FReadGeneric.section, Tuple{Float64}),
        (FReadGeneric.x_span, Tuple{}),
        (FReadGeneric.triangles, Tuple{}),
    )
    @test isempty(check_reader_set([FReadGeneric], FReadGeneric.Comp, generic_required; sites = NO_SITES))
end
