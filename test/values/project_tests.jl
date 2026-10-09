# Caller whitelist, sentinel returns, and string payloads, over one written source each.

const CALLER_ROOT = load_package("CallerRoot", """
include("calls/readers.jl")
include("calls/outside.jl")
include("calls/owner/root.jl")
""", [
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
])

const SENTINEL_BODIES = """
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
"""

const SENTINEL_OTHER = """
function elsewhere_nothing()
    nothing
end
"""

const SENTINEL_FULL = load_package("SentinelFull", """
include("gate/checked/bodies.jl")
include("gate/other.jl")
export ends_nothing, returns_missing, nested_closure, documented, ends_value
public ends_inf
public ends_nan
""", [
    "gate/checked/bodies.jl" => SENTINEL_BODIES,
    "gate/other.jl" => SENTINEL_OTHER,
])

const SENTINEL_OMIT_BODIES = """
ends_nothing() = nothing
ends_inf() = -Inf
ends_nan() = NaN
returns_missing() = missing
hidden() = nothing
ends_value() = 1
"""

const SENTINEL_OMIT = load_package("SentinelOmit", """
include("gate/checked/bodies.jl")
export ends_nothing, returns_missing, ends_value
public ends_inf
public ends_nan
""", [
    "gate/checked/bodies.jl" => SENTINEL_OMIT_BODIES,
])

const PAYLOAD_MAPS = """
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
"""

const PAYLOAD_ROOT = load_package("PayloadRoot", """
include("data/maps.jl")
include("other/other.jl")
""", [
    "data/maps.jl" => PAYLOAD_MAPS,
    "other/other.jl" => "outside() = Dict{String,Any}()\n",
])

const ABSENT_ROOT = load_package("AbsentRoot", "x() = 1\n")

@testset "an unlisted definition that calls a guarded name is an error" begin
    ctx = case_context(CALLER_ROOT)
    allowed = (("src/calls/readers.jl", :allowed_reader),)
    callees = (:root_find, :other_find)
    exempt = ("src/calls/owner",)
    check = CallerWhitelist(callees, allowed, exempt)
    @test ArchCheck.kinds(check) == (:unlisted_caller => :error,)
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :calls)
    expected = [
        (:unlisted_caller, "both", "other_find root_find"),
        (:unlisted_caller, "outsider", "root_find"),
        (:unlisted_caller, "qualified", "root_find"),
    ]
    @test rows == expected
end

@testset "a public function in the configured directory that returns a sentinel is reported" begin
    ctx = case_context(SENTINEL_FULL)
    check = SentinelReturns(("src/gate/checked",))
    @test ArchCheck.kinds(check) == (:sentinel_return => :advisory,)
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :sentinel)
    expected = [
        (:sentinel_return, "documented", "NaN"),
        (:sentinel_return, "ends_inf", "-Inf"),
        (:sentinel_return, "ends_nan", "NaN"),
        (:sentinel_return, "ends_nothing", "nothing"),
        (:sentinel_return, "returns_missing", "missing"),
    ]
    @test rows == expected
end

@testset "a sentinel set that omits nothing leaves a typed absence quiet" begin
    ctx = case_context(SENTINEL_OMIT)
    sentinels = (:Inf, :NaN, :missing)
    check = SentinelReturns(("src/gate/checked",), sentinels)
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :sentinel)
    expected = [
        (:sentinel_return, "ends_inf", "-Inf"),
        (:sentinel_return, "ends_nan", "NaN"),
        (:sentinel_return, "returns_missing", "missing"),
    ]
    @test rows == expected
end

@testset "a string-keyed dictionary is reported when its value type is not concrete" begin
    ctx = case_context(PAYLOAD_ROOT)
    check = StringPayloads(("src/data",))
    @test ArchCheck.kinds(check) == (:string_payload => :advisory,)
    found = ArchCheck.run(check, ctx)
    rows = evidence_rows(found, :type)
    expected = [
        (:string_payload, "Base.Dict{String,Any}", "Base.Dict{String,Any}"),
        (:string_payload, "Dict{String,Any}", "Dict{String,Any}"),
        (:string_payload, "Dict{String,Integer}", "Dict{String,Integer}"),
        (:string_payload, "Dict{String,Union{Int,String}}", "Dict{String,Union{Int,String}}"),
        (:string_payload, "Dict{String,Vector}", "Dict{String,Vector}"),
    ]
    @test rows == expected
end

@testset "a configured directory with no indexed file is refused" begin
    ctx = case_context(ABSENT_ROOT)
    absent = "src/absent"
    refused = (
        StringPayloads((absent,)),
        SentinelReturns((absent,)),
        CallerWhitelist((:f,), (), (absent,)),
    )
    for check in refused
        @test_throws ArgumentError ArchCheck.run(check, ctx)
    end
end
