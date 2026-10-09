# Field types stay closed, and a field read stays on a struct the caller's module may read.

const OPEN_FIELDS = load_package("OpenFields", """
abstract type Abs end
struct Closed
    xs::Vector{Float64}
    t::Type{Float64}
    u::Union{Float64,Nothing}
end
struct Open
    xs::Vector
    any::Vector{Any}
    absv::AbstractVector
    absf::AbstractVector{Float64}
    d::Dict
    da::Dict{Int,Any}
    s::Set
    map::Type{<:Integer}
    r::Real
    spec::Abs
end
struct Param{T}
    x::T
    ys::Vector
    zs::Vector{T}
    r::Real
    ws::Vector{Pair{K,T} where K}
end
""")

const OPEN_FIELD_NAMES = Set([
    "Open.xs", "Open.any", "Open.absv", "Open.absf", "Open.d", "Open.s", "Open.da",
    "Open.map", "Open.r", "Open.spec", "Param.ys", "Param.r", "Param.ws",
])

@testset "a field whose stored type leaves dispatch open is a finding" begin
    ctx = case_context(OPEN_FIELDS)
    found = ArchCheck.run(AbstractFields(), ctx)
    symbols = Set(finding.symbol for finding in found)
    @test symbols == OPEN_FIELD_NAMES
    rows = evidence_rows(found, :declared)
    @test (:abstract_field, "Open.xs", "Vector") in rows
end

@testset "a field read on another module's struct is a finding" begin
    ctx = Context(Nested)
    found = ArchCheck.run(ForeignFields(), ctx)
    reads = Set((string(finding.mod), finding.symbol) for finding in found)
    @test reads == Set([
        ("Hi", "Low.Span.hi"),
        ("Hi", "Low.Mark.at"),
        ("Hi", "Geo.Cuts.Ring.radius"),
        ("Geo.Cuts", "Geo.Curves.OpenBox.held"),
        ("Hi", "Low.Tick.at"),
        ("Hi", "Low.Notch.at"),
        ("Hi", "Geo.Cuts.Arc.at"),
        ("Hi", "Low.Pin.depth"),
        ("Hi", "Geo.Cuts.Kerf.depth"),
    ])
end
