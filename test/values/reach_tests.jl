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

const TWIN_UUID = "b8f9d2e3-5c40-4f6b-8d7e-222222222222"

function write_twin_package(root)
    src = joinpath(root, "src")
    mkdir(src)
    project = """
    name = "TwinCase"
    uuid = "$TWIN_UUID"
    """
    write(joinpath(root, "Project.toml"), project)
    source = """
    __precompile__(false)

    module TwinCase
    struct Held
        n::Int
    end
    make(x::Int) = Held(x)
    spare(x::Int) = x + 1
    end
    """
    write(joinpath(src, "TwinCase.jl"), source)
end

function load_twin_package()
    root = mktempdir()
    write_twin_package(root)
    pushfirst!(LOAD_PATH, root)
    identity = Base.PkgId(Base.UUID(TWIN_UUID), "TwinCase")
    loaded = try
        Base.require(identity)
    finally
        popfirst!(LOAD_PATH)
    end
    loaded
end

@testset "a compiler Any constructor beside a typed one is not an unreached method" begin
    pkg = load_twin_package()
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    entry = (pkg.make, Tuple{Int})
    function twin_workload()
        pkg.make(1)
    end
    checks = (ArchCheck.UnreachedMethods(),)
    found = ArchCheck.gate(pkg; report_path = report, io = quiet, checks, workload = twin_workload,
                           entries = (entry,))
    symbols = String[]
    for finding in found
        push!(symbols, finding.symbol)
    end
    @test symbols == ["spare"]
end

const PARAM_UUID = "c9a0e3f4-6d51-407c-9e8f-333333333333"

function write_param_package(root)
    src = joinpath(root, "src")
    mkdir(src)
    project = """
    name = "ParamCase"
    uuid = "$PARAM_UUID"
    """
    write(joinpath(root, "Project.toml"), project)
    source = """
    __precompile__(false)

    module ParamCase
    struct Box{T}
        value::T
    end
    wrap(x::T) where {T} = Box{T}(x)
    make(x::Int) = wrap(x)
    spare(x::Int) = x + 1
    end
    """
    write(joinpath(src, "ParamCase.jl"), source)
end

function load_param_package()
    root = mktempdir()
    write_param_package(root)
    pushfirst!(LOAD_PATH, root)
    identity = Base.PkgId(Base.UUID(PARAM_UUID), "ParamCase")
    loaded = try
        Base.require(identity)
    finally
        popfirst!(LOAD_PATH)
    end
    loaded
end

@testset "a called parametric constructor is not an unreached method" begin
    pkg = load_param_package()
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    entry = (pkg.make, Tuple{Int})
    function param_workload()
        pkg.make(1)
    end
    checks = (ArchCheck.UnreachedMethods(),)
    found = ArchCheck.gate(pkg; report_path = report, io = quiet, checks, workload = param_workload,
                           entries = (entry,))
    symbols = String[]
    for finding in found
        push!(symbols, finding.symbol)
    end
    @test symbols == ["spare"]
end

const ENTRY_UUID = "d0b1f4a5-7e62-418d-8f90-444444444444"

function write_entry_package(root)
    src = joinpath(root, "src")
    mkdir(src)
    project = """
    name = "EntryCase"
    uuid = "$ENTRY_UUID"
    """
    write(joinpath(root, "Project.toml"), project)
    source = """
    __precompile__(false)

    module EntryCase
    export spare
    called(x::Int) = x + 1
    spare(x::Int) = x + 2
    hidden(x::Int) = x + 3
    end
    """
    write(joinpath(src, "EntryCase.jl"), source)
end

function load_entry_package()
    root = mktempdir()
    write_entry_package(root)
    pushfirst!(LOAD_PATH, root)
    identity = Base.PkgId(Base.UUID(ENTRY_UUID), "EntryCase")
    loaded = try
        Base.require(identity)
    finally
        popfirst!(LOAD_PATH)
    end
    loaded
end

function entry_symbols(pkg, check)
    report = joinpath(mktempdir(), "architecture.jsonl")
    quiet = IOBuffer()
    entry = (pkg.called, Tuple{Int})
    function entry_workload()
        pkg.called(1)
    end
    found = ArchCheck.gate(pkg; report_path = report, io = quiet, checks = (check,), workload = entry_workload,
                           entries = (entry,))
    symbols = String[]
    for finding in found
        push!(symbols, finding.symbol)
    end
    sort!(symbols)
    symbols
end

@testset "an exported uncalled method stays quiet when a public name is an entry" begin
    pkg = load_entry_package()
    open = ArchCheck.UnreachedMethods()
    closed = ArchCheck.UnreachedMethods(public_is_entry = true)
    open_symbols = entry_symbols(pkg, open)
    closed_symbols = entry_symbols(pkg, closed)
    @test open_symbols == ["hidden", "spare"]
    @test closed_symbols == ["hidden"]
end
