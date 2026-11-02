# A method taking an argument of a closed type, a subtype or an instance of it, sits in a definition the type's list
# allows. A container of the type, a type object and an untyped argument take no value of it

const TAKERS = load_package("Takers", """
include("types.jl")
include("build.jl")
include("read.jl")
""", [
    "types.jl" => """
    struct Spec
        n::Int   # design count
    end
    abstract type Shape end
    struct Disk <: Shape
        r::Int   # radius
    end
    struct Wide{T}
        x::T   # payload
    end
    """,
    "build.jl" => """
    build(spec::Spec) = spec.n
    area(shape::Shape) = 0
    """,
    "read.jl" => """
    read_spec(spec::Spec) = spec.n
    maybe(spec::Union{Spec,Nothing}) = 1
    bounded(spec::S) where {S<:Spec} = spec.n
    splat(specs::Spec...) = length(specs)
    keyed(spec::Spec; scale = 1) = spec.n * scale
    Base.show(io::IO, spec::Spec) = print(io, spec.n)
    listed(specs::Vector{Spec}) = length(specs)
    named(::Type{Spec}) = 1
    untyped(value) = value
    area(disk::Disk) = disk.r
    build(spec::Spec, extra::Int) = spec.n + extra
    wide(held::Wide{Int}) = held.x
    wide_any(held::Wide) = 0
    """,
])

@testset "a method taking a closed type sits in a definition its list allows" begin
    ctx = case_context(TAKERS)
    package = TAKERS.pkg
    allowed = ("src/build.jl", :build)
    shaped = ("src/build.jl", :area)
    check = TakerAllowlist(package.Spec => (allowed,), package.Shape => (shaped,), package.Wide => ())
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :takes)
    @test rows == [(:unlisted_taker, "area", "Takers.Shape"),
                   (:unlisted_taker, "bounded", "Takers.Spec"),
                   (:unlisted_taker, "build", "Takers.Spec"),
                   (:unlisted_taker, "keyed", "Takers.Spec"),
                   (:unlisted_taker, "maybe", "Takers.Spec"),
                   (:unlisted_taker, "read_spec", "Takers.Spec"),
                   (:unlisted_taker, "show", "Takers.Spec"),
                   (:unlisted_taker, "splat", "Takers.Spec"),
                   (:unlisted_taker, "wide", "Takers.Wide"),
                   (:unlisted_taker, "wide_any", "Takers.Wide")]
    @test all(finding -> finding.file == "src/read.jl", found)
    area = only(finding for finding in found if finding.symbol == "area")
    @test area.line == 10
    @test (:unlisted_taker => :advisory) in ArchCheck.kinds(check)
    unused = TakerAllowlist(package.Spec => (allowed, ("src/read.jl", :untyped)))
    stale = only(finding for finding in ArchCheck.run(unused, ctx) if finding.kind === :stale_allowance)
    @test (stale.file, stale.symbol, ev(stale, :takes)) == ("src/read.jl", "untyped", "Takers.Spec")
    @test (:stale_allowance => :error) in ArchCheck.kinds(unused)
    @test_throws ArgumentError TakerAllowlist()
end
