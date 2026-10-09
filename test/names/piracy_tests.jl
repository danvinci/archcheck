# A method on a foreign function needs an argument type its module owns.

const METHOD_FAMILY = load_package("MethodFamily", """
include("siba/SibA.jl")
using .SibA
include("sibb/SibB.jl")
using .SibB
Base.length(::SibB.Twig) = 2
SibA.spread(x::String; pad = 0) = x
""", [
    "siba/SibA.jl" => """
    module SibA
    struct Leaf end
    spread(x::Int) = x
    Base.show(io::IO, ::Leaf) = print(io, "leaf")
    end
    """,
    "sibb/SibB.jl" => """
    module SibB
    using ..SibA
    struct Twig end
    SibA.spread(x::Twig) = x
    Base.show(io::IO, ::Twig) = print(io, "twig")
    Base.zero(::Type{Twig}) = Twig()
    SibA.spread(x::SibA.Leaf) = x
    SibA.spread(x::Float64) = x
    Base.length(::SibA.Leaf) = 1
    Base.one(::Type{SibA.Leaf}) = SibA.Leaf()
    SibA.spread(x::Union{Twig,Char}) = x
    end
    """,
])

function method_signature(parts...)
    string(Tuple{parts...})
end

@testset "a method on a foreign function needs an argument type its module owns" begin
    ctx = case_context(METHOD_FAMILY)
    found = ArchCheck.run(ModulePiracy(), ctx)
    flagged = Set((finding.mod, ev(finding, :signature)) for finding in found)
    pkg = METHOD_FAMILY.pkg
    leaf = pkg.SibA.Leaf
    twig = pkg.SibB.Twig
    spread = pkg.SibA.spread
    sib_b = :SibB
    root = :MethodFamily

    on_twig = method_signature(typeof(spread), twig)
    on_show = method_signature(typeof(show), IO, twig)
    on_zero = method_signature(typeof(zero), Type{twig})
    parent_length = method_signature(typeof(length), twig)
    @test !any(finding -> finding.mod === :SibA, found)
    @test !((sib_b, on_twig) in flagged)
    @test !((sib_b, on_show) in flagged)
    @test !((sib_b, on_zero) in flagged)
    @test !((root, parent_length) in flagged)

    on_leaf = method_signature(typeof(spread), leaf)
    on_float = method_signature(typeof(spread), Float64)
    on_length = method_signature(typeof(length), leaf)
    on_one = method_signature(typeof(one), Type{leaf})
    on_union = method_signature(typeof(spread), Union{twig,Char})
    on_string = method_signature(typeof(spread), String)
    on_kw = method_signature(typeof(Core.kwcall), NamedTuple, typeof(spread), String)
    @test (sib_b, on_leaf) in flagged
    @test (sib_b, on_float) in flagged
    @test (sib_b, on_length) in flagged
    @test (sib_b, on_one) in flagged
    @test (sib_b, on_union) in flagged
    @test (root, on_string) in flagged
    @test (root, on_kw) in flagged
    @test length(found) == 7

    by_signature = Dict(ev(finding, :signature) => finding for finding in found)
    leaf_finding = by_signature[on_leaf]
    @test endswith(leaf_finding.file, "SibB.jl")
    @test leaf_finding.line == 7
    @test leaf_finding.symbol == "spread"
    @test ev(leaf_finding, :owner) == "MethodFamily.SibA"
    length_finding = by_signature[on_length]
    @test ev(length_finding, :owner) == "Base"
end
