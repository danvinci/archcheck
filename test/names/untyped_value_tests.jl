# An empty container with no element type is built on Any; a typed or filled container and an explicit Any are not

const UNTYPED = load_package("Untyped", """
include("values.jl")
""", [
    "values.jl" => """
    empty_list() = []
    empty_dict() = Dict()
    empty_set() = Set()
    empty_identity() = IdDict()
    wide(x::Any) = x
    boxes() = Vector{Any}()
    typed_list() = Int[]
    typed_dict() = Dict{Symbol,Int}()
    filled_set() = Set([1])
    filled_dict() = Dict(:a => 1)
    filled_list() = [1, 2]
    """,
    "../scripts/tool.jl" => """
    scratch() = []
    typed_scratch() = String[]
    """,
])

@testset "an empty untyped container is a finding, in src/ and in the directories named" begin
    ctx = case_context(UNTYPED)
    found = ArchCheck.run(UntypedValues(), ctx)
    rows = evidence_rows(found, :form)
    @test rows == [(:untyped_value, "empty_dict", "Dict()"),
                   (:untyped_value, "empty_identity", "IdDict()"),
                   (:untyped_value, "empty_list", "[]"),
                   (:untyped_value, "empty_set", "Set()")]
    with_scripts = ArchCheck.run(UntypedValues(dirs = ["scripts"]), ctx)
    outside = [(f.mod, f.file, f.symbol) for f in with_scripts if !startswith(f.file, "src/")]
    @test outside == [(:Entry, "scripts/tool.jl", "scratch")]
    scripts = joinpath(UNTYPED.root, "scripts")
    entry_ctx = case_context(UNTYPED; entry_dirs = [scripts])
    from_entry = ArchCheck.run(UntypedValues(dirs = ["scripts"]), entry_ctx)
    @test length(from_entry) == length(with_scripts)
    @test (:untyped_value => :advisory) in ArchCheck.kinds(UntypedValues())
end
