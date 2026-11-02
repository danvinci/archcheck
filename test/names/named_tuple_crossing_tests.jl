# A function handing back a named tuple literal that another file keeps is a finding: a file of another module reading
# the function, or a file of its own module whose call does not destructure the result by name where it lands

const RECORDS = load_package("Records", """
include("make.jl")
include("use.jl")
include("other.jl")
""", [
    "make.jl" => """
    make_pair(x) = (left = x, right = 2x)
    make_named(x) = (; x)
    function make_held(x)
        record = (; first = x, second = x)
        return record
    end
    function make_branch(x)
        if x > 0
            return (; x)
        end
        (; y = x)
    end
    make_mapped(xs) = map(xs) do x
        (; x)
    end
    make_looped(xs) = [(; x) for x in xs]
    make_tuple(x) = (x, x)
    make_published(x) = (; x)
    make_unread(x) = (; x)
    make_caller(x) = make_unread(x).x
    make_shadowed(x) = (; x)
    function make_nested(x)
        inner(y) = (; y)
        inner(x).y
    end
    """,
    "use.jl" => """
    function uses(x)
        (; x) = make_named(x)
        held = make_held(x).first
        value = make_branch(x)
        total = 0
        for (; x) in make_mapped([x])
            total += x
        end
        (; x) = make_shadowed(x)
        (held, value)
    end
    shadow(make_shadowed) = make_shadowed(1)
    """,
    "other.jl" => """
    module Other
    using ..Records: make_pair, make_tuple, make_published, make_nested
    import ..Records
    take(x) = make_pair(x).left
    pieces(x) = make_tuple(x)
    published(x) = make_published(x)
    nested(x) = make_nested(x)
    looped(xs) = Records.make_looped(xs)
    end
    """,
])

@testset "a named tuple another file keeps is a finding, and one destructured by name where the call lands is none" begin
    ctx = case_context(RECORDS)
    found = ArchCheck.run(NamedTupleCrossings(), ctx)
    rows = evidence_rows(found, :fields, :called_in)
    use_path = joinpath("src", "use.jl")
    other_path = joinpath("src", "other.jl")
    @test rows == [(:named_tuple_crossing, "make_branch", "x", use_path),
                   (:named_tuple_crossing, "make_held", "first,second", use_path),
                   (:named_tuple_crossing, "make_looped", "x", other_path),
                   (:named_tuple_crossing, "make_pair", "left,right", other_path),
                   (:named_tuple_crossing, "make_published", "x", other_path)]
    held = only(finding for finding in found if finding.symbol == "make_held")
    @test (held.file, held.line) == (joinpath("src", "make.jl"), 3)
    @test (:named_tuple_crossing => :advisory) in ArchCheck.kinds(NamedTupleCrossings())
end

@testset "a producer the package publishes as a named tuple on purpose is no finding, and an allowance naming none is stale" begin
    ctx = case_context(RECORDS)
    make_path = joinpath("src", "make.jl")
    gone_path = joinpath("src", "gone.jl")
    allowed = ((make_path, :make_published), (make_path, :make_tuple), (gone_path, :vanished))
    found = ArchCheck.run(NamedTupleCrossings(; allowed), ctx)
    rows = sort!([(finding.kind, finding.file, finding.symbol) for finding in found])
    @test rows == [(:named_tuple_crossing, make_path, "make_branch"),
                   (:named_tuple_crossing, make_path, "make_held"),
                   (:named_tuple_crossing, make_path, "make_looped"),
                   (:named_tuple_crossing, make_path, "make_pair"),
                   (:stale_allowance, gone_path, "vanished"),
                   (:stale_allowance, make_path, "make_tuple")]
    stale = only(finding for finding in found if finding.symbol == "vanished")
    @test stale.mod === :Records
    @test (:stale_allowance => :error) in ArchCheck.kinds(NamedTupleCrossings())
end
