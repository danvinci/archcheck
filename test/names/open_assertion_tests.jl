# A type assertion in a method body naming a parametric type without its parameters leaves the value abstract, so it
# is a finding; a concrete or parameterized assertion, a declaration and a name that resolves to no type are none

const ASSERTIONS = load_package("Assertions", """
include("types.jl")
include("asserts.jl")
""", [
    "types.jl" => """
    struct Wrapper{M}
        value::M
    end
    struct Plain
        value::Int
    end
    const Alias = Wrapper
    """,
    "asserts.jl" => """
    opened(task) = fetch(task)::Wrapper
    aliased(task) = fetch(task)::Alias
    qualified(xs) = first(xs)::Base.Vector
    closed(task) = fetch(task)::Wrapper{Int}
    concrete(task) = fetch(task)::Plain
    matched(task, x) = fetch(task)::typeof(x)
    parameter(task, ::Wrapper{M}) where {M} = fetch(task)::Wrapper{M}
    argument(x::Wrapper) = x
    returned(x)::Wrapper = x
    function declared(x)
        local held::Wrapper = x
        typed::Wrapper = x
        (held, typed)
    end
    unknown(task) = fetch(task)::NoSuchType
    function shadowed(task, Wrapper)
        fetch(task)::Wrapper
    end
    closure(xs) = map((x::Wrapper) -> x, xs)
    function nested(task)
        inner() = fetch(task)::Wrapper
        inner()
    end
    loaded = Wrapper(1)::Wrapper
    each(xs) = [x::Vector for x in xs]
    """,
])

@testset "an assertion to a parametric type written without its parameters is a finding, a declaration none" begin
    ctx = case_context(ASSERTIONS)
    found = ArchCheck.run(OpenAssertions(), ctx)
    rows = evidence_rows(found, :type)
    @test rows == [(:open_assertion, "aliased", "Alias"),
                   (:open_assertion, "each", "Vector"),
                   (:open_assertion, "inner", "Wrapper"),
                   (:open_assertion, "opened", "Wrapper"),
                   (:open_assertion, "qualified", "Base.Vector")]
    opened = only(finding for finding in found if finding.symbol == "opened")
    @test (opened.file, opened.line) == (joinpath("src", "asserts.jl"), 1)
    inner = only(finding for finding in found if finding.symbol == "inner")
    @test inner.line == 21
    @test (:open_assertion => :advisory) in ArchCheck.kinds(OpenAssertions())
end
