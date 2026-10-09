# A runtime type test on a method's own parameter picks the path.

const BRANCH_BODY = """
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
"""

const BRANCH_BODIES = load_package("BranchBodies", """
include("body.jl")
""", ["body.jl" => BRANCH_BODY])

function source_line(source, fragment)
    lines = split(source, "\n"; keepempty = true)
    findfirst(line -> occursin(fragment, line), lines)
end

@testset "a runtime type test on a method's own parameter picks the path" begin
    ctx = case_context(BRANCH_BODIES)
    found = ArchCheck.run(TypeBranches(), ctx)
    @test all(finding -> finding.kind === :type_branch && finding.mod === :BranchBodies, found)
    flagged = Set([
        ("flagged_if:shape", source_line(BRANCH_BODY, "shape isa Shape")),
        ("flagged_ternary:label", source_line(BRANCH_BODY, "label isa String")),
        ("flagged_typeof:shape", source_line(BRANCH_BODY, "typeof(shape) == Shape")),
        ("logged:shape", source_line(BRANCH_BODY, "shape isa Shape && println")),
    ])
    got = Set((finding.symbol, finding.line) for finding in found)
    @test got == flagged
    @test (:type_branch => :advisory) in ArchCheck.kinds(TypeBranches())
end
