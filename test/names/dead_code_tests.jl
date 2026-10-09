# An uncalled definition is dead. A script entry keeps a name alive; a test entry does not.

@testset "dead-code (static, JuliaSyntax)" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "scripts"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "keep() = 1\ngone() = 2\nentry() = keep()")
        entry_dir = joinpath(dir, "scripts")
        write(joinpath(entry_dir, "run.jl"), "entry()")
        rank = Dict(:Aa => 1)
        dirs = Dict("aa" => :Aa)
        index = build_source_index(dir, rank, dirs; entry_dirs = [entry_dir])
        dead = check_dead_code_static(index)
        syms = Set(f.symbol for f in dead)
        @test "gone" in syms                        # never called, not external -> dead
        @test !("keep" in syms) && !("entry" in syms)   # called / external
        @test all(f -> f.kind === :dead_code, dead)
    end
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "owner(x = helper()) = x\nhelper() = 1")
        rank = Dict(:Aa => 1)
        dir2mod = Dict("aa" => :Aa)
        index = build_source_index(dir, rank, dir2mod)
        dead = Set(f.symbol for f in check_dead_code_static(index))
        @test !("helper" in dead)
        @test "owner" in dead
    end
    # entry-dir names keep a def alive: the same tree is dead without them, live with them
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "scripts"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "shipped() = 1")
        entry = joinpath(dir, "scripts")
        write(joinpath(entry, "run.jl"), "shipped()")

        lonely = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa))
        @test "shipped" in Set(f.symbol for f in check_dead_code_static(lonely))

        withentry = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa); entry_dirs = [entry])
        @test isempty(check_dead_code_static(withentry))
    end
    # a test/ entry dir does not keep a def alive: nothing production runs reaches it there
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "tested() = 1")
        entry = joinpath(dir, "test")
        write(joinpath(entry, "runtests.jl"), "tested()")

        index = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa); entry_dirs = [entry])
        @test "tested" in Set(f.symbol for f in check_dead_code_static(index))
    end
    # a def's own export line is not a use: exported with no caller is still dead
    mktempdir() do dir
        mkpath(joinpath(dir, "bb"))
        write(joinpath(dir, "bb", "Bb.jl"), "export uncalled\ninclude(\"impl.jl\")")
        write(joinpath(dir, "bb", "impl.jl"), "uncalled() = 1")
        index = build_source_index(dir, Dict(:Bb => 1), Dict("bb" => :Bb))
        @test "uncalled" in Set(f.symbol for f in check_dead_code_static(index))
    end
    # a qualified call from another module counts as the use dead-code looks for
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "cc"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"defs.jl\")")
        write(joinpath(dir, "aa", "defs.jl"), "helper() = 1")
        write(joinpath(dir, "cc", "Cc.jl"), "include(\"caller.jl\")")
        write(joinpath(dir, "cc", "caller.jl"), "user() = Aa.helper()")
        rank = Dict(:Aa => 1, :Cc => 2)
        dir2mod = Dict("aa" => :Aa, "cc" => :Cc)
        index = build_source_index(dir, rank, dir2mod)
        dead = Set(f.symbol for f in check_dead_code_static(index))
        @test !("helper" in dead)
    end
end
