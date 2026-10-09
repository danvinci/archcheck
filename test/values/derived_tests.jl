# Declared derived values: one producer, a key that names every input, calls kept on the cache.

function case_package(name, body)
    directory = mktempdir()
    src = joinpath(directory, "src")
    mkpath(src)
    path = joinpath(src, "$name.jl")
    text = "module $name\n" * body * "\nend\n"
    write(path, text)
    include(path)
    mod_name = Symbol(name)
    mod = Base.invokelatest(getfield, Main, mod_name)
    layout = ArchCheck.package_layout(path, mod_name)
    rank = layout[1]
    dirs = layout[2]
    index = ArchCheck.build_source_index(src, rank, dirs; root = mod_name)
    (mod = mod, index = index, directory = directory)
end

function declared_findings(check, loaded, derived)
    ctx = Context(loaded.index, loaded.mod, [loaded.mod]; derived = derived)
    ArchCheck.run(check, ctx)
end

function of_kind(found, kind)
    [finding for finding in found if finding.kind === kind]
end

const ROLE_BODY = """
struct Role
    n::Int
end
function make_role(n::Int)
    Role(n)
end
function again(n::Int)
    Role(n + 1)
end
function labeled(n::Int)::Role
    n
end
function plain(n::Int)
    n + 1
end
make_role(n::Float64) = Role(round(Int, n))
function mirror(knots)
    1 .- reverse(knots)
end
"""

const KEY_BODY = """
struct Piece
    knots::Vector{Float64}
    degree::Int
end
mutable struct Box
    x::Int
end
struct Imm
    x::Int
end
function solid(piece::Piece)
    piece.knots .+ piece.degree
end
function solid_key(piece::Piece)
    (length(piece.knots),)
end
function full_key(piece::Piece)
    (length(piece.knots), piece.degree)
end
function bits_key(x::Int)
    (x, 1)
end
function vector_key(x::Int)
    [x]
end
function ptr_key(x::Int)
    Ptr{Cvoid}(0)
end
function count_only(x::Int)
    x + 1
end
function id_cache(x::Int)
    cache = IdDict{Int,Int}()
    cache[x] = x
    x
end
function object_key(x::Int)
    objectid(x)
end
function boxed(box::Box)
    Dict{Box,Int}()
    box.x
end
function box_key(box::Box)
    box.x
end
function imm_cache(imm::Imm)
    Dict{Imm,Int}()
    imm.x
end
function imm_key(imm::Imm)
    imm.x
end
macro memoize(ex)
    esc(ex)
end
macro memoize(cache, ex)
    esc(ex)
end
@memoize function bare_cache(x::Int)
    x + 1
end
@memoize Dict function typed_cache(x::Int)
    x + 1
end
"""

const HASHED_BODY = """
mutable struct Box
    x::Int
end
Base.hash(box::Box, h::UInt) = hash(box.x, h)
function boxed(box::Box)
    Dict{Box,Int}()
    box.x
end
function box_key(box::Box)
    box.x
end
"""

const KEPT_BODY = """
mutable struct Owner
    held::Int
end
function make_role(n::Int)
    n
end
function keep(owner, n)
    owner.held = make_role(n)
    owner
end
function read_held(owner, n)
    make_role(n)
    owner.held
end
"""

@testset "a role built in a second method is a second producer" begin
    loaded = case_package("ProdRole", ROLE_BODY)
    derived = (Derived(loaded.mod.make_role),)
    found = declared_findings(ArchCheck.OneProducer(), loaded, derived)
    hits = of_kind(found, :second_producer)
    symbols = Set(hit.symbol for hit in hits)
    @test symbols == Set(["again", "labeled"])
    for hit in hits
        @test hit.mod === :ProdRole
        producer_name = ev(hit, :derived)
        @test producer_name == "make_role"
        producers = ev(hit, :producers)
        @test occursin("make_role@", producers)
        marker = hit.symbol * "@"
        @test occursin(marker, producers)
    end
end

@testset "one producer, a bare formula, and a second method of the producer stay quiet" begin
    loaded = case_package("ProdQuiet", """
    struct Role
        n::Int
    end
    function make_role(n::Int)::Role
        Role(n)
    end
    make_role(n::Float64)::Role = Role(round(Int, n))
    function plain(n::Int)
        n + 1
    end
    function mirror(knots)
        1 .- reverse(knots)
    end
    """)
    derived = (Derived(loaded.mod.make_role),)
    found = declared_findings(ArchCheck.OneProducer(), loaded, derived)
    hits = of_kind(found, :second_producer)
    @test isempty(hits)
end

@testset "a mutable dict key, an IdDict, a bare memoize, and objectid are identity caches" begin
    loaded = case_package("ProdKeys", KEY_BODY)
    mod = loaded.mod
    cases = (
        (declared = Derived(mod.boxed; key = mod.box_key), problem = "identity_cache", name = ""),
        (declared = Derived(mod.id_cache; key = mod.bits_key), problem = "identity_cache", name = ""),
        (declared = Derived(mod.bare_cache; key = mod.bits_key), problem = "identity_cache", name = ""),
        (declared = Derived(mod.object_key; key = mod.bits_key), problem = "identity_cache", name = ""),
        (declared = Derived(mod.solid; key = mod.solid_key), problem = "omitted_read", name = "degree"),
        (declared = Derived(mod.count_only; key = mod.vector_key), problem = "not_isbits", name = ""),
        (declared = Derived(mod.count_only; key = mod.ptr_key), problem = "not_isbits", name = ""),
    )
    for case in cases
        found = declared_findings(ArchCheck.CacheKeys(), loaded, (case.declared,))
        hits = of_kind(found, :cache_key)
        problems = Set(ev(hit, :problem) for hit in hits)
        expected = Set([case.problem])
        @test problems == expected
        producer = case.declared.producer
        producer_name = nameof(producer)
        producer_text = string(producer_name)
        for hit in hits
            evidence_name = ev(hit, :derived)
            @test evidence_name == producer_text
            if !isempty(case.name)
                read_name = ev(hit, :name)
                @test read_name == case.name
            end
        end
    end
end

@testset "an isbits key, a hashed mutable, a typed memoize, and a covered field stay quiet" begin
    loaded = case_package("ProdKeyQuiet", KEY_BODY)
    mod = loaded.mod
    hashed = case_package("ProdHashed", HASHED_BODY)
    own = (
        Derived(mod.solid; key = mod.full_key),
        Derived(mod.count_only; key = mod.bits_key),
        Derived(mod.imm_cache; key = mod.imm_key),
        Derived(mod.typed_cache; key = mod.bits_key),
    )
    found = declared_findings(ArchCheck.CacheKeys(), loaded, own)
    hits = of_kind(found, :cache_key)
    @test isempty(hits)
    hashed_declared = Derived(hashed.mod.boxed; key = hashed.mod.box_key)
    hashed_found = declared_findings(ArchCheck.CacheKeys(), hashed, (hashed_declared,))
    hashed_hits = of_kind(hashed_found, :cache_key)
    @test isempty(hashed_hits)
end

@testset "a producer called outside the method that writes the store is unkept" begin
    loaded = case_package("ProdKept", KEPT_BODY)
    mod = loaded.mod
    kept = Derived(mod.make_role; cache = :held)
    found = declared_findings(ArchCheck.CachedCalls(), loaded, (kept,))
    hits = of_kind(found, :uncached_call)
    @test length(hits) == 1
    hit = only(hits)
    @test hit.symbol == "read_held"
    producer_name = ev(hit, :derived)
    @test producer_name == "make_role"
    site = ev(hit, :site)
    line_text = string(hit.line)
    expected_site = hit.file * ":" * line_text
    @test site == expected_site
    open_declared = Derived(mod.make_role)
    open_found = declared_findings(ArchCheck.CachedCalls(), loaded, (open_declared,))
    open_hits = of_kind(open_found, :uncached_call)
    @test isempty(open_hits)
end

@testset "the writer method is the one place a stored producer is called" begin
    loaded = case_package("ProdWriter", """
    mutable struct Owner
        held::Int
    end
    function make_role(n::Int)
        n
    end
    function keep(owner, n)
        owner.held = make_role(n)
        owner
    end
    """)
    declared = Derived(loaded.mod.make_role; cache = :held)
    found = declared_findings(ArchCheck.CachedCalls(), loaded, (declared,))
    hits = of_kind(found, :uncached_call)
    @test isempty(hits)
end

