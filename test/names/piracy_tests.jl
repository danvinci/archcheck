# A method on a foreign function needs an argument type its module owns. GlueExt sits in ext/, as an extension does.

const METHOD_FAMILY = load_package("MethodFamily", """
include("siba/SibA.jl")
using .SibA
include("sibb/SibB.jl")
using .SibB
Base.length(::SibB.Twig) = 2
SibA.spread(x::String; pad = 0) = x
glue(x::Int) = x
struct Span end
Base.similar(xs::Array, ::Type{Union{Span, Missing}}) = xs
Base.similar(::Type{T}, ::Base.RefValue{Symbol}) where {T<:Array{Union{Span, Missing}}} = T
Base.similar(x::Union{Span, Int}, ::Base.RefValue{Symbol}) = x
Base.similar(::Type{T}, ::Base.RefValue{Missing}) where {T<:Union{Span, Int}} = T
Base.similar(::Type{Union{Int, Missing}}, ::Base.RefValue{Missing}) = Int
include("../ext/GlueExt.jl")
""", [
    "../ext/GlueExt.jl" => """
    module GlueExt
    import ..MethodFamily: glue
    glue(x::Char) = x
    Base.:-(left::Base.RefValue{Symbol}, right::Base.RefValue{Symbol}) = right
    end
    """,
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
    Base.:+(left::Base.RefValue{Symbol}, right::Base.RefValue{Symbol}) = left
    end
    """,
])

# A signature as a fresh process prints it in full: from a module holding only the standard imports, no alias named.
const FRESH_SCOPE = Module(:FreshScope)

function method_signature(parts...)
    signature = Tuple{parts...}
    context = (:module => FRESH_SCOPE, :compact => false)
    sprint(show, signature; context)
end

# A where-bound signature, as the method table stores it: the variable outside the tuple.
function where_signature(func, bound, argument)
    var = TypeVar(:T, bound)
    body = Tuple{typeof(func), Type{var}, argument}
    signature = UnionAll(var, body)
    context = (:module => FRESH_SCOPE, :compact => false)
    sprint(show, signature; context)
end

@testset "a method on a foreign function needs an argument type its package owns, or when strict its module" begin
    ctx = case_context(METHOD_FAMILY)
    found = ArchCheck.run(ModulePiracy(strict = true), ctx)
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
    reference = Base.RefValue{Symbol}
    on_base = method_signature(typeof(+), reference, reference)
    @test (sib_b, on_base) in flagged

    extension = :GlueExt
    on_glue = method_signature(typeof(pkg.glue), Char)
    on_minus = method_signature(typeof(-), reference, reference)
    @test !((extension, on_glue) in flagged)
    @test (extension, on_minus) in flagged

    span = pkg.Span
    on_type_union = method_signature(typeof(similar), Array, Type{Union{span, Missing}})
    on_bare_union = method_signature(typeof(similar), Union{span, Int}, Base.RefValue{Symbol})
    on_foreign_type = method_signature(typeof(similar), Type{Union{Int, Missing}}, Base.RefValue{Missing})
    array_bound = Array{Union{span, Missing}}
    on_array_bound = where_signature(similar, array_bound, Base.RefValue{Symbol})
    union_bound = Union{span, Int}
    on_union_bound = where_signature(similar, union_bound, Base.RefValue{Missing})
    @test !((root, on_type_union) in flagged)
    @test !((root, on_array_bound) in flagged)
    @test (root, on_bare_union) in flagged
    @test (root, on_union_bound) in flagged
    @test (root, on_foreign_type) in flagged
    @test length(found) == 12

    package_found = ArchCheck.run(ModulePiracy(), ctx)
    package_flagged = Set((finding.mod, ev(finding, :signature)) for finding in package_found)
    @test package_flagged == Set([
        (sib_b, on_base), (extension, on_minus),
        (root, on_bare_union), (root, on_union_bound), (root, on_foreign_type),
    ])

    by_signature = Dict(ev(finding, :signature) => finding for finding in found)
    leaf_finding = by_signature[on_leaf]
    @test endswith(leaf_finding.file, "SibB.jl")
    @test leaf_finding.line == 7
    @test leaf_finding.symbol == "spread"
    @test ev(leaf_finding, :owner) == "MethodFamily.SibA"
    length_finding = by_signature[on_length]
    @test ev(length_finding, :owner) == "Base"
end
