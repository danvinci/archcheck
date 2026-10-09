# Field types stay closed, and a field read stays on a struct the caller's module may read.
# abstract-field corpus: closed storage vs every open-dispatch shape the check names
module FAbs
    abstract type Abs end
    struct Closed
        xs::Vector{Float64}   # field type
        t::Type{Float64}   # field type
        u::Union{Float64,Nothing}   # field type
    end
    struct Open
        xs::Vector   # field type
        any::Vector{Any}   # field type
        absv::AbstractVector   # field type
        absf::AbstractVector{Float64}   # field type
        d::Dict   # field type
        da::Dict{Int,Any}   # field type
        s::Set   # field type
        map::Type{<:Integer}   # field type
        r::Real   # field type
        spec::Abs   # field type
    end
    struct Param{T}
        x::T   # field type
        ys::Vector   # field type
        zs::Vector{T}   # field type
        r::Real   # field type
        ws::Vector{Pair{K,T} where K}   # names T, and each element is still a family over K
    end
end

@testset "abstract-field" begin
    found = ArchCheck.check_abstract_fields([FAbs], NO_SITES)
    syms = Set(f.symbol for f in found)

    @test "Open.xs" in syms && ev(only(f for f in found if f.symbol == "Open.xs"), :declared) == "Vector"
    @test "Open.any" in syms
    @test "Open.absv" in syms
    @test "Open.absf" in syms
    @test "Open.d" in syms && "Open.s" in syms
    @test "Open.da" in syms
    @test "Open.map" in syms
    @test "Open.r" in syms && "Open.spec" in syms

    @test !("Closed.xs" in syms)
    @test !("Closed.t" in syms)          # Type{Float64} holds that one type object
    @test !("Closed.u" in syms)          # small Union, lowering splits it

    @test !("Param.x" in syms) && !("Param.zs" in syms)   # names the parameter, closes on use
    @test "Param.ys" in syms && "Param.r" in syms         # independent of T, open on every instantiation
    @test "Param.ws" in syms                              # names T, yet each element is a family no T fixes
end

@testset "foreign fields: a field read on another module's struct" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.ForeignFields(),)
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    reads = Set((string(f.mod), f.symbol) for f in findings)
    # Span is public and documented: the field it documents is open, the field it leaves bare is not
    @test !(("Hi", "Low.Span.lo") in reads)
    @test ("Hi", "Low.Span.hi") in reads
    # Mark is public and documents its field but not itself, so Julia records no field docstring
    @test ("Hi", "Low.Mark.at") in reads
    # Ring documents itself and its field, but Cuts keeps it internal
    @test ("Hi", "Geo.Cuts.Ring.radius") in reads
    # OpenBox is public and documents nothing
    @test ("Geo.Cuts", "Geo.Curves.OpenBox.held") in reads
    # Tick is Low's own, read through receivers only inference types
    @test ("Hi", "Low.Tick.at") in reads
    # a receiver annotated with a Union reads the field on each member, owned by that member's module
    @test ("Hi", "Low.Notch.at") in reads
    @test ("Hi", "Geo.Cuts.Arc.at") in reads
    # a chain through a Union reads its next field on each member's declared field type
    @test ("Hi", "Low.Pin.depth") in reads
    @test ("Hi", "Geo.Cuts.Kerf.depth") in reads
    # no other read is flagged
    @test length(reads) == 9
end
