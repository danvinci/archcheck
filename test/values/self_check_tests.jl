# ArchCheck holds itself to its own gate: every check it ships, every kind promoted to error.

@testset "self-check: ArchCheck's gate passes on ArchCheck with every kind an error" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    active = Check[]
    for check in ArchCheck.CHECKS
        if check isa ArchCheck.DeadCode
            push!(active, ArchCheck.DeadCode(public_is_entry = true))
        else
            push!(active, check)
        end
    end
    checks = Tuple(active)
    every_kind = Tuple(keys(ArchCheck.severities(checks)))
    passes = try
        ArchCheck.gate(ArchCheck; report_path = report, io = IOBuffer(), error_kinds = every_kind, checks = checks)
        true
    catch err
        err isa ErrorException || rethrow()
        false
    end
    @test passes
end

@testset "an exported or public name is an entry, so dead code leaves it" begin
    mktempdir() do dir
        module_dir = joinpath(dir, "aa")
        mkpath(module_dir)
        wrapper = joinpath(module_dir, "Aa.jl")
        write(wrapper, "export shipped\npublic visible\ninclude(\"aa.jl\")")
        body = joinpath(module_dir, "aa.jl")
        write(body, "shipped() = 1\nvisible() = 2\nhidden() = 3\n")
        rank = Dict(:Aa => 1)
        dirs = Dict("aa" => :Aa)
        index = ArchCheck.build_source_index(dir, rank, dirs)
        check = ArchCheck.DeadCode(public_is_entry = true)
        dead = ArchCheck.run_checks((index = index,), (check,))
        pairs = Tuple{String,Symbol}[]
        for finding in dead
            push!(pairs, (finding.symbol, finding.kind))
        end
        @test Set(pairs) == Set([("hidden", :dead_code)])
    end
end

@testset "a callee file more than half the module reaches is shared vocabulary" begin
    mktempdir() do dir
        src = joinpath(dir, "src")
        mkpath(src)
        spine = joinpath(src, "Hub.jl")
        write(spine, "module Hub\ninclude(\"hub.jl\")\ninclude(\"c.jl\")\ninclude(\"b.jl\")\ninclude(\"a.jl\")\nend\n")
        write(joinpath(src, "hub.jl"), "hub_fn() = 1\n")
        write(joinpath(src, "c.jl"), "leaf_fn() = 1\nfrom_c() = hub_fn()\n")
        write(joinpath(src, "b.jl"), "from_b() = hub_fn()\n")
        write(joinpath(src, "a.jl"), "from_a() = hub_fn()\nstray() = leaf_fn()\n")
        rank, dir2mod = ArchCheck.package_layout(spine, :Hub)
        index = ArchCheck.build_source_index(src, rank, dir2mod)
        root = Module()
        mods = Module[]
        ctx = ArchCheck.Context(index, root, mods)
        check = ArchCheck.FileSinkable()
        found = ArchCheck.run_checks(ctx, (check,))
        records = Tuple{String,Symbol,String,String}[]
        for finding in found
            callee_file = ev(finding, :callees_in)
            using_files = ev(finding, :files_using_it)
            push!(records, (finding.symbol, finding.kind, callee_file, using_files))
        end
        @test Set(records) == Set([("stray", :file_sinkable, "c.jl", "1/4")])
    end
end

@testset "an exported check type carries a docstring" begin
    missing = String[]
    for name in names(ArchCheck)
        isdefined(ArchCheck, name) || continue
        value = getfield(ArchCheck, name)
        body = value isa UnionAll ? Base.unwrap_unionall(value) : value
        body isa DataType || continue
        body <: Check || continue
        isabstracttype(body) && continue
        binding = Base.Docs.Binding(ArchCheck, name)
        documented = haskey(Base.Docs.meta(ArchCheck), binding)
        documented && continue
        push!(missing, string(name))
    end
    sort!(missing)
    @test missing == String[]
end

@testset "self-check: every exported check is run or named inapplicable" begin
    gate_file = joinpath(@__DIR__, "..", "self_gate.jl")
    if !isdefined(@__MODULE__, :self_checks)
        include(gate_file)
    end
    held = Set{Any}()
    for pair in NOT_APPLICABLE
        push!(held, pair[1])
    end
    missing = String[]
    for name in names(ArchCheck)
        value = getfield(ArchCheck, name)
        body = value isa UnionAll ? Base.unwrap_unionall(value) : value
        body isa DataType || continue
        body <: Check || continue
        isabstracttype(body) && continue
        ran = false
        for check in self_checks()
            if check isa value
                ran = true
            end
        end
        ran && continue
        value in held && continue
        push!(missing, string(name))
    end
    sort!(missing)
    @test missing == String[]
end
