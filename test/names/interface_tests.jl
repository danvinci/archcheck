# The names a module declares, and the names a caller is allowed to reach.
# `vanished` outlived its definition; `hidden` is defined but kept off the interface
module FIface
    export present, vanished
    present() = 1
    hidden() = 2
end

@testset "interface" begin
    # blanket export: the wrapper republishes its whole namespace, so it declares no interface
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\nfor n in names(@__MODULE__; all=true)\n    @eval export \$n\nend")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = ArchCheck.build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        found = ArchCheck.check_blanket_exports(index)
        @test length(found) == 1
        @test found[1].kind === :blanket_export
    end

    # a comment that quotes the blanket form is not a call
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\n# names(@__MODULE__; all=true)\n")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = ArchCheck.build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        @test isempty(ArchCheck.check_blanket_exports(index))
    end

    # stale export: Julia accepts a name with no definition behind it
    stale = ArchCheck.check_stale_exports([FIface])
    @test length(stale) == 1
    @test stale[1].symbol == "vanished"
    @test stale[1].kind === :stale_export
    @test isempty(ArchCheck.check_stale_exports([FDupA]))
end

# shown is exported, named is public-unexported, the rest are internal
const REACHED = load_package("Reached", """
    export shown
    public named
    shown() = 1
    named() = 2
    hidden() = 3
    other() = 4
    value = 4
    struct Secret end
    """)

# The internal names an entry script reaches, as (symbol, line), with the script written to its own directory.
function reached_from(script; repeat_dir = false)
    scripts = mktempdir()
    write(joinpath(scripts, "use.jl"), script)
    absent = joinpath(scripts, "absent")
    entry_dirs = repeat_dir ? [scripts, scripts] : [absent, scripts]
    ctx = case_context(REACHED; entry_dirs)
    found = ArchCheck.run(ReachesInternal(), ctx)
    sort([(f.symbol, f.line) for f in found])
end

@testset "an entry script's qualified reference to an internal name reaches it" begin
    script = """
        const G = Main.Reached
        G.hidden()
        G.named()
        Reached.hidden()
        Reached.named()
        Reached.shown()
        Main.Reached.hidden()
        function wrap()
            G = 1
            G.hidden()
        end
        q = :(Reached.hidden())
        obj = (Reached = (hidden = 1,),)
        obj.Reached.hidden
        # Reached.hidden()
        s = "Reached.hidden()"
        """
    @test reached_from(script) == [("Reached.hidden", 2), ("Reached.hidden", 4), ("Reached.hidden", 7)]
end

@testset "a type position, an assignment, or an extension reaches an internal name once per directory" begin
    script = """
        const G = Main.Reached
        typed(x::G.Secret)::G.Secret = x
        bounded(x::T) where {T<:G.Secret} = x
        G.value = 4
        G.hidden(x) = x
        lambda = (x::G.Secret) -> x
        """
    expected = [
        ("Reached.Secret", 2), ("Reached.Secret", 2), ("Reached.Secret", 3), ("Reached.Secret", 6),
        ("Reached.hidden", 5), ("Reached.value", 4),
    ]
    @test reached_from(script; repeat_dir = true) == expected
end

@testset "an entry script importing a name its module keeps internal reaches it" begin
    script = """
        using Reached: shown, hidden
        import Reached: named, other
        import Reached.hidden
        using Reached
        """
    @test reached_from(script) == [("Reached.hidden", 1), ("Reached.hidden", 3), ("Reached.other", 2)]
end

@testset "declared names: a reference reaches only what the module it names declares" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredNames(), ArchCheck.PrivateImports())
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    undeclared = filter(f -> f.kind === :undeclared_name, findings)
    # a name reached through Geo, which declares it for its callers, is declared along the written path;
    # Geo's own import of it from Curves, which keeps it private, is not
    @test Set((string(f.mod), f.symbol, ev(f, :via)) for f in undeclared) == Set([
        ("Geo", "Geo.Curves.calls_later", "import"),
        ("Geo.Curves", "Low._lowpriv", "import"),
        ("Geo.Cuts", "Geo.Curves._secret", "using"),
        ("Geo.Curves", "Geo.Cuts.cut_only", "qualified"),
        ("Hi", "Geo.Curves._secret", "qualified"),
        ("Hi", "Geo.Cuts.Ring", "qualified"),
        ("Hi", "Low._lowpriv", "extends"),
        ("Hi", "Geo.gauge", "extends"),
    ])
    # an underscore import is one case of an undeclared name
    private = filter(f -> f.kind === :private_import, findings)
    @test all(p -> any(u -> u.file == p.file && u.line == p.line, undeclared), private)
end

@testset "declared extensions: a module extends only another module's documented public verb" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredExtensions(), ArchCheck.DeclaredNames(), ArchCheck.ReachesInternal())
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    records = [JSON.parse(line) for line in eachline(report)]
    extensions = filter(r -> r["kind"] == "private_extension", records)
    @test all(r -> r["severity"] == "error", extensions)
    # private, public but undocumented, and the root's private function; Low's documented `gauge` is clean
    extended = Set((r["module"], r["symbol"], r["evidence"]["public"], r["evidence"]["documented"])
                   for r in extensions)
    @test extended == Set([
        ("Hi", "Low._lowpriv", "false", "false"),
        ("Hi", "Geo.Curves.perimeter", "true", "false"),
        ("Hi", "Nested.root_measure", "false", "false"),
        ("Nested", "Low.lowf", "true", "false"),
    ])
    private = only(r for r in extensions if r["symbol"] == "Low._lowpriv")
    @test private["evidence"]["owner"] == "Low" && private["evidence"]["function"] == "_lowpriv"
    @test private["file"] == joinpath("src", "hi", "Hi.jl")

    # extending through Geo, which only passes Low's verb on, uses a name Geo does not declare
    relayed(kind) = only(r for r in records if r["kind"] == kind && r["symbol"] == "Geo.gauge")
    undeclared = relayed("undeclared_name")
    @test undeclared["module"] == "Hi" && undeclared["evidence"]["via"] == "extends"
    @test undeclared["evidence"]["owner"] == "Low"
    @test relayed("reaches_internal")["file"] == joinpath("src", "hi", "Hi.jl")
end

@testset "declared modules: a module reaches only the modules its wrapper names" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredModules(),)
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    reached = Set((string(f.mod), f.symbol, ev(f, :via)) for f in findings)
    @test reached == Set([
        ("Geo.Curves", "Geo.Cuts", "qualified"),
        ("Hi", "Geo.Curves", "qualified"),
        ("Hi", "Geo.Curves", "extends"),
        ("Hi", "Geo.Cuts", "qualified"),
    ])

    # a path opening with the package's own name reaches the module below it
    source = "x = Pkg.Aa.f()\nimport ..Pkg\n"
    refs = ArchCheck.scan_modrefs(source, :Bb, "x.jl", Set([:Aa, :Bb]); root = :Pkg)
    @test Set((r.to, r.via) for r in refs) == Set([(:Aa, :qualified), (:Pkg, :import)])
end
