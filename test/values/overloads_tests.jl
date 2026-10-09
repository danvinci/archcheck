# One kernel written twice, once per array storage. Fixed-size arrays are local types.

const OVERLOADS_FILE = joinpath(pkgdir(ArchCheck), "src", "checks_overloads.jl")
isdefined(ArchCheck, :StorageOverloads) || Base.include(ArchCheck, OVERLOADS_FILE)

struct LatticeType
    form::Union{Symbol,Expr} # argument type as written in the method
    wheres::Vector{Symbol}   # type variables that form names
end

plain(form) = LatticeType(form, Symbol[])

function parametric(form, vars)
    names = collect(vars)
    LatticeType(form, names)
end

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

function define_slots(mod, name, slots)
    arguments = Expr[]
    wheres = Symbol[]
    for (index, slot) in enumerate(slots)
        parameter = Symbol("slot", index)
        argument = Expr(:(::), parameter, slot.form)
        push!(arguments, argument)
        for var in slot.wheres
            var in wheres || push!(wheres, var)
        end
    end
    signature = Expr(:call, name, arguments...)
    if !isempty(wheres)
        signature = Expr(:where, signature, wheres...)
    end
    definition = Expr(:(=), signature, 0)
    Core.eval(mod, definition)
end

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

function overload_index()
    directory = mktempdir()
    src = joinpath(directory, "src")
    mkpath(src)
    entry = joinpath(src, "Empty.jl")
    write(entry, "placeholder() = 1\n")
    rank = Dict(:Empty => 1)
    dirs = Dict("." => :Empty)
    ArchCheck.build_source_index(src, rank, dirs)
end

function hits_named(found, name)
    [f for f in found if f.symbol == name]
end

module FStore
    struct Fix{N,T} <: AbstractVector{T} end
    const KERNEL_LINE = @__LINE__() + 1
    kernel(xs::Vector{Float64}) = xs
    const KERNEL_FIX_LINE = @__LINE__() + 1
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
end

# A method added outside the package. Its module is the test's, so the pair stays the package's.
FStore.kernel(xs::Matrix{Float64}) = xs

module FPack
    module A
        struct Fix{N,T} <: AbstractVector{T} end
        shared(xs::Vector{Float64}) = xs
    end
    module B
        import ..A
        A.shared(xs::A.Fix{N,Float64}) where {N} = xs
    end
end

module FGen
    struct Fix{N,T} <: AbstractVector{T} end
    struct FixB <: AbstractVector{Float64} end
end

gen_expected = Set{String}()
for seed in 1:40
    rng = Random.Xoshiro(seed)
    left, right, fires = draw_pair(rng)
    name = Symbol("gen_", seed)
    define_slots(FGen, name, left)
    define_slots(FGen, name, right)
    fires || continue
    push!(gen_expected, string(name))
end

@testset "storage overloads are an error and run before the workload" begin
    check = ArchCheck.StorageOverloads()
    @test ArchCheck.kinds(check) == (:storage_overload => :error,)
    @test ArchCheck.phase(check) === :static
end

@testset "a heap array beside a fixed-size array of the same elements is one finding" begin
    index = overload_index()
    here = relpath(@__FILE__, index.repo)
    store_ctx = Context(index, FStore, [FStore])
    store_found = ArchCheck.run(ArchCheck.StorageOverloads(), store_ctx)
    kernel_sites = "$(here):$(FStore.KERNEL_LINE) $(here):$(FStore.KERNEL_FIX_LINE)"
    cases = (
        (name = "kernel", count = 1,
         storage = "Vector{Float64} Main.FStore.Fix{N, Float64}",
         methods = kernel_sites),
        (name = "both", count = 1,
         storage = "Vector{Float64} Main.FStore.Fix{N, Float64} Vector{Int64} Main.FStore.Fix{M, Int64}",
         methods = nothing),
        (name = "tail", count = 1,
         storage = "Vector{Float64} Main.FStore.Fix{N, Float64}",
         methods = nothing),
        (name = "bounded", count = 1,
         storage = "Vector{Float64} Main.FStore.Fix{N, Float64}",
         methods = nothing),
        (name = "tri", count = 1, storage = nothing, methods = nothing),
        (name = "kw", count = 1, storage = nothing, methods = nothing),
        (name = "wide_bound", count = 0, storage = nothing, methods = nothing),
    )
    for case in cases
        hits = hits_named(store_found, case.name)
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

    pack_mods = [FPack, FPack.A, FPack.B]
    pack_ctx = Context(index, FPack, pack_mods)
    pack_found = ArchCheck.run(ArchCheck.StorageOverloads(), pack_ctx)
    shared_hits = hits_named(pack_found, "shared")
    @test length(shared_hits) == 1
    if length(shared_hits) == 1
        shared_hit = only(shared_hits)
        @test shared_hit.mod === Symbol("FPack.A")
    end
end

@testset "storage pairs drawn from the lattice match the verdict of the draw" begin
    index = overload_index()
    ctx = Context(index, FGen, [FGen])
    found = ArchCheck.run(ArchCheck.StorageOverloads(), ctx)
    got = Set(f.symbol for f in found)
    @test got == gen_expected
    @test all(f -> f.kind === :storage_overload, found)
end
