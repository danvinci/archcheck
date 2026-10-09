# The package spine is the root module's file: its methods are indexed, and an outside using resolves.

function write_spine_package(dir; import_child::Bool)
    src = joinpath(dir, "src")
    child_dir = joinpath(src, "child")
    mkpath(child_dir)
    import_line = import_child ? "import SpinePkg.Child\n" : ""
    spine = """
    module SpinePkg
    using ArchCheck
    include("child/Child.jl")
    using .Child
    $(import_line)spine_only(x) = x + 1
    end
    """
    write(joinpath(src, "SpinePkg.jl"), spine)
    child = """
    module Child
    child_only(x) = x
    end
    """
    write(joinpath(child_dir, "Child.jl"), child)
    src
end

function spine_index(src)
    spine = joinpath(src, "SpinePkg.jl")
    layout = ArchCheck.package_layout(spine, :SpinePkg)
    rank = layout[1]
    dir2mod = layout[2]
    build_source_index(src, rank, dir2mod; root = :SpinePkg)
end

function loaded_spine(src)
    parent = Module(:SpinePkg)
    # The parent's own name hides a child module of the same name, so the loaded module is what `include` returns.
    Base.include(parent, joinpath(src, "SpinePkg.jl"))
end

function probe_loaded_spine(pkg, index)
    child = getfield(pkg, :Child)
    spine_only = getfield(pkg, :spine_only)
    ctx = Context(index, pkg, [child])
    probes = Probes(functions = (spine_only,), slow_s = 0.0)
    armed = ArchCheck.arm!(probes, ctx)
    local traced
    try
        got = Base.invokelatest(spine_only, 2)
        @test got == 3
    finally
        traced = ArchCheck.disarm!(armed)
    end
    names = [record.name for record in traced.records]
    @test names == [:spine_only]
end

@testset "a method in the spine is indexed and probed" begin
    mktempdir() do dir
        src = write_spine_package(dir; import_child = false)
        index = spine_index(src)
        spine_file = only(f for f in index.files if f.name == "SpinePkg.jl")
        @test spine_file.mod === :SpinePkg
        for module_rank in values(index.rank)
            ordered_before = ArchCheck.completes_before(spine_file.modrank, module_rank)
            @test ordered_before
        end
        dead = check_dead_code_static(index)
        planted = filter(f -> f.symbol == "spine_only", dead)
        finding = only(planted)
        @test finding.kind === :dead_code
        @test finding.mod === :SpinePkg
        @test endswith(finding.file, joinpath("src", "SpinePkg.jl"))
        corpus = check_corpus(index)
        hole = any(f -> f.kind === :unranked_file && endswith(f.file, "SpinePkg.jl"), corpus)
        @test !hole

        pkg = loaded_spine(src)
        # Names defined while loading are visible in the latest world.
        Base.invokelatest(probe_loaded_spine, pkg, index)
    end
end

@testset "a spine using an outside package and importing its child by the package name indexes" begin
    mktempdir() do dir
        src = write_spine_package(dir; import_child = true)
        index = spine_index(src)
        outside_ref = any(r -> r.to === :ArchCheck, index.refs)
        @test !outside_ref
        imported = filter(r -> r.via === :import && r.to === :Child, index.refs)
        @test length(imported) == 1
        dead = check_dead_code_static(index)
        @test any(f -> f.symbol == "spine_only" && f.mod === :SpinePkg, dead)
    end
end
