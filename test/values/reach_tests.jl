# A method the workload left uncompiled stays a finding. A call the method graph names accounts for one the run skipped.

const REACH_UUID = "a7e8c1d2-4b3f-4e5a-9c6d-111111111111"

function write_reach_package(root)
    src = joinpath(root, "src")
    mkdir(src)
    project = """
    name = "ReachCase"
    uuid = "$REACH_UUID"
    """
    write(joinpath(root, "Project.toml"), project)
    source = """
    __precompile__(false)

    module ReachCase
    called(x::Int) = x + 1
    uncalled(x::Int) = x + 2
    onlykw(; extra::Int = 0) = extra + 1
    edged(x::Int) = x + 3
    hidden(x::Int) = x + 4
    function route(x::Int, value)
        edged(x)
        hidden(value)
    end
    end
    """
    write(joinpath(src, "ReachCase.jl"), source)
end

function load_reach_package()
    root = mktempdir()
    write_reach_package(root)
    pushfirst!(LOAD_PATH, root)
    identity = Base.PkgId(Base.UUID(REACH_UUID), "ReachCase")
    loaded = try
        Base.require(identity)
    finally
        popfirst!(LOAD_PATH)
    end
    loaded
end

@testset "only the method nobody called and no graph name accounts for is unreached" begin
    pkg = load_reach_package()
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    entry = (pkg.route, Tuple{Int,Any})
    function reach_workload()
        pkg.called(1)
        pkg.onlykw(; extra = 4)
    end
    checks = (ArchCheck.UnreachedMethods(),)
    found = ArchCheck.gate(pkg; report_path = report, io = quiet, checks, workload = reach_workload,
                           entries = (entry,))
    hit = only(found)
    uncalled = only(methods(pkg.uncalled))
    @test hit.kind === :unreached_method
    @test hit.mod === :ReachCase
    @test hit.symbol == "uncalled"
    @test hit.line == Int(uncalled.line)
    @test ev(hit, :module) == "ReachCase"
    @test ev(hit, :signature) == string(uncalled.sig)
end
