# The names a module declares, and the names a caller is allowed to reach.

const BLANKET_NAMES = load_package("BlanketNames", """
include("body.jl")
for n in names(@__MODULE__; all = true)
    @eval export \$n
end
""", ["body.jl" => "kept() = 1\n"])

const COMMENT_EXPORT = load_package("CommentExport", """
include("body.jl")
# names(@__MODULE__; all = true)
""", ["body.jl" => "kept() = 1\n"])

const MISSING_EXPORT = load_package("MissingExport", """
export present, vanished
present() = 1
hidden() = 2
""")

const DEFINED_EXPORT = load_package("DefinedExport", """
export present
present() = 1
""")

const REACHED = load_package("InternalNames", """
export shown
public named
shown() = 1
named() = 2
hidden() = 3
other() = 4
value = 4
struct Secret end
""")

const PACKAGE_PATH = load_package("PackagePath", """
include("aa/Aa.jl")
using .Aa
include("bb/Bb.jl")
using .Bb
""", [
    "aa/Aa.jl" => "module Aa\nf() = 1\nend\n",
    "bb/Bb.jl" => """
    module Bb
    import ..PackagePath
    x() = PackagePath.Aa.f()
    end
    """,
])

function reached_from(script; repeat_dir = false)
    scripts = mktempdir()
    write(joinpath(scripts, "use.jl"), script)
    absent = joinpath(scripts, "absent")
    entry_dirs = repeat_dir ? [scripts, scripts] : [absent, scripts]
    ctx = case_context(REACHED; entry_dirs)
    found = ArchCheck.run(ReachesInternal(), ctx)
    rows = Tuple{String,Int}[]
    for finding in found
        push!(rows, (finding.symbol, finding.line))
    end
    sort!(rows)
end

@testset "a wrapper that exports every name declares no interface" begin
    ctx = case_context(BLANKET_NAMES)
    found = ArchCheck.run(BlanketExports(), ctx)
    @test only(found).kind === :blanket_export
end

@testset "a comment that quotes a blanket export is not one" begin
    ctx = case_context(COMMENT_EXPORT)
    found = ArchCheck.run(BlanketExports(), ctx)
    @test isempty(found)
end

@testset "an exported name with no definition is stale" begin
    stale_ctx = case_context(MISSING_EXPORT)
    stale = ArchCheck.run(StaleExports(), stale_ctx)
    @test only(stale).symbol == "vanished"
    @test only(stale).kind === :stale_export
    fresh_ctx = case_context(DEFINED_EXPORT)
    fresh = ArchCheck.run(StaleExports(), fresh_ctx)
    @test isempty(fresh)
end

@testset "an entry script's qualified reference to an internal name reaches it" begin
    script = """
        const G = InternalNames
        G.hidden()
        G.named()
        InternalNames.hidden()
        InternalNames.named()
        InternalNames.shown()
        InternalNames.hidden(InternalNames.shown())
        function wrap()
            G = 1
            G.hidden()
        end
        q = :(InternalNames.hidden())
        obj = (InternalNames = (hidden = 1,),)
        obj.InternalNames.hidden
        # InternalNames.hidden()
        s = "InternalNames.hidden()"
        """
    @test reached_from(script) == [("InternalNames.hidden", 2), ("InternalNames.hidden", 4), ("InternalNames.hidden", 7)]
end

@testset "a type position, an assignment, or an extension reaches an internal name once per directory" begin
    script = """
        const G = InternalNames
        typed(x::G.Secret)::G.Secret = x
        bounded(x::T) where {T<:G.Secret} = x
        G.value = 4
        G.hidden(x) = x
        lambda = (x::G.Secret) -> x
        """
    expected = [
        ("InternalNames.Secret", 2), ("InternalNames.Secret", 2), ("InternalNames.Secret", 3), ("InternalNames.Secret", 6),
        ("InternalNames.hidden", 5), ("InternalNames.value", 4),
    ]
    @test reached_from(script; repeat_dir = true) == expected
end

@testset "an entry script importing a name its module keeps internal reaches it" begin
    script = """
        using InternalNames: shown, hidden
        import InternalNames: named, other
        import InternalNames.hidden
        using InternalNames
        """
    @test reached_from(script) == [("InternalNames.hidden", 1), ("InternalNames.hidden", 3), ("InternalNames.other", 2)]
end

@testset "a reference reaches only what the module it names declares" begin
    ctx = Context(Nested)
    found = ArchCheck.run(DeclaredNames(), ctx)
    undeclared = Tuple{String,String,String}[]
    for finding in found
        via = ev(finding, :via)
        push!(undeclared, (string(finding.mod), finding.symbol, via))
    end
    @test Set(undeclared) == Set([
        ("Geo", "Geo.Curves.calls_later", "import"),
        ("Geo.Curves", "Low._lowpriv", "import"),
        ("Geo.Cuts", "Geo.Curves._secret", "using"),
        ("Geo.Curves", "Geo.Cuts.cut_only", "qualified"),
        ("Hi", "Geo.Curves._secret", "qualified"),
        ("Hi", "Geo.Cuts.Ring", "qualified"),
        ("Hi", "Low._lowpriv", "extends"),
        ("Hi", "Geo.gauge", "extends"),
    ])
    private = ArchCheck.run(PrivateImports(), ctx)
    @test !isempty(private)
    @test all(item -> any(finding -> finding.file == item.file && finding.line == item.line, found), private)
end

@testset "a module extends only another module's documented public verb" begin
    ctx = Context(Nested)
    found = ArchCheck.run(DeclaredExtensions(), ctx)
    extended = Tuple{String,String,String,String}[]
    for finding in found
        is_public = ev(finding, :public)
        documented = ev(finding, :documented)
        push!(extended, (string(finding.mod), finding.symbol, is_public, documented))
    end
    @test Set(extended) == Set([
        ("Hi", "Low._lowpriv", "false", "false"),
        ("Hi", "Geo.Curves.perimeter", "true", "false"),
        ("Hi", "Nested.root_measure", "false", "false"),
        ("Nested", "Low.lowf", "true", "false"),
    ])
    private = only(finding for finding in found if finding.symbol == "Low._lowpriv")
    @test ev(private, :owner) == "Low"
    @test ev(private, :function) == "_lowpriv"
    @test private.file == joinpath("src", "hi", "Hi.jl")
    declared = ArchCheck.kinds(DeclaredExtensions())
    @test (:private_extension => :error) in declared

    undeclared = ArchCheck.run(DeclaredNames(), ctx)
    relayed = only(finding for finding in undeclared if finding.symbol == "Geo.gauge")
    @test string(relayed.mod) == "Hi"
    @test ev(relayed, :via) == "extends"
    @test ev(relayed, :owner) == "Low"
    reached = ArchCheck.run(ReachesInternal(), ctx)
    secret = only(finding for finding in reached if finding.symbol == "Geo.gauge")
    @test secret.file == joinpath("src", "hi", "Hi.jl")

    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (DeclaredExtensions(),)
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    records = [JSON.parse(line) for line in eachline(report)]
    severities = [record["severity"] for record in records if record["kind"] == "private_extension"]
    @test all(severity -> severity == "error", severities)
end

@testset "a module reaches only the modules its wrapper names" begin
    ctx = Context(Nested)
    found = ArchCheck.run(DeclaredModules(), ctx)
    reached = Tuple{String,String,String}[]
    for finding in found
        via = ev(finding, :via)
        push!(reached, (string(finding.mod), finding.symbol, via))
    end
    @test Set(reached) == Set([
        ("Geo.Curves", "Geo.Cuts", "qualified"),
        ("Hi", "Geo.Curves", "qualified"),
        ("Hi", "Geo.Curves", "extends"),
        ("Hi", "Geo.Cuts", "qualified"),
    ])

    path_ctx = case_context(PACKAGE_PATH)
    path_found = ArchCheck.run(DeclaredModules(), path_ctx)
    symbols = Set(finding.symbol for finding in path_found)
    @test "Aa" in symbols
    @test !("PackagePath" in symbols)
end
