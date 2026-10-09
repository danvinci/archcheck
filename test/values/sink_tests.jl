# File-sinkable at method grain. With no entries every method of a name is one node.
# Entries judge each method on the callees inference resolved for it.

function sink_findings(case; options...)
    ctx = case_context(case; options...)
    ArchCheck.run(FileSinkable(), ctx)
end

function sink_by_callee(findings, callee_file)
    matched = filter(finding -> ev(finding, :callees_in) == callee_file, findings)
    only(matched)
end

const SINK_SPLIT_SPINE = "include(\"low_a.jl\")\ninclude(\"low_b.jl\")\ninclude(\"left.jl\")\ninclude(\"right.jl\")\n"
const SINK_SPLIT = load_package("SinkSplit", SINK_SPLIT_SPINE, [
    "low_a.jl" => "alpha(x::Int) = x\n",
    "low_b.jl" => "beta(x::String) = x\n",
    "left.jl" => "split(x::Int) = alpha(x)\n",
    "right.jl" => "split(x::String) = beta(x)\n",
])

const SINK_HUB_SPINE = "include(\"low.jl\")\ninclude(\"a.jl\")\ninclude(\"b.jl\")\n"
const SINK_HUB = load_package("SinkHub", SINK_HUB_SPINE, [
    "low.jl" => "leaf(x::Int) = x\n",
    "a.jl" => "from_a(x::Int) = leaf(x)\n",
    "b.jl" => "from_b(x::Int) = leaf(x)\n",
])

const SINK_PASSED_SPINE = "include(\"low.jl\")\ninclude(\"wrap.jl\")\ninclude(\"pad_a.jl\")\ninclude(\"pad_b.jl\")\n"
const SINK_PASSED = load_package("SinkPassed", SINK_PASSED_SPINE, [
    "low.jl" => "helper(x::Int) = x\n",
    "wrap.jl" => "wrap(xs::Vector{Int}) = map(x -> helper(x), xs)\n",
    "pad_a.jl" => "pad_a(x::Int) = x\n",
    "pad_b.jl" => "pad_b(x::Int) = x\n",
])

const SINK_PLACED_SPINE = "include(\"low.jl\")\ninclude(\"home.jl\")\ninclude(\"away.jl\")\ninclude(\"pad_a.jl\")\ninclude(\"pad_b.jl\")\n"
const SINK_PLACED = load_package("SinkPlaced", SINK_PLACED_SPINE, [
    "low.jl" => "leaf(x::Int) = x\nleaf(x::String) = x\n",
    "home.jl" => "place(x::Int) = leaf(x)\nuses(x::Int) = place(x)\n",
    "away.jl" => "place(x::String) = leaf(x)\n",
    "pad_a.jl" => "pad_a(x::Int) = x\n",
    "pad_b.jl" => "pad_b(x::Int) = x\n",
])

@testset "method grain: two methods in two files keep their own callee files" begin
    named = sink_findings(SINK_SPLIT)
    @test isempty(named)
    split = SINK_SPLIT.pkg.split
    entries = ((split, Tuple{Int}), (split, Tuple{String}))
    found = sink_findings(SINK_SPLIT; entries)
    @test length(found) == 2
    left = sink_by_callee(found, "low_a.jl")
    right = sink_by_callee(found, "low_b.jl")
    @test left.symbol == "split"
    @test right.symbol == "split"
    @test endswith(left.file, "left.jl")
    @test endswith(right.file, "right.jl")
    @test left.line == 1
    @test ev(left, :callers_in_own_file) == "0"
    @test left.kind === :file_sinkable
end

@testset "method grain: a callee file most files reach is shared vocabulary" begin
    named = sink_findings(SINK_HUB)
    @test isempty(named)
    entries = ((SINK_HUB.pkg.from_a, Tuple{Int}), (SINK_HUB.pkg.from_b, Tuple{Int}))
    found = sink_findings(SINK_HUB; entries)
    @test isempty(found)
end

@testset "method grain: a callee behind a closure in map keeps the method sinkable" begin
    named = sink_findings(SINK_PASSED)
    by_name = only(named)
    @test by_name.symbol == "wrap"
    @test ev(by_name, :callees_in) == "low.jl"
    entries = ((SINK_PASSED.pkg.wrap, Tuple{Vector{Int}}),)
    found = sink_findings(SINK_PASSED; entries)
    hit = only(found)
    @test hit.symbol == "wrap"
    @test endswith(hit.file, "wrap.jl")
    @test hit.line == 1
    @test ev(hit, :callees_in) == "low.jl"
    @test ev(hit, :callers_in_own_file) == "0"
end

@testset "method grain: a caller beside one method leaves the other method sinkable" begin
    named = sink_findings(SINK_PLACED)
    @test isempty(named)
    place = SINK_PLACED.pkg.place
    entries = ((place, Tuple{Int}), (place, Tuple{String}), (SINK_PLACED.pkg.uses, Tuple{Int}))
    found = sink_findings(SINK_PLACED; entries)
    away = only(found)
    @test away.symbol == "place"
    @test endswith(away.file, "away.jl")
    @test away.line == 1
    @test ev(away, :callees_in) == "low.jl"
    @test ev(away, :callers_in_own_file) == "0"
end
