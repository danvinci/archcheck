# Declared derived values: one producer, a key that names every input, calls kept on the cache.

const SECOND_PRODUCER = load_package("SecondProducer", """
    struct Made
        n::Int
    end
    function make_value(n::Int)
        Made(n)
    end
    function again(n::Int)
        Made(n + 1)
    end
    function labeled(n::Int)::Made
        n
    end
    function plain(n::Int)
        n + 1
    end
    make_value(n::Float64) = Made(round(Int, n))
    function mirror(knots)
        1 .- reverse(knots)
    end
    """)

const QUIET_PRODUCER = load_package("QuietProducer", """
    struct Made
        n::Int
    end
    function make_value(n::Int)::Made
        Made(n)
    end
    make_value(n::Float64)::Made = Made(round(Int, n))
    function plain(n::Int)
        n + 1
    end
    function mirror(knots)
        1 .- reverse(knots)
    end
    """)

const KEY_CASES = load_package("KeyCases", """
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
    """)

const HASHED_BOX = load_package("HashedBox", """
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
    """)

const UNCACHED_CALL = load_package("UncachedCall", """
    mutable struct Owner
        held::Int
    end
    function make_value(n::Int)
        n
    end
    function keep(owner, n)
        owner.held = make_value(n)
        owner
    end
    function read_held(owner, n)
        make_value(n)
        owner.held
    end
    """)

const CACHED_WRITER = load_package("CachedWriter", """
    mutable struct Owner
        held::Int
    end
    function make_value(n::Int)
        n
    end
    function keep(owner, n)
        owner.held = make_value(n)
        owner
    end
    """)

function declared_findings(check, case, derived)
    ArchCheck.run(check, case_context(case; derived))
end

@testset "a second method that builds the declared value is a second producer" begin
    declared = (Derived(SECOND_PRODUCER.pkg.make_value),)
    found = declared_findings(OneProducer(), SECOND_PRODUCER, declared)
    rows = evidence_rows(found, :derived)
    @test rows == [
        (:second_producer, "again", "make_value"),
        (:second_producer, "labeled", "make_value"),
    ]
    producer_rows = evidence_rows(found, :producers)
    for row in producer_rows
        producers = row[3]
        @test occursin("make_value@", producers)
        marker = row[2] * "@"
        @test occursin(marker, producers)
    end
end

@testset "one producer, a bare formula, and a second method of the producer stay quiet" begin
    declared = (Derived(QUIET_PRODUCER.pkg.make_value),)
    found = declared_findings(OneProducer(), QUIET_PRODUCER, declared)
    @test isempty(found)
end

@testset "a mutable dict key, an IdDict, a bare memoize, and objectid are identity caches" begin
    mod = KEY_CASES.pkg
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
        declared = (case.declared,)
        found = declared_findings(CacheKeys(), KEY_CASES, declared)
        rows = evidence_rows(found, :problem)
        problems = Set{String}()
        for row in rows
            push!(problems, row[3])
        end
        @test problems == Set([case.problem])
        producer = case.declared.producer
        producer_name = nameof(producer)
        producer_text = string(producer_name)
        derived_rows = evidence_rows(found, :derived)
        for derived_row in derived_rows
            @test derived_row[3] == producer_text
        end
        if !isempty(case.name)
            name_rows = evidence_rows(found, :name)
            name_row = only(name_rows)
            @test name_row[3] == case.name
        end
    end
end

@testset "an isbits key, a hashed mutable, a typed memoize, and a covered field stay quiet" begin
    mod = KEY_CASES.pkg
    own = (
        Derived(mod.solid; key = mod.full_key),
        Derived(mod.count_only; key = mod.bits_key),
        Derived(mod.imm_cache; key = mod.imm_key),
        Derived(mod.typed_cache; key = mod.bits_key),
    )
    found = declared_findings(CacheKeys(), KEY_CASES, own)
    @test isempty(found)
    hashed_declared = (Derived(HASHED_BOX.pkg.boxed; key = HASHED_BOX.pkg.box_key),)
    hashed_found = declared_findings(CacheKeys(), HASHED_BOX, hashed_declared)
    @test isempty(hashed_found)
end

@testset "a producer called outside the method that writes the store is unkept" begin
    mod = UNCACHED_CALL.pkg
    kept = (Derived(mod.make_value; cache = :held),)
    found = declared_findings(CachedCalls(), UNCACHED_CALL, kept)
    rows = evidence_rows(found, :derived, :site)
    hit = only(found)
    line_text = string(hit.line)
    site = hit.file * ":" * line_text
    @test rows == [(:uncached_call, "read_held", "make_value", site)]
    open_declared = (Derived(mod.make_value),)
    open_found = declared_findings(CachedCalls(), UNCACHED_CALL, open_declared)
    @test isempty(open_found)
end

@testset "the writer method is the one place a stored producer is called" begin
    declared = (Derived(CACHED_WRITER.pkg.make_value; cache = :held),)
    found = declared_findings(CachedCalls(), CACHED_WRITER, declared)
    @test isempty(found)
end
