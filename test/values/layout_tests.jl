# A package with no submodules is one module. The spine's include order ranks its files.

const FLAT_LOW = """
leaf(x) = x
climb(x) = peak(x)
"""

const FLAT_HIGH = """
peak(x) = leaf(x)
"""

const FLAT_SPINE = """
include("low.jl")
include("high.jl")
"""

const FLAT_RANK = load_package("FlatRank", FLAT_SPINE, [
    "low.jl" => FLAT_LOW,
    "high.jl" => FLAT_HIGH,
])

const FLAT_STRAY = load_package("FlatStray", FLAT_SPINE, [
    "low.jl" => FLAT_LOW,
    "high.jl" => FLAT_HIGH,
    "stray.jl" => "lost() = 1\n",
])

@testset "a package with no submodules ranks included files by the spine" begin
    ctx = case_context(FLAT_RANK)
    corpus = ArchCheck.run(Corpus(), ctx)
    @test isempty(corpus)
    back_findings = ArchCheck.run(FileBackEdges(), ctx)
    back = only(back_findings)
    file_name = basename(back.file)
    symbol_name = basename(back.symbol)
    via = ev(back, :via)
    @test (file_name, symbol_name, via) == ("low.jl", "high.jl", "climb")
end

@testset "a file the spine does not include is an unranked file" begin
    ctx = case_context(FLAT_STRAY)
    corpus = ArchCheck.run(Corpus(), ctx)
    hole = only(corpus)
    @test hole.kind === :unranked_file
    @test endswith(hole.file, "stray.jl")
end
