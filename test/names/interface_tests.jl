# The names a module declares, and the names a caller is allowed to reach.
# `vanished` outlived its definition; `hidden` is defined but kept off the interface
module FIface
    export present, vanished
    present() = 1
    hidden() = 2
end
# shown is exported, offered is public-unexported, hidden is private
module FPub
    export shown
    public offered
    shown() = 1
    offered() = 2
    hidden() = 3
    value = 4
    struct Secret end
end

@testset "interface" begin
    # blanket export: the wrapper republishes its whole namespace, so it declares no interface
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\nfor n in names(@__MODULE__; all=true)\n    @eval export \$n\nend")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        found = check_blanket_exports(index)
        @test length(found) == 1
        @test found[1].kind === :blanket_export
    end

    # a comment that quotes the blanket form is not a call
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\n# names(@__MODULE__; all=true)\n")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        @test isempty(check_blanket_exports(index))
    end

    # stale export: Julia accepts a name with no definition behind it
    stale = check_stale_exports([FIface])
    @test length(stale) == 1
    @test stale[1].symbol == "vanished"
    @test stale[1].kind === :stale_export
    @test isempty(check_stale_exports([FDupA]))

    # reaches-internal: a qualified reference to a name the owner kept private
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        entry = mktempdir()
        write(joinpath(entry, "probe.jl"), "a = FIface.hidden()\nb = FIface.present()\n")
        found = check_reaches_internal(index, [FIface]; entry_dirs = [entry])
        @test length(found) == 1
        @test found[1].symbol == "FIface.hidden"
        @test found[1].kind === :reaches_internal

        # a missing entry dir contributes nothing, as the index treats it
        absent = joinpath(dir, "absent")
        found = check_reaches_internal(index, [FIface]; entry_dirs = [absent, entry])
        @test [f.symbol for f in found] == ["FIface.hidden"]
    end

    # comments and strings are not references
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        entry = mktempdir()
        write(joinpath(entry, "probe.jl"),
              "# FIface.hidden()\ns = \"FIface.hidden()\"\nx = 1  # FIface.hidden\n")
        @test isempty(check_reaches_internal(index, [FIface]; entry_dirs = [entry]))
    end

    # public-unexported names are the declared interface; aliases and quotes follow the same rule
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        entry = mktempdir()
        probe = joinpath(entry, "probe.jl")
        write(probe,
              "const G = Main.FPub\nG.hidden()\nG.offered()\nFPub.hidden()\nFPub.offered()\nFPub.shown()\nMain.FPub.hidden()\nfunction wrap()\n    G = 1\n    G.hidden()\nend\nq = :(FPub.hidden())\nobj = (FPub = (hidden = 1,),)\nobj.FPub.hidden\n")
        found = check_reaches_internal(index, [FPub]; entry_dirs = [entry])
        @test Set(f.symbol for f in found) == Set(["FPub.hidden"])
        @test length(found) == 3
        write(probe, """
            const G = Main.FPub
            typed(x::G.Secret)::G.Secret = x
            bounded(x::T) where {T<:G.Secret} = x
            G.value = 4
            G.hidden(x) = x
            lambda = (x::G.Secret) -> x
            """)
        found = check_reaches_internal(index, [FPub]; entry_dirs = [entry, entry])
        @test sort([f.symbol for f in found]) ==
              [fill("FPub.Secret", 4); "FPub.hidden"; "FPub.value"]
    end
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
    refs = scan_modrefs(source, :Bb, "x.jl", Set([:Aa, :Bb]); root = :Pkg)
    @test Set((r.to, r.via) for r in refs) == Set([(:Aa, :qualified), (:Pkg, :import)])
end
