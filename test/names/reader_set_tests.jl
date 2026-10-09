# A reader set names every method the workload requires.

const MISSING_READER = load_package("MissingReader", """
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
""")

const ANSWERED_READERS = load_package("AnsweredReaders", """
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
""")

const GENERIC_READER = load_package("GenericReader", """
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
""")

function reader_findings(case)
    pkg = case.pkg
    required = (
        (pkg.classify, Tuple{pkg.Point3D}),
        (pkg.section, Tuple{Float64}),
        (pkg.x_span, Tuple{}),
        (pkg.triangles, Tuple{}),
    )
    check = ReaderSet(pkg.Comp, required)
    ctx = case_context(case)
    ArchCheck.run(check, ctx)
end

@testset "a concrete subtype answers every reader in the set" begin
    unanswered = reader_findings(MISSING_READER)
    symbols = Set(finding.symbol for finding in unanswered)
    @test symbols == Set([
        "Bare.classify", "Bare.section", "Bare.x_span", "Bare.triangles",
        "Fam.classify", "Fam.section", "Fam.x_span", "Fam.triangles", "Flat.classify",
    ])
    bare = only(finding for finding in unanswered if finding.symbol == "Bare.classify")
    @test ev(bare, :reader) == "classify"
    identities = Set((finding.kind, finding.symbol, finding.file) for finding in unanswered)
    @test length(identities) == length(unanswered)

    answered = reader_findings(ANSWERED_READERS)
    @test isempty(answered)
    generic = reader_findings(GENERIC_READER)
    @test isempty(generic)
end
