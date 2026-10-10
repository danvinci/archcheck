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
include("cc/Cc.jl")
using .Cc
""", [
    "aa/Aa.jl" => """
    module Aa
    export @shown_macro
    f() = 1
    g() = 2
    macro shown_macro() end
    macro hidden_macro() end
    module Util
    aa_only() = 1
    end
    reads_own() = Util.aa_only()
    end
    """,
    "bb/Bb.jl" => """
    module Bb
    import ..PackagePath
    x() = PackagePath.Aa.f()
    module Util
    bb_only() = 2
    end
    reads_own() = Util.bb_only()
    end
    """,
    "cc/Cc.jl" => """
    module Cc
    import ..PackagePath as P
    import ..Aa as A
    using ..Aa: @shown_macro, @hidden_macro
    include("use.jl")
    end
    """,
    "cc/use.jl" => """
    through_root() = P.Aa.g()
    through_module() = A.g()
    binds_no_util() = Util.bb_only()
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

@testset "an entry script's qualified reference to an internal name reaches it, in quoted code too" begin
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
        import InternalNames as Renamed
        Renamed.hidden()
        Renamed.named()
        """
    expected = [
        ("InternalNames.hidden", 2), ("InternalNames.hidden", 4), ("InternalNames.hidden", 7),
        ("InternalNames.hidden", 12), ("InternalNames.hidden", 18),
    ]
    @test reached_from(script) == expected
end

@testset "a type position, a macro-wrapped argument, an assignment, or an extension reaches an internal name once per line" begin
    script = """
        const G = InternalNames
        typed(x::G.Secret)::G.Secret = x
        bounded(x::T) where {T<:G.Secret} = x
        G.value = 4
        G.hidden(x) = x
        lambda = (x::G.Secret) -> x
        wrapped(@nospecialize(x::G.Secret)) = x
        """
    expected = [
        ("InternalNames.Secret", 2), ("InternalNames.Secret", 3), ("InternalNames.Secret", 6),
        ("InternalNames.Secret", 7), ("InternalNames.hidden", 5), ("InternalNames.value", 4),
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

@testset "a source reference reaches only what the module it is written through declares" begin
    ctx = Context(Nested)
    found = ArchCheck.run(ReachesInternal(), ctx)
    reached = Tuple{String,String,String,String}[]
    for finding in found
        via = ev(finding, :via)
        owner = ev(finding, :owner)
        push!(reached, (string(finding.mod), finding.symbol, via, owner))
    end
    @test Set(reached) == Set([
        ("Geo", "Geo.Curves.calls_later", "import", "Geo.Curves"),
        ("Geo.Curves", "Low._lowpriv", "import", "Low"),
        ("Geo.Cuts", "Geo.Curves._secret", "using", "Geo.Curves"),
        ("Hi", "Geo.Curves", "qualified", "Geo"),
        ("Hi", "Geo.Curves._secret", "qualified", "Geo.Curves"),
        ("Hi", "Geo.Cuts", "qualified", "Geo"),
        ("Hi", "Geo.Cuts.Ring", "qualified", "Geo.Cuts"),
        ("Hi", "Low._lowpriv", "qualified", "Low"),
        ("Hi", "Geo.gauge", "qualified", "Low"),
    ])
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

@testset "a path through an import alias reaches the module the alias names, and an import list keeps its macros" begin
    ctx = case_context(PACKAGE_PATH)
    use_path = joinpath("src", "cc", "use.jl")
    wrapper_path = joinpath("src", "cc", "Cc.jl")
    reached = ArchCheck.run(ReachesInternal(), ctx)
    reached_rows = Set((finding.symbol, ev(finding, :via), finding.file, finding.line)
                       for finding in reached if finding.mod === :Cc)
    @test reached_rows == Set([
        ("PackagePath.Aa", "qualified", use_path, 1),
        ("Aa.g", "qualified", use_path, 1),
        ("Aa.g", "qualified", use_path, 2),
        ("Aa.@hidden_macro", "using", wrapper_path, 4),
    ])
end

@testset "a qualifier resolves from the module its code sits in, so two modules of one name stay apart" begin
    scripts = mktempdir()
    script = """
        using PackagePath.Aa: Util
        Util.aa_only()
        Bb.x()
        """
    write(joinpath(scripts, "use.jl"), script)
    ctx = case_context(PACKAGE_PATH; entry_dirs = [scripts])
    found = ArchCheck.run(ReachesInternal(), ctx)
    rows = Set((finding.mod, finding.symbol, finding.line)
               for finding in found if finding.mod === :Entry || occursin("Util", finding.symbol))
    @test rows == Set([
        (:Aa, "Aa.Util.aa_only", 10),
        (:Bb, "Bb.Util.bb_only", 7),
        (:Entry, "Aa.Util", 1),
        (:Entry, "Aa.Util.aa_only", 2),
    ])
end
