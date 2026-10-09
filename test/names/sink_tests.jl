# A definition whose whole footprint sits in one lower place.

const LAYERED_PLACE = load_package("LayeredPlace", """
include("lo/Lo.jl")
using .Lo
include("mid/Mid.jl")
using .Mid
include("hi/Hi.jl")
using .Hi
""", [
    "lo/Lo.jl" => """
    module Lo
    struct LowType end
    const LowRun = Union{LowType,Int}
    pure_in_low(x::Int) = x + 1
    end
    """,
    "mid/Mid.jl" => """
    module Mid
    struct MidType end
    end
    """,
    "hi/Hi.jl" => """
    module Hi
    using ..Lo: LowType, LowRun
    using ..Mid: MidType
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
    """,
])

const DUPLICATE_NAME = load_package("DuplicateName", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\nexport dup\ndup() = 1\nend\n",
    "bb/Bb.jl" => "module Bb\nexport dup\ndup() = 2\nend\n",
])

const SOLO_NAME = load_package("SoloName", "export present\npresent() = 1\n")

const NESTED_NAME = load_package("NestedName", """
export tokens
tokens() = 1
include("lexer.jl")
""", ["lexer.jl" => "module Lexer\nexport tokens\ntokens() = 2\nend\n"])

const EXTRACT_BATCH = load_package("ExtractBatch", """
include("lo/Lo.jl")
using .Lo
include("hi/Hi.jl")
using .Hi
""", [
    "lo/Lo.jl" => "module Lo\nstruct LowType end\nend\n",
    "hi/Hi.jl" => "module Hi\nusing ..Lo: LowType\ninclude(\"many.jl\")\ninclude(\"one.jl\")\nend\n",
    "hi/many.jl" => "take_a(v::LowType) = v\ntake_b(v::LowType) = v\ntake_c(v::LowType) = v\n",
    "hi/one.jl" => "take_d(v::LowType) = v\n",
])

const DOWNWARD_SINK = load_package("DownwardSink", """
include("low.jl")
include("high.jl")
""", [
    "low.jl" => "leaf(x) = x\n",
    "high.jl" => "stray(x) = leaf(x)\n",
])

const UPWARD_SINK = load_package("UpwardSink", """
include("early.jl")
include("late.jl")
""", [
    "early.jl" => "helper(x) = leaf(x)\n",
    "late.jl" => "leaf(x) = x\n",
])

const SPREAD_SINK = load_package("SpreadSink", """
include("ay.jl")
include("bee.jl")
include("top.jl")
""", [
    "ay.jl" => "ay() = 1\n",
    "bee.jl" => "bee() = 1\n",
    "top.jl" => "spread() = ay() + bee()\n",
])

const SHADOWED_HELPER = load_package("ShadowedHelper", """
include("low.jl")
include("high.jl")
""", [
    "low.jl" => "leaf(x) = x\n",
    "high.jl" => """
    helper(x) = leaf(x)
    struct Shadow
        value::Int
        Shadow(helper) = new(helper(1))
    end
    """,
])

const CALLED_HELPER = load_package("CalledHelper", """
include("low.jl")
include("high.jl")
""", [
    "low.jl" => "leaf(x) = x\n",
    "high.jl" => "helper(x) = leaf(x)\nuse() = helper(1)\n",
])

const CONSTRUCTOR_HELPERS = load_package("ConstructorHelpers", """
include("low.jl")
include("high.jl")
""", [
    "low.jl" => "leaf(x) = x\n",
    "high.jl" => """
    helper(x) = leaf(x)
    struct Long
        value::Int
        function Long(x)
            new(helper(x))
        end
    end
    struct Short
        value::Int
        Short(x) = new(helper(x))
    end
    struct Parametric{T}
        value::T
        Parametric{T}(x) where {T} = new{T}(helper(x))
    end
    stray(x) = leaf(x)
    """,
])

const LAW_CALLABLE = load_package("LawCallable", """
include("low.jl")
include("high.jl")
""", [
    "low.jl" => "struct Law end\nleaf(x) = x\n",
    "high.jl" => """
    helper(x) = leaf(x)
    (law::Law)(x) = helper(x)
    stray(x) = leaf(x)
    """,
])

function module_sinkable(case)
    ctx = case_context(case)
    ArchCheck.run(Sinkable(), ctx)
end

function file_sinkable(case)
    ctx = case_context(case)
    ArchCheck.run(FileSinkable(), ctx)
end

@testset "a definition whose footprint is one lower module can move there" begin
    found = module_sinkable(LAYERED_PLACE)
    symbols = Set(finding.symbol for finding in found)
    @test "takes_low" in symbols
    @test !("helper_low" in symbols)
    @test !("pure_in_high" in symbols)
    @test !("sig_own" in symbols)
    @test !("body_own" in symbols)
    @test !("pure_in_low" in symbols)
    takes = only(finding for finding in found if finding.symbol == "takes_low")
    @test ev(takes, :touches) == "Lo"
    @test ev(takes, :sinks_to) == "Lo"
    @test endswith(takes.file, "Hi.jl")
    run_user = only(finding for finding in found if finding.symbol == "uses_run")
    @test ev(run_user, :sinks_to) == "Lo"
    wide = only(finding for finding in found if finding.symbol == "spans_two")
    @test ev(wide, :touches) == "Lo Mid"
    @test !any(pair -> pair.first === :sinks_to, wide.evidence)
end

@testset "a module and one it encloses exporting one name collide only when strict" begin
    ctx = case_context(NESTED_NAME)
    @test isempty(ArchCheck.run(OwnerUniqueness(), ctx))
    strict_found = ArchCheck.run(OwnerUniqueness(strict = true), ctx)
    nested = only(strict_found)
    @test ev(nested, :owners) == "NestedName Lexer"
end

@testset "two modules exporting one name bound to different objects collide" begin
    ctx = case_context(DUPLICATE_NAME)
    found = ArchCheck.run(OwnerUniqueness(), ctx)
    dup = only(found)
    @test dup.kind === :duplicate_owner
    @test dup.symbol == "dup"
    @test ev(dup, :owners) == "Aa Bb"
    solo_ctx = case_context(SOLO_NAME)
    solo = ArchCheck.run(OwnerUniqueness(), solo_ctx)
    @test isempty(solo)
end

@testset "three sinkable definitions in one file are an extract candidate" begin
    found = module_sinkable(EXTRACT_BATCH)
    candidates = [finding for finding in found if finding.kind === :extract_candidate]
    candidate = only(candidates)
    @test endswith(candidate.file, "many.jl")
    @test ev(candidate, :defs) == "3"
end

@testset "a definition whose callees share one lower file can move there" begin
    down = file_sinkable(DOWNWARD_SINK)
    stray = only(down)
    @test stray.symbol == "stray"
    @test stray.kind === :file_sinkable
    @test ev(stray, :callees_in) == "low.jl"
    @test ev(stray, :files_using_it) == "1/2"
    @test ev(stray, :callers_in_own_file) == "0"

    up = file_sinkable(UPWARD_SINK)
    @test isempty(up)
    up_ctx = case_context(UPWARD_SINK)
    backs = ArchCheck.run(FileBackEdges(), up_ctx)
    @test length(backs) == 1

    spread = file_sinkable(SPREAD_SINK)
    @test isempty(spread)
end

@testset "a parameter named like a callee is not a call and a constructor is" begin
    shadow = file_sinkable(SHADOWED_HELPER)
    shadow_names = Set(finding.symbol for finding in shadow)
    @test "helper" in shadow_names
    called = file_sinkable(CALLED_HELPER)
    @test !any(finding -> finding.symbol == "helper", called)

    ctors = file_sinkable(CONSTRUCTOR_HELPERS)
    ctor_names = Set(finding.symbol for finding in ctors)
    @test ctor_names == Set(["stray"])
end

@testset "a callable keeps the helper it calls and a stray call can move down" begin
    found = file_sinkable(LAW_CALLABLE)
    symbols = Set(finding.symbol for finding in found)
    @test !("helper" in symbols)
    stray = only(finding for finding in found if finding.symbol == "stray")
    @test ev(stray, :callees_in) == "low.jl"
    @test ev(stray, :callers_in_own_file) == "0"
end
