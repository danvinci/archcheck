# A runtime type test on a method's own parameter picks the path.
@testset "type branch: a runtime type test on a method's own parameter picks the path" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), """
            struct Shape end
            function flagged_if(shape, scale)
                if shape isa Shape
                    scale
                else
                    -scale
                end
            end
            flagged_ternary(shape; label = "") = label isa String ? label : shape
            function flagged_typeof(shape)
                if isempty(shape)
                    0
                elseif typeof(shape) == Shape
                    1
                end
            end
            guarded(shape) = shape isa Shape || throw(ArgumentError("not a shape"))
            function local_test(shapes)
                part = first(shapes)
                part isa Shape ? 1 : 2
            end
            filtered(shape, shapes) = filter(shape -> shape isa Shape && isvalid(shape), shapes)
            function validated(shape)
                (shape isa Shape && isvalid(shape)) || throw(ArgumentError("not a valid shape"))
                shape
            end
            is_plain(value) = value isa Real && !(value isa Bool)
            function logged(shape)
                shape isa Shape && println(shape)
                nothing
            end
            """)
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = ArchCheck.build_source_index(dir, rank, dir2mod)
        found = ArchCheck.run_checks((index = index,), (ArchCheck.TypeBranches(),))
        @test all(f -> f.kind === :type_branch && f.mod === :M, found)
        # `&&` and `||` pick a path only as a statement; as an operand or a result they compute a Bool
        flagged = Set([("flagged_if:shape", 3), ("flagged_ternary:label", 9), ("flagged_typeof:shape", 13),
                       ("logged:shape", 29)])
        @test Set((f.symbol, f.line) for f in found) == flagged
    end
    @test default_severity()[:type_branch] === :advisory
end
