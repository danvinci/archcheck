# Caller whitelist, sentinel returns, and string payloads, over synthetic trees.

const PROJECT_CHECKS = joinpath(@__DIR__, "..", "..", "src", "checks_project.jl")
if !isdefined(ArchCheck, :CallerWhitelist)
    Base.include(ArchCheck, PROJECT_CHECKS)
end

module ProjectSentinels
    export ends_nothing, returns_missing, nested_closure, documented, ends_value
    public ends_inf
    public ends_nan
    ends_nothing() = 0
    returns_missing() = 0
    ends_inf() = 0
    ends_nan() = 0
    nested_closure() = 0
    documented() = 0
    hidden() = 0
    ends_value() = 0
end

function project_context(files, rank, dir2mod, mods)
    root = mktempdir()
    src = joinpath(root, "src")
    for (rel, text) in files
        path = joinpath(src, rel)
        mkpath(dirname(path))
        write(path, text)
    end
    index = build_source_index(src, rank, dir2mod)
    ArchCheck.Context(index, Main, mods)
end

function finding_rows(found, evidence_key)
    rows = []
    for finding in found
        evidence = ev(finding, evidence_key)
        row = (finding.symbol, finding.file, finding.kind, evidence)
        push!(rows, row)
    end
    sort!(rows)
end

@testset "an unlisted definition that calls a guarded name is an error" begin
    files = [
        "calls/Calls.jl" => "include(\"readers.jl\")\ninclude(\"outside.jl\")\ninclude(\"owner/root.jl\")\n",
        "calls/readers.jl" => """
            function allowed_reader(x)
                root_find(x)
            end
            function both(x)
                other_find(x)
                root_find(x)
            end
            """,
        "calls/outside.jl" => """
            function outsider(x)
                root_find(x)
            end
            function qualified(x)
                M.root_find(x)
            end
            function shadowed(root_find)
                root_find(1)
            end
            function clean(x)
                helper(x)
            end
            function helper(x)
                x
            end
            """,
        "calls/owner/root.jl" => """
            function root_find(x)
                x
            end
            function uses_own(x)
                root_find(x)
            end
            """,
    ]
    rank = Dict(:Calls => 1)
    dir2mod = Dict("calls" => :Calls)
    ctx = project_context(files, rank, dir2mod, Module[])
    allowed = (("src/calls/readers.jl", :allowed_reader),)
    callees = (:root_find, :other_find)
    exempt = ("src/calls/owner",)
    check = ArchCheck.CallerWhitelist(callees, allowed, exempt)
    @test ArchCheck.kinds(check) == (:unlisted_caller => :error,)
    found = ArchCheck.run(check, ctx)
    rows = finding_rows(found, :calls)
    expected = [
        ("both", "src/calls/readers.jl", :unlisted_caller, "other_find root_find"),
        ("outsider", "src/calls/outside.jl", :unlisted_caller, "root_find"),
        ("qualified", "src/calls/outside.jl", :unlisted_caller, "root_find"),
    ]
    @test rows == expected
end

@testset "a public function in the configured directory that returns a sentinel is reported" begin
    files = [
        "gate/Gate.jl" => "include(\"checked/bodies.jl\")\ninclude(\"other.jl\")\n",
        "gate/checked/bodies.jl" => """
            ends_nothing() = nothing
            function returns_missing(x)
                if x
                    return missing
                end
                1
            end
            ends_inf() = -Inf
            hidden() = nothing
            function nested_closure()
                cb = () -> nothing
                1
            end
            ends_value() = 1
            \"\"\"reads a gap\"\"\"
            function documented()
                NaN
            end
            ends_nan() = NaN
            """,
        "gate/other.jl" => "function ends_nothing()\n    nothing\nend\n",
    ]
    rank = Dict(:ProjectSentinels => 1)
    dir2mod = Dict("gate" => :ProjectSentinels)
    ctx = project_context(files, rank, dir2mod, [ProjectSentinels])
    check = ArchCheck.SentinelReturns(("src/gate/checked",))
    @test ArchCheck.kinds(check) == (:sentinel_return => :advisory,)
    found = ArchCheck.run(check, ctx)
    rows = finding_rows(found, :sentinel)
    expected = [
        ("documented", "src/gate/checked/bodies.jl", :sentinel_return, "NaN"),
        ("ends_inf", "src/gate/checked/bodies.jl", :sentinel_return, "-Inf"),
        ("ends_nan", "src/gate/checked/bodies.jl", :sentinel_return, "NaN"),
        ("ends_nothing", "src/gate/checked/bodies.jl", :sentinel_return, "nothing"),
        ("returns_missing", "src/gate/checked/bodies.jl", :sentinel_return, "missing"),
    ]
    @test rows == expected
end

@testset "a sentinel set that omits nothing leaves a typed absence quiet" begin
    files = [
        "gate/Gate.jl" => "include(\"checked/bodies.jl\")\n",
        "gate/checked/bodies.jl" => """
            ends_nothing() = nothing
            ends_inf() = -Inf
            ends_nan() = NaN
            returns_missing() = missing
            hidden() = nothing
            ends_value() = 1
            """,
    ]
    rank = Dict(:ProjectSentinels => 1)
    dir2mod = Dict("gate" => :ProjectSentinels)
    ctx = project_context(files, rank, dir2mod, [ProjectSentinels])
    sentinels = (:Inf, :NaN, :missing)
    check = ArchCheck.SentinelReturns(("src/gate/checked",), sentinels)
    found = ArchCheck.run(check, ctx)
    rows = finding_rows(found, :sentinel)
    expected = [
        ("ends_inf", "src/gate/checked/bodies.jl", :sentinel_return, "-Inf"),
        ("ends_nan", "src/gate/checked/bodies.jl", :sentinel_return, "NaN"),
        ("returns_missing", "src/gate/checked/bodies.jl", :sentinel_return, "missing"),
    ]
    @test rows == expected
end

@testset "a string-keyed dictionary is reported when its value type is not concrete" begin
    files = [
        "data/Data.jl" => "include(\"maps.jl\")\n",
        "data/maps.jl" => """
            function wide()
                Dict{String,Int}()
            end
            function labels()
                Dict{String,String}()
            end
            function ranks()
                Dict{String,Symbol}()
            end
            function pairs()
                Dict{String,NTuple{2,Int}}()
            end
            function sets()
                Dict{String,Set{String}}()
            end
            function lists()
                Dict{String,Vector{Int}}()
            end
            function qualified()
                Base.Dict{String,Any}()
            end
            function record()
                Dict{String,Union{Int,String}}()
            end
            function numbers()
                Dict{String,Integer}()
            end
            function open_lists()
                Dict{String,Vector}()
            end
            function nested()
                Dict{String,Dict{String,Any}}()
            end
            struct Bucket
                rows::Dict{String,Float64}
            end
            function takes(rows::Dict{String,UInt8})
                rows
            end
            """,
        "other/Other.jl" => "outside() = Dict{String,Any}()\n",
    ]
    rank = Dict(:Data => 1, :Other => 2)
    dir2mod = Dict("data" => :Data, "other" => :Other)
    ctx = project_context(files, rank, dir2mod, Module[])
    check = ArchCheck.StringPayloads(("src/data",))
    @test ArchCheck.kinds(check) == (:string_payload => :advisory,)
    found = ArchCheck.run(check, ctx)
    rows = finding_rows(found, :type)
    expected = [
        ("Base.Dict{String,Any}", "src/data/maps.jl", :string_payload, "Base.Dict{String,Any}"),
        ("Dict{String,Any}", "src/data/maps.jl", :string_payload, "Dict{String,Any}"),
        ("Dict{String,Integer}", "src/data/maps.jl", :string_payload, "Dict{String,Integer}"),
        ("Dict{String,Union{Int,String}}", "src/data/maps.jl", :string_payload, "Dict{String,Union{Int,String}}"),
        ("Dict{String,Vector}", "src/data/maps.jl", :string_payload, "Dict{String,Vector}"),
    ]
    @test rows == expected
end

@testset "a configured directory with no indexed file is refused" begin
    files = ["data/Data.jl" => "x() = 1\n"]
    rank = Dict(:Data => 1)
    dir2mod = Dict("data" => :Data)
    ctx = project_context(files, rank, dir2mod, Module[])
    absent = "src/absent"
    refused = (
        ArchCheck.StringPayloads((absent,)),
        ArchCheck.SentinelReturns((absent,)),
        ArchCheck.CallerWhitelist((:f,), (), (absent,)),
    )
    for check in refused
        @test_throws ArgumentError ArchCheck.run(check, ctx)
    end
end
