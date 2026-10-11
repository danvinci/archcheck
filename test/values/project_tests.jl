# The caller whitelist, over written sources.

const CALLER_ROOT = load_package("CallerRoot", """
include("calls/readers.jl")
include("calls/outside.jl")
include("calls/owner/root.jl")
include("calls/loaded.jl")
include("calls/bound.jl")
""", [
    "calls/loaded.jl" => "const FOUND = root_find(1)\n",
    # Clauses, a definition and its docstring name a guarded function without reading it; a bound handle reads it.
    "calls/bound.jl" => """
    using Base: isodd
    import Base: iseven
    function other_find end
    \"\"\"Finds the other.\"\"\"
    other_find(x) = x
    const handle = root_find
    """,
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

const ABSENT_ROOT = load_package("AbsentRoot", "x() = 1\n")

@testset "an unlisted definition or load-time code that reads a guarded name is an error" begin
    ctx = case_context(CALLER_ROOT)
    allowed = (("src/calls/readers.jl", :allowed_reader),)
    callees = (:root_find, :other_find, :isodd, :iseven)
    exempt = ("src/calls/owner",)
    check = CallerWhitelist(callees, allowed, exempt)
    @test ArchCheck.kinds(check) == (:unlisted_caller => :error,)
    found = ArchCheck.run(check, ctx)
    load_time = [(finding.file, finding.line) for finding in found if isempty(finding.symbol)]
    @test sort!(load_time) == [("src/calls/bound.jl", 6), ("src/calls/loaded.jl", 1)]
    rows = evidence_rows(found, :references)
    expected = [
        (:unlisted_caller, "", "root_find"),
        (:unlisted_caller, "", "root_find"),
        (:unlisted_caller, "both", "other_find root_find"),
        (:unlisted_caller, "outsider", "root_find"),
        (:unlisted_caller, "qualified", "root_find"),
    ]
    @test rows == expected
end

@testset "a configured directory with no indexed file is refused" begin
    ctx = case_context(ABSENT_ROOT)
    check = CallerWhitelist((:f,), (), ("src/absent",))
    @test_throws ArgumentError ArchCheck.run(check, ctx)
end
