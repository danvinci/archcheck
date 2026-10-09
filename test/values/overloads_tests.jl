# One kernel written twice, once per array storage. Fixed-size arrays are local types.
# The lattice draw decides which pairs fire. The source is that draw, written out.

struct LatticeType
    form::Union{Symbol,Expr} # argument type as written in the method
    wheres::Vector{Symbol}   # type variables that form names
end

plain(form) = LatticeType(form, Symbol[])

parametric(form, vars) = LatticeType(form, collect(vars))

const VECTOR_F64 = plain(:(Vector{Float64}))
const MATRIX_F64 = plain(:(Matrix{Float64}))
const VECTOR_INT = plain(:(Vector{Int}))
const FIX_F64 = parametric(:(Fix{N,Float64}), (:N,))
const FIX_INT = parametric(:(Fix{M,Int}), (:M,))
const FIXB = plain(:(FixB))
const WIDE_F64 = plain(:(AbstractVector{Float64}))
const FLOAT_SLOT = plain(:(Float64))
const REAL_SLOT = plain(:(Real))
const INT_SLOT = plain(:(Int))

function orient_pair(rng, left, right, fires)
    flip = rand(rng, Bool)
    flip || return (left, right, fires)
    (right, left, fires)
end

function recipe_heap_fixed(rng)
    use_int = rand(rng, Bool)
    if use_int
        return ([VECTOR_INT], [FIX_INT], true)
    end
    heap = rand(rng, (VECTOR_F64, MATRIX_F64))
    fixed = rand(rng, (FIX_F64, FIXB))
    ([heap], [fixed], true)
end

function recipe_two_heaps(_rng)
    ([VECTOR_F64], [MATRIX_F64], true)
end

function recipe_two_positions(_rng)
    ([VECTOR_F64, VECTOR_INT], [FIX_F64, FIX_INT], true)
end

function recipe_shared_scalar(_rng)
    ([INT_SLOT, VECTOR_F64], [INT_SLOT, FIX_F64], true)
end

function recipe_two_fixed(_rng)
    ([FIX_F64], [FIXB], false)
end

function recipe_scalar_specialize(rng)
    use_int = rand(rng, Bool)
    use_int && return ([INT_SLOT], [REAL_SLOT], false)
    ([FLOAT_SLOT], [REAL_SLOT], false)
end

function recipe_supertype(rng)
    concrete = rand(rng, (VECTOR_F64, FIX_F64, FIXB))
    ([concrete], [WIDE_F64], false)
end

function recipe_element(rng)
    choice = rand(rng, 1:3)
    choice == 1 && return ([VECTOR_F64], [VECTOR_INT], false)
    choice == 2 && return ([VECTOR_F64], [FIX_INT], false)
    ([MATRIX_F64], [VECTOR_INT], false)
end

function recipe_mixed_position(_rng)
    ([VECTOR_F64, INT_SLOT], [FIX_F64, FLOAT_SLOT], false)
end

function recipe_arity(rng)
    flip = rand(rng, Bool)
    flip && return ([VECTOR_F64], [FIX_F64, VECTOR_INT], false)
    ([VECTOR_F64, INT_SLOT], [FIX_F64], false)
end

const RECIPES = (
    recipe_heap_fixed,
    recipe_two_heaps,
    recipe_two_positions,
    recipe_shared_scalar,
    recipe_two_fixed,
    recipe_scalar_specialize,
    recipe_supertype,
    recipe_element,
    recipe_mixed_position,
    recipe_arity,
)

function draw_pair(rng)
    recipe = rand(rng, RECIPES)
    left, right, fires = recipe(rng)
    orient_pair(rng, left, right, fires)
end

function overload_where_names(slots)
    wheres = Symbol[]
    for slot in slots
        for var in slot.wheres
            var in wheres || push!(wheres, var)
        end
    end
    wheres
end

function overload_method_text(name, slots)
    parts = String[]
    for (index, slot) in enumerate(slots)
        parameter = "slot" * string(index)
        form = string(slot.form)
        push!(parts, parameter * "::" * form)
    end
    signature = string(name) * "(" * join(parts, ", ") * ")"
    wheres = overload_where_names(slots)
    if !isempty(wheres)
        where_text = join(wheres, ", ")
        signature = signature * " where {" * where_text * "}"
    end
    signature * " = 0"
end

function overload_generated_spine()
    lines = String[
        "struct Fix{N,T} <: AbstractVector{T} end",
        "struct FixB <: AbstractVector{Float64} end",
    ]
    expected = Set{String}()
    for seed in 1:40
        rng = Random.Xoshiro(seed)
        left, right, fires = draw_pair(rng)
        name = "gen_" * string(seed)
        push!(lines, overload_method_text(name, left))
        push!(lines, overload_method_text(name, right))
        fires || continue
        push!(expected, name)
    end
    spine = join(lines, "\n")
    (; spine, expected)
end

const OVER_GENERATED = overload_generated_spine()
const OVER_GEN = load_package("OverGen", OVER_GENERATED.spine)

const STORE_SPINE = """
struct Fix{N,T} <: AbstractVector{T} end
kernel(xs::Vector{Float64}) = xs
kernel(xs::Fix{N,Float64}) where {N} = xs
both(xs::Vector{Float64}, ys::Vector{Int}) = xs
both(xs::Fix{N,Float64}, ys::Fix{M,Int}) where {N,M} = xs
tri(xs::Vector{Float64}) = xs
tri(x::Real) = x
tri(xs::Fix{N,Float64}) where {N} = xs
tail(n::Int, xs::Vector{Float64}) = xs
tail(n::Int, xs::Fix{N,Float64}) where {N} = xs
bounded(xs::T) where {T<:Vector{Float64}} = xs
bounded(xs::Fix{N,Float64}) where {N} = xs
wide_bound(xs::T) where {T<:AbstractVector{Float64}} = xs
wide_bound(xs::Vector{Float64}) = xs
kw(xs::Vector{Float64}; tol = 0) = xs
kw(xs::Fix{N,Float64}; tol = 0) where {N} = xs
struct Box{K} end
struct Tag{K} end
held(xs::Vector{Box{K}}) where {K} = xs
held(xs::Matrix{Tag{K}}) where {K} = xs
boxed(xs::Vector{Box{K}}) where {K} = xs
boxed(xs::Matrix{Box{L}}) where {L} = xs
"""

const STORE_HEAP = load_package("StoreHeap", STORE_SPINE)

# The heap method loads first; the fixed-size one sits in a module block a later file holds.
const STORE_BLOCK = load_package("StoreBlock", """
struct Fix{N,T} <: AbstractVector{T} end
include("heap.jl")
include("fixed.jl")
""", [
    "heap.jl" => "kernel(xs::Vector{Float64}) = xs\n",
    "fixed.jl" => "module Blocky\nimport ..kernel, ..Fix\nkernel(xs::Fix{N,Float64}) where {N} = xs\nend\n",
])

# A method added outside the package. Its module is the test's, so the pair stays the package's.
StoreHeap.kernel(xs::Matrix{Float64}) = xs

const PACK_STORE = load_package("PackStore", """
include("a/A.jl")
using .A
include("b/B.jl")
using .B
""", [
    "a/A.jl" => """
    module A
    struct Fix{N,T} <: AbstractVector{T} end
    shared(xs::Vector{Float64}) = xs
    end
    """,
    "b/B.jl" => """
    module B
    import ..A
    A.shared(xs::A.Fix{N,Float64}) where {N} = xs
    end
    """,
])

@testset "storage overloads are an error and run before the workload" begin
    check = StorageOverloads()
    @test ArchCheck.kinds(check) == (:storage_overload => :error,)
    @test ArchCheck.phase(check) === :static
end

@testset "a heap array beside a fixed-size array of the same elements is one finding" begin
    ctx = case_context(STORE_HEAP)
    store_found = ArchCheck.run(StorageOverloads(), ctx)
    kernel_sites = "src/StoreHeap.jl:3 src/StoreHeap.jl:4"
    cases = (
        (name = "kernel", count = 1,
         storage = "Vector{Float64} StoreHeap.Fix{N, Float64}",
         methods = kernel_sites),
        (name = "both", count = 1,
         storage = "Vector{Float64} StoreHeap.Fix{N, Float64} Vector{Int64} StoreHeap.Fix{M, Int64}",
         methods = nothing),
        (name = "tail", count = 1,
         storage = "Vector{Float64} StoreHeap.Fix{N, Float64}",
         methods = nothing),
        (name = "bounded", count = 1,
         storage = "Vector{Float64} StoreHeap.Fix{N, Float64}",
         methods = nothing),
        (name = "tri", count = 1, storage = nothing, methods = nothing),
        (name = "kw", count = 1, storage = nothing, methods = nothing),
        (name = "wide_bound", count = 0, storage = nothing, methods = nothing),
        (name = "held", count = 0, storage = nothing, methods = nothing),
        (name = "boxed", count = 1, storage = nothing, methods = nothing),
    )
    for case in cases
        hits = filter(f -> f.symbol == case.name, store_found)
        @test length(hits) == case.count
        case.count == 1 || continue
        hit = only(hits)
        if !isnothing(case.storage)
            @test ev(hit, :storage) == case.storage
        end
        if !isnothing(case.methods)
            @test ev(hit, :methods) == case.methods
        end
    end
    pack_ctx = case_context(PACK_STORE)
    pack_found = ArchCheck.run(StorageOverloads(), pack_ctx)
    shared_hits = filter(f -> f.symbol == "shared", pack_found)
    @test length(shared_hits) == 1
    shared_hit = only(shared_hits)
    @test shared_hit.mod === :A
    block_ctx = case_context(STORE_BLOCK)
    block_found = ArchCheck.run(StorageOverloads(), block_ctx)
    block_hit = only(block_found)
    @test block_hit.file == joinpath("src", "heap.jl")
end

@testset "storage pairs drawn from the lattice match the verdict of the draw" begin
    ctx = case_context(OVER_GEN)
    found = ArchCheck.run(StorageOverloads(), ctx)
    got = Set(f.symbol for f in found)
    @test got == OVER_GENERATED.expected
    @test all(f -> f.kind === :storage_overload, found)
end
