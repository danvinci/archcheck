# A method on a foreign function needs an argument type its module owns.
# module-piracy corpus: two siblings and their parent, each adding methods to functions and types the others own
module FFam
    module SibA
        struct Leaf end
        spread(x::Int) = x
        Base.show(io::IO, ::Leaf) = print(io, "leaf")
    end
    module SibB
        using ..SibA
        struct Twig end
        SibA.spread(x::Twig) = x
        Base.show(io::IO, ::Twig) = print(io, "twig")
        Base.zero(::Type{Twig}) = Twig()
        const PIRATE_AT = @__LINE__() + 1
        SibA.spread(x::SibA.Leaf) = x
        SibA.spread(x::Float64) = x
        Base.length(::SibA.Leaf) = 1
        Base.one(::Type{SibA.Leaf}) = SibA.Leaf()
        SibA.spread(x::Union{Twig,Char}) = x
    end
    Base.length(::SibB.Twig) = 2
    SibA.spread(x::String; pad = 0) = x
end

@testset "module piracy: a method on a foreign function needs an argument type its module owns" begin
    repo = normpath(joinpath(@__DIR__, ".."))
    here = relpath(@__FILE__, repo)
    found = ArchCheck.check_module_piracy([FFam, FFam.SibA, FFam.SibB]; repo)
    by_signature = Dict(ev(f, :signature) => f for f in found)
    flagged = Set((f.mod, ev(f, :signature)) for f in found)
    sig(parts...) = string(Tuple{parts...})
    sib_a = Symbol("FFam.SibA")
    sib_b = Symbol("FFam.SibB")
    Leaf = FFam.SibA.Leaf
    Twig = FFam.SibB.Twig
    spread = FFam.SibA.spread

    # a module's own function, or any function on a type the module owns
    @test !any(f -> f.mod === sib_a, found)
    @test !((sib_b, sig(typeof(spread), Twig)) in flagged)
    @test !((sib_b, sig(typeof(show), IO, Twig)) in flagged)
    @test !((sib_b, sig(typeof(zero), Type{Twig})) in flagged)
    # a parent owns the types of the modules nested in it
    @test !((:FFam, sig(typeof(length), Twig)) in flagged)

    # a foreign function on a sibling's type, on no owned type, and Base's function on a sibling's type
    @test (sib_b, sig(typeof(spread), Leaf)) in flagged
    @test (sib_b, sig(typeof(spread), Float64)) in flagged
    @test (sib_b, sig(typeof(length), Leaf)) in flagged
    # Type{T} belongs where T does; a Union that also claims a foreign type is foreign
    @test (sib_b, sig(typeof(one), Type{Leaf})) in flagged
    @test (sib_b, sig(typeof(spread), Union{Twig,Char})) in flagged
    # a keyword method is judged by the function it wraps
    @test (:FFam, sig(typeof(spread), String)) in flagged
    @test (:FFam, sig(typeof(Core.kwcall), NamedTuple, typeof(spread), String)) in flagged
    @test length(found) == 7

    # the finding sits at the method and names the function's owner
    on_leaf = by_signature[sig(typeof(spread), Leaf)]
    @test on_leaf.file == here && on_leaf.line == FFam.SibB.PIRATE_AT
    @test on_leaf.symbol == "spread"
    @test ev(on_leaf, :owner) == "Main.FFam.SibA"
    on_base = by_signature[sig(typeof(length), Leaf)]
    @test ev(on_base, :owner) == "Base"
end
