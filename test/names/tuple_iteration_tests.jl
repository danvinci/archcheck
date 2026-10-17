# A flatten over a Tuple or NamedTuple is a finding. A plain loop, a single-level generator, an NTuple and a Vector
# each compile one `iterate` method, so none is.

const TUPLE_LOOPS = load_package("TupleLoops", """
include("loops.jl")
""", [
    "loops.jl" => """
    flat_group(group::NamedTuple) = Iterators.flatten(parts(value) for value in values(group))
    flat_pairs(group::NamedTuple{K}) where {K} = Iterators.flatten(pairs(group))
    flat_bare(pieces::Tuple{Vector{Int},UnitRange{Int}}) = Iterators.flatten(pieces)
    flat_literal(a, b) = Base.Iterators.flatten((a, b))
    nested(pieces::Tuple) = [step for piece in pieces for step in piece]
    nested_filtered(group::NamedTuple) = (step for piece in values(group) if !isempty(piece) for step in piece)
    function wrapped(group::NamedTuple)
        each = function ()
            Iterators.flatten(values(group))
        end
        each()
    end
    function looped(group::NamedTuple)
        total = 0
        for piece in values(group)
            total += length(piece)
        end
        total
    end
    single(pieces::Tuple) = (length(piece) for piece in pieces)
    product(pieces::Tuple) = [(piece, step) for piece in pieces, step in 1:2]
    homogeneous(pieces::NTuple{2,Vector{Int}}) = Iterators.flatten(pieces)
    flat_vector(pieces::Vector) = Iterators.flatten(pieces)
    nested_vector(pieces::Vector) = [step for piece in pieces for step in piece]
    function shadowed(pieces::Tuple)
        let pieces = collect(pieces)
            Iterators.flatten(pieces)
        end
    end
    """,
])

@testset "a flatten over a Tuple or NamedTuple is a finding and a single level of iteration is none" begin
    ctx = case_context(TUPLE_LOOPS)
    found = ArchCheck.run(TupleIterations(), ctx)
    rows = evidence_rows(found, :iterates)
    @test rows == [(:tuple_iteration, "flat_bare", "pieces"),
                   (:tuple_iteration, "flat_group", "values(group)"),
                   (:tuple_iteration, "flat_literal", "(a, b)"),
                   (:tuple_iteration, "flat_pairs", "pairs(group)"),
                   (:tuple_iteration, "nested", "pieces"),
                   (:tuple_iteration, "nested_filtered", "values(group)"),
                   (:tuple_iteration, "wrapped", "values(group)")]
    @test (:tuple_iteration => :error) in ArchCheck.kinds(TupleIterations())
end
