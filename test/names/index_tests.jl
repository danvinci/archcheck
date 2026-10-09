# The index accounts for every file it walks, and ranks each file by include order.

function corpus_of(case; entry_dirs = String[])
    ctx = case_context(case; entry_dirs)
    ArchCheck.run(Corpus(), ctx)
end

function index_of(case; entry_dirs = String[])
    ctx = case_context(case; entry_dirs)
    ctx.index
end

const FORGOTTEN_FILE = load_package("ForgottenFile", """
include("known.jl")
""", [
    "known.jl" => "a() = 1\n",
    "forgotten.jl" => "b() = 2\n",
])

const MISSING_CHILD = load_package("MissingChild", """
include("mm/Mm.jl")
using .Mm
""", ["mm/Mm.jl" => "module Mm\nif false\ninclude(\"missing.jl\")\nend\nend\n"])

const MISSING_SPINE = load_package("MissingSpine", """
if false
include("missing.jl")
end
include("present.jl")
""", ["present.jl" => "a() = 1\n"])

const DYNAMIC_INCLUDE = load_package("DynamicInclude", """
if false
include(joinpath(@__DIR__, "known.jl"))
end
""", ["known.jl" => "a() = 1\n"])

const COMMENT_INCLUDE = load_package("CommentInclude", """
include("known.jl")
# include(joinpath(@__DIR__, "x.jl"))
s = "include(joinpath(x))"
""", ["known.jl" => "a() = 1\n"])

const NESTED_INCLUDE = load_package("NestedInclude", """
include("known.jl")
""", [
    "known.jl" => "include(\"deeper.jl\")\na() = 1\n",
    "deeper.jl" => "b() = 2\n",
])

const CROSS_DIRECTORY = load_package("CrossDirectory", """
include("geometry/Geometry.jl")
using .Geometry
""", [
    "geometry/Geometry.jl" => "module Geometry\ninclude(\"early.jl\")\ninclude(\"../shared.jl\")\nend\n",
    "geometry/early.jl" => "climb() = shared_helper()\n",
    "shared.jl" => "shared_helper() = 1\n",
])

const OUTSIDE_DIR = load_package("OutsideDir", """
include("geometry/Geometry.jl")
using .Geometry
""", [
    "geometry/Geometry.jl" => "module Geometry\nif false\ninclude(\"../missing.jl\")\ninclude(joinpath(@__DIR__, \"../dyn.jl\"))\ninclude(\"../bad.jl\")\nend\nend\n",
    "bad.jl" => "function wrecked(x\n",
])

const SINGLE_OWNER = load_package("SingleOwner", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\ninclude(\"../bb/shared.jl\")\nend\n",
    "bb/Bb.jl" => "module Bb\ninclude(\"local.jl\")\nend\n",
    "bb/shared.jl" => "shared_helper() = 1\n",
    "bb/local.jl" => "local_helper() = 1\n",
])

const SHARED_INCLUDE = load_package("SharedInclude", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\ninclude(\"../bb/shared.jl\")\nend\n",
    "bb/Bb.jl" => "module Bb\ninclude(\"shared.jl\")\nend\n",
    "bb/shared.jl" => "shared_helper() = 1\n",
])

const SPLIT_INCLUDE = load_package("SplitInclude", """
include("early.jl"); include("same.jl")
begin
include("inside.jl")
end
include(
"split.jl"
)
""", [
    "early.jl" => "climb() = split_helper()\n",
    "same.jl" => "same_helper() = 1\n",
    "inside.jl" => "inside_helper() = 1\n",
    "split.jl" => "split_helper() = 1\n",
])

const NAMED_ENTRY = load_package("NamedEntry", """
include("mm/Entry.jl")
using .Mm
""", [
    "mm/Entry.jl" => "module Mm\ninclude(\"known.jl\")\nend\n",
    "mm/known.jl" => "a() = 1\n",
])

const CAPITAL_HELPER = load_package("CapitalHelper", """
include("Helper.jl")
""", ["Helper.jl" => "a() = 1\n"])

const AMBIGUOUS_SPINE = load_package("AmbiguousSpine", "ready() = 1\n", [
    "Aye.jl" => "a() = 1\n",
    "Bee.jl" => "b() = 2\n",
])

const UNPARSED_FILE = load_package("UnparsedFile", """
include("good.jl")
if false
include("bad.jl")
end
""", [
    "good.jl" => "a() = 1\n",
    "bad.jl" => "function wrecked(x\n  return x\n",
])

const BROKEN_ENTRY = load_package("BrokenEntry", """
include("body.jl")
""", ["body.jl" => "shipped() = 1\n"])
const BROKEN_ENTRY_DIR = mktempdir()
write(joinpath(BROKEN_ENTRY_DIR, "run.jl"), "shipped(\n")

const UNTRACKED_LOOSE = load_package("UntrackedLoose", """
include("known.jl")
""", [
    "known.jl" => "a() = 1\n",
    "scratch.jl" => "b() = 2\n",
])
run(Cmd(`git init -q`; dir = UNTRACKED_LOOSE.src))
run(Cmd(`git add UntrackedLoose.jl known.jl`; dir = UNTRACKED_LOOSE.src))

const TRACKED_INCLUDE = load_package("TrackedInclude", """
include("known.jl")
include("shared.jl")
""", [
    "known.jl" => "a() = 1\n",
    "shared.jl" => "b() = 2\n",
])
run(Cmd(`git init -q`; dir = TRACKED_INCLUDE.src))
run(Cmd(`git add TrackedInclude.jl known.jl`; dir = TRACKED_INCLUDE.src))

const SCORE_PAIR = load_package("ScorePair", """
include("eval/score.jl")
include("viz/score.jl")
""", [
    "eval/score.jl" => "a() = 1\n",
    "viz/score.jl" => "b() = 2\n",
])

const SPINE_ORDER = load_package("SpineOrder", """
include("aa/Entry.jl")
using .Aa
include("bb/inner/Inner.jl")
using .Inner
""", [
    "aa/Entry.jl" => "module Aa\nf() = 1\nend\n",
    "bb/inner/Inner.jl" => "module Inner\ng() = 1\nend\n",
])

# Each seed plants one generated file that will not parse: loading skips its include and the parse sees it.
@testset "the index accounts for every generated file" begin
    wrecked = "function wrecked(x\n"
    for seed in 1:20
        rng = Xoshiro(seed)
        spec = random_module(rng)
        broken = rand(rng, spec.files)
        broken_include = "include(\"$broken\")"
        planted_spine = replace(spec.spine, broken_include => "if false\n$broken_include\nend")
        planted_sources = [name => (name == broken ? wrecked : source) for (name, source) in spec.sources]
        case_name = "IndexOrder$seed"
        case = load_package(case_name, planted_spine, planted_sources)
        index = index_of(case)
        on_disk = length(spec.files) + 1
        accounted = length(index.files) + length(index.unparsed)
        @test accounted == on_disk
        @test any(pair -> endswith(pair[2], broken), index.unparsed)
        corpus = corpus_of(case)
        @test any(finding -> finding.kind === :unparsed && endswith(finding.file, broken), corpus)
    end
end

@testset "a file the wrapper does not include is an unranked hole" begin
    corpus = corpus_of(FORGOTTEN_FILE)
    hole = only(corpus)
    @test hole.kind === :unranked_file
    @test endswith(hole.file, "forgotten.jl")
end

@testset "an include of a missing file is a hole on the includer" begin
    corpus = corpus_of(MISSING_CHILD)
    hole = only(finding for finding in corpus if finding.kind === :missing_include)
    @test hole.symbol == "missing.jl"
    @test hole.line == 3
    @test endswith(hole.file, "Mm.jl")
    @test hole.mod === :Mm
end

@testset "a missing include on the package spine is a hole" begin
    corpus = corpus_of(MISSING_SPINE)
    hole = only(finding for finding in corpus if finding.kind === :missing_include)
    @test hole.mod === :MissingSpine
    @test hole.symbol == "missing.jl"
end

@testset "an include whose argument is not a string is a hole and a comment is not" begin
    dynamic = corpus_of(DYNAMIC_INCLUDE)
    hole = only(finding for finding in dynamic if finding.kind === :nonliteral_include)
    @test hole.line == 3
    @test endswith(hole.file, "DynamicInclude.jl")
    comment = corpus_of(COMMENT_INCLUDE)
    @test !any(finding -> finding.kind === :nonliteral_include, comment)
end

@testset "a nested include takes its place in the depth-first load order" begin
    index = index_of(NESTED_INCLUDE)
    known = only(file for file in index.files if file.name == "known.jl")
    deeper = only(file for file in index.files if file.name == "deeper.jl")
    @test known.filerank == 1
    @test deeper.filerank == 2
    @test isempty(corpus_of(NESTED_INCLUDE))
end

@testset "a call to a later file outside the module directory is a file back edge" begin
    ctx = case_context(CROSS_DIRECTORY)
    found = ArchCheck.run(FileBackEdges(), ctx)
    back = only(found)
    @test back.kind === :file_backedge
    @test endswith(back.file, "early.jl")
    @test endswith(back.symbol, "shared.jl")
    @test ev(back, :via) == "climb"
    @test ev(back, :include_order) == "1->2"
end

@testset "missing, dynamic, and unparsed includes outside the module directory still report" begin
    corpus = corpus_of(OUTSIDE_DIR)
    @test any(finding -> finding.kind === :missing_include && finding.symbol == "../missing.jl", corpus)
    @test any(finding -> finding.kind === :nonliteral_include && endswith(finding.file, "Geometry.jl"), corpus)
    @test any(finding -> finding.kind === :unparsed && endswith(finding.file, "bad.jl"), corpus)
end

@testset "a cross-directory include belongs to the module that executes it" begin
    index = index_of(SINGLE_OWNER)
    shared = [file for file in index.files if file.name == "shared.jl"]
    owners = Set(file.mod for file in shared)
    @test owners == Set([:Aa])
    @test any(file -> file.name == "local.jl" && file.mod === :Bb, index.files)
end

@testset "one source included by two modules keeps both modules" begin
    index = index_of(SHARED_INCLUDE)
    shared = [file for file in index.files if file.name == "shared.jl"]
    owners = Set(file.mod for file in shared)
    @test owners == Set([:Aa, :Bb])
end

@testset "same-line, begin, and split includes still place the named source" begin
    @test isempty(corpus_of(SPLIT_INCLUDE))
    ctx = case_context(SPLIT_INCLUDE)
    found = ArchCheck.run(FileBackEdges(), ctx)
    back = only(found)
    @test endswith(back.file, "early.jl")
    @test endswith(back.symbol, "split.jl")
end

@testset "the wrapper is the entry file the directory leaves unincluded" begin
    @test isempty(corpus_of(NAMED_ENTRY))
    @test isempty(corpus_of(CAPITAL_HELPER))
    corpus = corpus_of(AMBIGUOUS_SPINE)
    kinds = Set(finding.kind for finding in corpus)
    @test kinds == Set([:unranked_file])
    holes = Set(basename(finding.file) for finding in corpus)
    @test holes == Set(["Aye.jl", "Bee.jl"])
end

@testset "a source file that will not parse is recorded and its definitions are absent" begin
    corpus = corpus_of(UNPARSED_FILE)
    hole = only(corpus)
    @test hole.kind === :unparsed
    @test endswith(hole.file, "bad.jl")
end

@testset "a broken entry script is unparsed and the name it alone used is dead" begin
    corpus = corpus_of(BROKEN_ENTRY; entry_dirs = [BROKEN_ENTRY_DIR])
    hole = only(corpus)
    @test hole.kind === :unparsed
    @test hole.mod === :Entry
    ctx = case_context(BROKEN_ENTRY; entry_dirs = [BROKEN_ENTRY_DIR])
    dead = ArchCheck.run(DeadCode(), ctx)
    dead_names = Set(finding.symbol for finding in dead)
    @test "shipped" in dead_names
end

@testset "git keeps an included untracked file and drops an untracked loose file" begin
    @test isempty(corpus_of(UNTRACKED_LOOSE))
    loose = index_of(UNTRACKED_LOOSE)
    @test !any(file -> file.name == "scratch.jl", loose.files)
    included = index_of(TRACKED_INCLUDE)
    @test any(file -> file.name == "shared.jl" && file.mod === :TrackedInclude && file.filerank == 2, included.files)
    @test isempty(corpus_of(TRACKED_INCLUDE))
end

@testset "two files with one basename keep distinct ranks" begin
    index = index_of(SCORE_PAIR)
    scored = [file for file in index.files if file.name == "score.jl"]
    ranks = Set(file.filerank for file in scored)
    @test length(scored) == 2
    @test ranks == Set([1, 2])
    @test isempty(corpus_of(SCORE_PAIR))
end

@testset "the module name comes from the using that follows the include" begin
    index = index_of(SPINE_ORDER)
    @test index.dir2mod["aa"] === :Aa
    @test index.dir2mod["bb/inner"] === :Inner
    @test index.rank[:Aa] == [1]
    @test index.rank[:Inner] == [2]
end
