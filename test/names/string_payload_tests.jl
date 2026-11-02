# A `Dict{String,V}` with a value type other than String carries a record under string keys. A String-to-String map,
# another key type, and a Dict with one parameter or none are no such record

const PAYLOADS = load_package("Payloads", """
include("records.jl")
""", [
    "records.jl" => """
    built() = Dict{String,Float64}()
    stored(record::Dict{String,Vector{Int}}) = length(record)
    qualified() = Base.Dict{String,Int}()
    const TABLE = Dict{String,Any}()
    settings() = Dict{String,String}()
    keyed() = Dict{Symbol,Float64}()
    loose() = Dict{String}()
    plain() = Dict("a" => 1)
    """,
    "../scripts/tool.jl" => """
    report() = Dict{String,Int}()
    """,
])

@testset "a string-keyed Dict of non-String values is a finding, in src/ and in the directories named" begin
    ctx = case_context(PAYLOADS)
    found = ArchCheck.run(StringPayloads(), ctx)
    rows = evidence_rows(found, :type)
    @test rows == [(:string_payload, "", "Dict{String,Any}"),
                   (:string_payload, "built", "Dict{String,Float64}"),
                   (:string_payload, "qualified", "Base.Dict{String,Int}"),
                   (:string_payload, "stored", "Dict{String,Vector{Int}}")]
    with_scripts = ArchCheck.run(StringPayloads(dirs = ["scripts"]), ctx)
    outside = [(f.mod, f.file, f.symbol) for f in with_scripts if !startswith(f.file, "src/")]
    @test outside == [(:Entry, "scripts/tool.jl", "report")]
    @test (:string_payload => :advisory) in ArchCheck.kinds(StringPayloads())
end
