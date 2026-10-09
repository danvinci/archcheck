# File-sinkable at method grain. The name graph merges every method of a function into one node;
# a method graph judges each method on the callees inference resolved for it.

function write_sink_tree(dir, files)
    module_dir = joinpath(dir, "m")
    mkpath(module_dir)
    for pair in files
        name = pair.first
        body = pair.second
        path = joinpath(module_dir, name)
        write(path, body)
    end
    dir
end

function included_file(line)
    trimmed = strip(line)
    matched = match(r"^include\(\"([^\"]+)\"\)$", trimmed)
    isnothing(matched) && return nothing
    matched.captures[1]
end

function load_sink_module(dir, modname)
    module_dir = joinpath(dir, "m")
    lines = String["module $modname"]
    entry = joinpath(module_dir, "M.jl")
    for line in eachline(entry)
        name = included_file(line)
        isnothing(name) && continue
        push!(lines, line)
    end
    push!(lines, "end")
    loader = joinpath(module_dir, "loader.jl")
    text = join(lines, "\n")
    write(loader, text)
    Base.invokelatest(Base.include, Main, loader)
end

function sink_index(dir)
    rank = Dict(:M => 1)
    dirs = Dict("m" => :M)
    build_source_index(dir, rank, dirs)
end

function sink_methods(loaded, specs)
    entries = []
    for spec in specs
        name = spec[1]
        argtype = spec[2]
        func = Base.invokelatest(getfield, loaded, name)
        push!(entries, (func, argtype))
    end
    Base.invokelatest(ArchCheck.method_graph, entries, (loaded,))
end

function finding_by_callee(findings, callee_file)
    matched = Finding[]
    for finding in findings
        callee = ev(finding, :callees_in)
        callee == callee_file || continue
        push!(matched, finding)
    end
    only(matched)
end

const SINK_SPLIT = [
    "M.jl" => "include(\"low_a.jl\")\ninclude(\"low_b.jl\")\ninclude(\"left.jl\")\ninclude(\"right.jl\")\n",
    "low_a.jl" => "alpha(x::Int) = x\n",
    "low_b.jl" => "beta(x::String) = x\n",
    "left.jl" => "split(x::Int) = alpha(x)\n",
    "right.jl" => "split(x::String) = beta(x)\n",
]

const SINK_HUB = [
    "M.jl" => "include(\"low.jl\")\ninclude(\"a.jl\")\ninclude(\"b.jl\")\n",
    "low.jl" => "leaf(x::Int) = x\n",
    "a.jl" => "from_a(x::Int) = leaf(x)\n",
    "b.jl" => "from_b(x::Int) = leaf(x)\n",
]

const SINK_PLACED = [
    "M.jl" => "include(\"low.jl\")\ninclude(\"home.jl\")\ninclude(\"away.jl\")\ninclude(\"pad_a.jl\")\ninclude(\"pad_b.jl\")\n",
    "low.jl" => "leaf(x::Int) = x\nleaf(x::String) = x\n",
    "home.jl" => "place(x::Int) = leaf(x)\nuses(x::Int) = place(x)\n",
    "away.jl" => "place(x::String) = leaf(x)\n",
    "pad_a.jl" => "pad_a(x::Int) = x\n",
    "pad_b.jl" => "pad_b(x::Int) = x\n",
]

@testset "method grain: two methods in two files keep their own callee files" begin
    mktempdir() do dir
        write_sink_tree(dir, SINK_SPLIT)
        index = sink_index(dir)
        graph = build_call_graph(index, :M)
        named = check_file_sinkable(graph, NO_SITES)
        @test isempty(named)
        loaded = load_sink_module(dir, :SinkSplit)
        specs = [(:split, Tuple{Int}), (:split, Tuple{String})]
        methods = sink_methods(loaded, specs)
        with_nothing = check_file_sinkable(graph, NO_SITES, nothing, index.repo)
        @test isempty(with_nothing)
        found = check_file_sinkable(graph, NO_SITES, methods, index.repo)
        @test length(found) == 2
        left = finding_by_callee(found, "low_a.jl")
        right = finding_by_callee(found, "low_b.jl")
        @test left.symbol == "split"
        @test right.symbol == "split"
        @test endswith(left.file, "left.jl")
        @test endswith(right.file, "right.jl")
        @test left.line == 1
        @test ev(left, :callers_in_own_file) == "0"
        @test left.kind === :file_sinkable
    end
end

@testset "method grain: a callee file most files reach is shared vocabulary" begin
    mktempdir() do dir
        write_sink_tree(dir, SINK_HUB)
        index = sink_index(dir)
        graph = build_call_graph(index, :M)
        named = check_file_sinkable(graph, NO_SITES)
        @test isempty(named)
        loaded = load_sink_module(dir, :SinkHub)
        specs = [(:from_a, Tuple{Int}), (:from_b, Tuple{Int})]
        methods = sink_methods(loaded, specs)
        found = check_file_sinkable(graph, NO_SITES, methods, index.repo)
        @test isempty(found)
    end
end

@testset "method grain: a caller beside one method leaves the other method sinkable" begin
    mktempdir() do dir
        write_sink_tree(dir, SINK_PLACED)
        index = sink_index(dir)
        graph = build_call_graph(index, :M)
        named = check_file_sinkable(graph, NO_SITES)
        @test isempty(named)
        loaded = load_sink_module(dir, :SinkPlaced)
        specs = [(:place, Tuple{Int}), (:place, Tuple{String}), (:uses, Tuple{Int})]
        methods = sink_methods(loaded, specs)
        found = check_file_sinkable(graph, NO_SITES, methods, index.repo)
        away = only(found)
        @test away.symbol == "place"
        @test endswith(away.file, "away.jl")
        @test away.line == 1
        @test ev(away, :callees_in) == "low.jl"
        @test ev(away, :callers_in_own_file) == "0"
    end
end
