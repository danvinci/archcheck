# A definition whose whole footprint sits in one lower place.
# synthetic modules for the reflection checks (duplicate-owner/sinkable), so their logic tests with no package load
module FakeLo
    struct LowType end
    const LowRun = Union{LowType,Int}
    pure_in_low(x::Int) = x + 1
end
module FakeMid
    struct MidType end
end
module FakeHi
    using ..FakeLo: LowType, LowRun
    using ..FakeMid: MidType
    struct OwnType end
    uses_run() = LowRun
    sig_own(v::OwnType) = v
    pure_in_high(y::Float64) = y
    body_own() = sig_own(OwnType())
    takes_low(v::LowType) = v
    helper_low(v::LowType) = v
    calls_helper() = helper_low(LowType())
    spans_two(a::LowType, b::MidType) = (a, b)
end

@testset "reflection checks (duplicate-owner, sinkable)" begin
    # a def whose whole footprint is one lower module is the candidate. One its own module calls stays.
    # A def that names only Base carries no module, so it carries no evidence either way.
    high_calls = Dict(:body_own => Set([:sig_own]), :calls_helper => Set([:helper_low]))
    high_calls[:uses_run] = Set([:LowRun])
    bc = Dict(:FakeHi => high_calls)
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    sink = check_sinkable([FakeLo, FakeHi], Dict(:FakeLo => [1], :FakeHi => [2]), bc, NO_SITES; repo)
    syms = Set(f.symbol for f in sink)
    @test "takes_low" in syms                       # footprint is the lower module alone -> candidate
    @test !("helper_low" in syms)                   # same footprint, but called at home -> stays
    @test !("pure_in_high" in syms)                 # Base-only -> no evidence, no finding
    @test !("sig_own" in syms)                      # own type in signature -> stays
    @test !("body_own" in syms)                     # own module in body -> stays
    @test !("pure_in_low" in syms)                  # already in the substrate -> not flagged
    flagged = only(f for f in sink if f.symbol == "takes_low")
    @test ev(flagged, :touches) == "FakeLo"
    @test ev(flagged, :sinks_to) == "FakeLo"                # one module in the footprint names it
    # no indexed site here, so this is the reflected fallback - it must carry a repo-relative path,
    # since `file` is part of the fingerprint that suppression and the new/fixed delta key on
    @test flagged.file == relpath(@__FILE__, repo)
    # a Union alias has no parentmodule: the module owning its binding is the one the body touches
    run_user = only(f for f in sink if f.symbol == "uses_run")
    @test ev(run_user, :sinks_to) == "FakeLo"
    # a footprint spanning two modules names no destination: the def may belong in a shared module
    # nobody has written yet
    wide = check_sinkable([FakeLo, FakeMid, FakeHi], Dict(:FakeLo => [1], :FakeMid => [2], :FakeHi => [3]), bc, NO_SITES; repo)
    spanning = only(f for f in wide if f.symbol == "spans_two")
    @test ev(spanning, :touches) == "FakeLo FakeMid"
    @test !any(k === :sinks_to for (k, _) in spanning.evidence)

    # duplicate-owner: same name, different objects, two modules -> collision; single owner -> clean
    dup = check_dup_owners([FDupA, FDupB], Dict(:FDupA => [1], :FDupB => [2]))
    @test length(dup) == 1 && dup[1].kind === :duplicate_owner && dup[1].symbol == "dup"
    @test isempty(check_dup_owners([FDupA], Dict(:FDupA => [1])))
end

@testset "file-sinkable (advisory)" begin
    files = Dict(:helper => "x.jl", :a => "y.jl", :b => "y.jl")
    calls = Dict(:helper => Set([:a, :b]), :a => Set{Symbol}(), :b => Set{Symbol}())

    # helper in x.jl calls only into y.jl, which ranks BELOW it -> it belongs down there
    down = CallGraph(:M, [:helper, :a, :b], files, calls, calls, Dict("y.jl" => 1, "x.jl" => 2))
    fs = only(check_file_sinkable(down, NO_SITES))
    @test fs.symbol == "helper" && fs.kind === :file_sinkable
    @test ev(fs, :callees_in) == "y.jl"
    
    @test ev(fs, :files_using_it) == "1/2"             # only helper's file reaches y.jl
    @test ev(fs, :callers_in_own_file) == "0"               # nothing in x.jl calls helper

    # same calls, but y.jl ranks above x.jl: an up-rank edge belongs to the back-edge check
    up = CallGraph(:M, [:helper, :a, :b], files, calls, calls, Dict("x.jl" => 1, "y.jl" => 2))
    @test isempty(check_file_sinkable(up, NO_SITES))
    @test length(check_file_backedges(up)) == 1        # reported once, by the check that owns it

    # callees spanning two files are an integrator, so the check reports nothing
    spread = Dict(:h => Set([:a, :b]), :a => Set{Symbol}(), :b => Set{Symbol}())
    cg2 = CallGraph(:M, [:h, :a, :b], Dict(:h => "x.jl", :a => "y.jl", :b => "z.jl"), spread, spread,
                    Dict("y.jl" => 1, "z.jl" => 2, "x.jl" => 3))
    @test isempty(check_file_sinkable(cg2, NO_SITES))

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")")
        write(joinpath(dir, "m", "low.jl"), "leaf(x) = x\n")
        write(joinpath(dir, "m", "high.jl"), """
            helper(x) = leaf(x)
            struct Long
                value::Int   # stored test value
                function Long(x)
                    new(helper(x))
                end
            end
            struct Short
                value::Int   # stored test value
                Short(x) = new(helper(x))
            end
            struct Parametric{T}
                value::T   # stored test value
                Parametric{T}(x) where {T} = new{T}(helper(x))
            end
            struct Shadow
                value::Int   # stored test value
                Shadow(helper) = new(helper(1))
            end
            """)
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = build_call_graph(index, :M)
        for owner in (:Long, :Short, :Parametric)
            @test !(owner in cg.funcs)
        end
        @test !(:helper in cg.calls[:Shadow])
        @test isempty(check_file_sinkable(cg, def_sites(index)))
    end

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")")
        write(joinpath(dir, "m", "low.jl"), "struct Law end\nleaf(x) = x\n")
        write(joinpath(dir, "m", "high.jl"), """
            helper(x) = leaf(x)
            (law::Law)(x) = helper(x)
            stray(x) = leaf(x)
            """)
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        cg = build_call_graph(index, :M)
        found = check_file_sinkable(cg, def_sites(index))
        @test !any(f -> f.symbol == "helper", found)
        stray = only(f for f in found if f.symbol == "stray")
        @test ev(stray, :callees_in) == "low.jl"
        @test ev(stray, :callers_in_own_file) == "0"
    end
end

@testset "extract-candidate (sinkable density)" begin
    sink = [Finding(:Geo, :sinkable, "surface.jl", "a", ""), Finding(:Geo, :sinkable, "surface.jl", "b", ""),
            Finding(:Geo, :sinkable, "surface.jl", "c", ""), Finding(:Geo, :sinkable, "resolve.jl", "d", "")]
    ec = only(check_extract_candidates(sink; min_defs = 3))
    @test ec.file == "surface.jl" && ec.kind === :extract_candidate
    @test ev(ec, :defs) == "3"
    # below threshold -> nothing
    @test isempty(check_extract_candidates([Finding(:Geo, :sinkable, "x.jl", "a", "")]; min_defs = 3))
end
