# Field types stay closed, and a field read stays on a struct the caller's module may read.

const OPEN_FIELDS = load_package("OpenFields", """
abstract type Abs end
struct Closed
    xs::Vector{Float64}
    t::Type{Float64}
    u::Union{Float64,Nothing}
    rows::Vector{Vector{Any}}
    groups::Dict{Symbol,Vector{Any}}
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
const Renamed = Open
const IntParam = Param{Int}
const VectorParam{T} = Param{Vector{T}}
const AnyParam = Param{Any}
""")

const OPEN_FIELD_NAMES = Set([
    "Open.xs", "Open.any", "Open.absv", "Open.absf", "Open.d", "Open.s", "Open.da",
    "Open.map", "Open.r", "Open.spec", "Param.ys", "Param.r", "Param.ws",
    "AnyParam.x", "AnyParam.zs",
])

# An alias repeats its struct's open fields; only an instance opening a field the struct keeps closed adds one. A
# container's own element types decide, so a concrete element closes it whatever that element holds.
@testset "a field whose stored type leaves dispatch open is a finding, once, where it is written" begin
    ctx = case_context(OPEN_FIELDS)
    found = ArchCheck.run(AbstractFields(), ctx)
    symbols = Set(finding.symbol for finding in found)
    @test symbols == OPEN_FIELD_NAMES
    @test length(found) == length(OPEN_FIELD_NAMES)
    rows = evidence_rows(found, :declared)
    @test (:abstract_field, "Open.xs", "Array{T, 1} where T") in rows
    @test (:abstract_field, "AnyParam.zs", "Array{Any, 1}") in rows
    alias_lines = Set(finding.line for finding in found if startswith(finding.symbol, "AnyParam."))
    @test alias_lines == Set([32])
    @test all(finding -> finding.line > 0, found)
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
        ("Hi", "Contracts.Record.values"),
    ])

    # The abstract type lives in the root. Low's structs declare the field, and Low reads it. Side reads it and
    # declares none. A name no struct declares has no declarer to judge.
    abstract_read = load_package("AbstractRead", """
    abstract type Plate end
    public Plate
    include("low/Low.jl")
    using .Low
    include("side/Side.jl")
    using .Side
    """, [
        "low/Low.jl" => """
        module Low
        import ..Plate
        struct Sheet <: Plate
            gauge::Float64
        end
        struct Strip{T} <: Plate
            gauge::T
        end
        sheet_gauge(plate::Plate) = plate.gauge
        end
        """,
        "side/Side.jl" => """
        module Side
        import ..Plate
        plate_gauge(plate::Plate) = plate.gauge
        blank_plate(plate::Plate) = plate.absent
        end
        """,
    ])
    abstract_ctx = case_context(abstract_read)
    abstract_found = ArchCheck.run(ForeignFields(), abstract_ctx)
    abstract_rows = [(string(finding.mod), finding.symbol, ev(finding, :declared)) for finding in abstract_found]
    @test abstract_rows == [("Side", "AbstractRead.Plate.gauge", "abstract")]
end
