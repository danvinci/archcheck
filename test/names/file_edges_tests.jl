# A file reaches only files the include order has already loaded.

function file_backedges(case)
    ctx = case_context(case)
    ArchCheck.run(FileBackEdges(), ctx)
end

function edge_rows(found)
    rows = Tuple{String,String,String}[]
    for finding in found
        from_name = basename(finding.file)
        to_name = basename(finding.symbol)
        via = ev(finding, :via)
        push!(rows, (from_name, to_name, via))
    end
    sort!(rows)
end

const QUALIFIED_INDEX = load_package("QualifiedIndex", """
include("types.jl")
include("extension.jl")
include("late.jl")
""", [
    "types.jl" => "struct Shape{T} end\nwrap(shape) = Some(shape)\n",
    "extension.jl" => """
    function Base.getindex(shape::Shape{T}, helper, index = default_index()) where {T}
        helper(index)
        nested(value) = leaf(value)
        nested(shape)
    end
    """,
    "late.jl" => "default_index() = 1\nleaf(value) = value\nhelper() = 2\nSome{T}(shape::Shape{T}) where {T} = shape\n",
])

const IMPORTED_BREAKS = load_package("ImportedBreaks", """
include("iface/Iface.jl")
using .Iface
include("lofts/Lofts.jl")
using .Lofts
""", [
    "iface/Iface.jl" => "module Iface\ninclude(\"verbs.jl\")\nend\n",
    "iface/verbs.jl" => "function breaks end\nfunction splits end\n",
    "lofts/Lofts.jl" => """
    module Lofts
    import ..Iface: breaks, splits as divide
    import Base: show
    include("early.jl")
    include("cut.jl")
    include("late.jl")
    end
    """,
    "lofts/early.jl" => "measure(x) = breaks(x)\npart(x) = divide(x)\ndescribe(io, x) = show(io, x)\n",
    "lofts/cut.jl" => """
    struct Cut end
    breaks(c::Cut) = refine(c)
    divide(c::Cut) = c
    show(io::IO, c::Cut) = print(io, c)
    """,
    "lofts/late.jl" => "refine(c) = c\n",
])

const CONSTRUCTOR_LOCAL = load_package("ConstructorLocal", """
include("a.jl")
include("b.jl")
""", [
    "a.jl" => """
    struct Holder
        xs::Int
    end
    function Holder()
        helper()
    end
    function paint(faces)
        items = Int[]
        helper = length(items)
        helper
    end
    """,
    "b.jl" => "items() = 1\nhelper() = 1\n",
])

const WRAPPER_CALL = load_package("WrapperCall", """
wrapper_fn() = 1
include("early.jl")
include("late.jl")
""", [
    "early.jl" => "climb() = wrapper_fn() + late_fn()\n",
    "late.jl" => "late_fn() = 1\n",
])

# Each method below reads a name the load binds at one place: before the method's file is done, or after it.
const LATE_READS = load_package("LateReads", """
early_entry() = late_name()
include("decl.jl")
include("host.jl")
include("child/Child.jl")
using .Child
include("late.jl")
after_entry() = late_name()
function load_extra()
    include("extra.jl")
end
tail_name() = 1
""", [
    "decl.jl" => """
    function shape_of end
    @static if VERSION < v"1.0"
        import Base: setindex
    end
    """,
    "host.jl" => """
    include("part.jl")
    measure(x) = shape_of(x) + part_size(x)
    grab(xs) = Base.first(xs)
    own() = LateReads.late_name()
    swap(x) = setindex(x, 1, 1)
    display_of(io, x) = show(io, x)
    call_child() = Child.go()
    @static if VERSION < v"1.0"
        stale() = late_name()
    end
    """,
    "part.jl" => "part_size(x) = 1\n",
    "child/Child.jl" => "module Child\ngo() = 1\nend\n",
    "late.jl" => """
    import Base: setindex, show
    late_name() = 1
    first(x::Int) = x
    shape_of(x::Int) = x
    tail_reader() = tail_name()
    """,
])

@testset "a method reads a name late exactly when the load binds it after the method's file is done" begin
    found = file_backedges(LATE_READS)
    rows = edge_rows(found)
    @test rows == [("LateReads.jl", "late.jl", "early_entry"), ("host.jl", "Child.jl", "call_child"),
                   ("host.jl", "late.jl", "own swap")]
    names_read = Set(ev(finding, :names) for finding in found)
    @test "late_name setindex" in names_read
end

@testset "a method on another module's function or type keeps its calls' edges and gives the name no file" begin
    found = file_backedges(QUALIFIED_INDEX)
    rows = edge_rows(found)
    @test rows == [("extension.jl", "late.jl", "Base.getindex")]
    ctx = case_context(QUALIFIED_INDEX)
    dead = ArchCheck.run(DeadCode(), ctx)
    dead_names = Set(finding.symbol for finding in dead)
    @test "helper" in dead_names
    @test !("leaf" in dead_names)
    @test !("default_index" in dead_names)
end

@testset "an imported verb's method carries the edge of the file that defines the method" begin
    found = file_backedges(IMPORTED_BREAKS)
    rows = edge_rows(found)
    @test rows == [("cut.jl", "late.jl", "breaks")]
end

@testset "a constructor call keeps its callee and a same-named local does not" begin
    found = file_backedges(CONSTRUCTOR_LOCAL)
    rows = edge_rows(found)
    @test rows == [("a.jl", "b.jl", "Holder")]
    ctx = case_context(CONSTRUCTOR_LOCAL)
    dead = ArchCheck.run(DeadCode(), ctx)
    dead_names = Set(finding.symbol for finding in dead)
    @test "items" in dead_names
    @test !("helper" in dead_names)
end

@testset "a call into an unranked wrapper function is not a file back edge" begin
    found = file_backedges(WRAPPER_CALL)
    rows = edge_rows(found)
    @test rows == [("early.jl", "late.jl", "climb")]
end

@testset "file back edges match the generated include order" begin
    for seed in 1:40
        rng = Xoshiro(seed)
        spec = random_module(rng)
        case_name = "EdgeOrder$seed"
        case = load_package(case_name, spec.spine, spec.sources)
        found = file_backedges(case)
        rows = edge_rows(found)
        got = Set((from, to) for (from, to, _) in rows)
        expected = Set((from, to) for (from, to) in spec.truth if from != to && spec.rank[to] >= spec.rank[from])
        @test got == expected
    end
end
