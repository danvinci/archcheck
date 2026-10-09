# A wide anonymous tuple return is a finding. A named tuple is a record.
@testset "tuple return (the unnamed data layer)" begin
    sc = scan_defs("""
    three() = (a, b, c)
    pair() = (a, b)
    named() = (x = a, y = b, z = c)
    blocky() = begin; q = 1; return (a, b, c, d); end
    """)
    # the scan records raw arity. The check owns the threshold.
    @test sc.tupletail[:blocky] == 4           # through a block and an explicit return
    @test !haskey(sc.tupletail, :named)        # a NamedTuple names its slots - not anonymous

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "wide() = (a, b, c)\nnarrow() = (a, b)")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        tup = only(check_tuple_returns(index))
        @test tup.symbol == "wide" && tup.kind === :tuple_return
        @test tup.line == 1 && ev(tup, :slots) == "3"
    end
end
