# A text or file read through the json package with no target type is a finding, by a bare or a qualified name. A
# typed read, a splat, a read through Base or another module, and a package with its own module of that name are none

const JSON_PROJECT = """
[deps]
JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
"""

const PARSES = load_package("Parses", """
import JSON
using JSON: parsefile
include("other.jl")
include("reads.jl")
""", [
    "other.jl" => """
    module Other
    parse(x) = x
    end
    """,
    "reads.jl" => """
    read_text(text) = JSON.parse(text)
    read_file(path) = JSON.parsefile(path)
    read_bare(path) = parsefile(path)
    read_keyword(text) = JSON.parse(text; dicttype = Dict{String,Any})
    read_lines(lines) = JSON.parse.(lines)
    read_typed(text) = JSON.parse(text, Dict{String,Int})
    read_typed_file(path) = JSON.parsefile(path, Vector{Int})
    read_splat(parts) = JSON.parse(parts...)
    read_base(text) = parse(Int, text)
    read_other(text) = Other.parse(text)
    function read_local(text)
        JSON = Other
        JSON.parse(text)
    end
    """,
], JSON_PROJECT)

const OWN_JSON = load_package("OwnJson", """
module JSON
parse(x) = x
end
read_text(text) = JSON.parse(text)
""")

@testset "a json package parse with no target type is a finding, a typed parse or another parse none" begin
    ctx = case_context(PARSES)
    found = ArchCheck.run(UntypedParses(), ctx)
    rows = evidence_rows(found, :call)
    @test rows == [(:untyped_parse, "read_bare", "parsefile(path)"),
                   (:untyped_parse, "read_file", "JSON.parsefile(path)"),
                   (:untyped_parse, "read_keyword", "JSON.parse(text; dicttype = Dict{String,Any})"),
                   (:untyped_parse, "read_lines", "JSON.parse.(lines)"),
                   (:untyped_parse, "read_text", "JSON.parse(text)")]
    text = only(finding for finding in found if finding.symbol == "read_text")
    @test (text.file, text.line) == (joinpath("src", "reads.jl"), 1)
    own = case_context(OWN_JSON)
    @test isempty(ArchCheck.run(UntypedParses(), own))
    @test (:untyped_parse => :advisory) in ArchCheck.kinds(UntypedParses())
end
