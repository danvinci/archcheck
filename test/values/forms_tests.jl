# A method nested in another method's body is its own form.
# Calls written in that body stay on the enclosing method.

const FORMS_LONG = load_package("FormsLong", """
function outer(x)
    function inner(y)
        g(y)
    end
    inner(x)
end
""")

const FORMS_SHORT = load_package("FormsShort", """
function outer(x)
    inner(y) = g(y)
    inner(x)
end
""")

@testset "a nested method is its own form, and the calls in its body stay on the enclosing method" begin
    for case in (FORMS_LONG, FORMS_SHORT)
        ctx = case_context(case)
        spine_name = string(nameof(case.pkg)) * ".jl"
        scan = file_scans(ctx)[spine_name]
        outer = only(site for site in keys(scan.forms) if site.name === :outer)
        inner = only(site for site in keys(scan.forms) if site.name === :inner)
        callees = [call.callee for call in scan.callsites[outer]]
        @test :g in callees
        @test :inner in callees
        @test !haskey(scan.callsites, inner)
        @test :g in scan.refs[:outer]
    end
end
