# A method nested in another method's body is its own form.
# Calls written in that body stay on the enclosing method.

function line_holding(source, text)
    lines = split(source, "\n")
    for (index, line) in enumerate(lines)
        occursin(text, line) && return index
    end
    0
end

function callee_names(scan, site)
    calls = scan.callsites[site]
    names = Symbol[]
    for call in calls
        push!(names, call.callee)
    end
    names
end

function assert_nested_form(source, outer_text, inner_text)
    scan = scan_defs(source)
    outer_line = line_holding(source, outer_text)
    inner_line = line_holding(source, inner_text)
    outer_site = MethodSite(:outer, outer_line)
    inner_site = MethodSite(:inner, inner_line)
    @test haskey(scan.forms, outer_site)
    form = scan.forms[inner_site]
    body = ArchCheck.method_body(form)
    @test !isnothing(body)
    names = callee_names(scan, outer_site)
    @test :g in names
    @test :inner in names
    @test !haskey(scan.callsites, inner_site)
    @test :g in scan.refs[:outer]
end

@testset "a nested method is recorded on its own site" begin
    long_source = "function outer(x)\n    function inner(y)\n        g(y)\n    end\n    inner(x)\nend\n"
    assert_nested_form(long_source, "function outer", "function inner")
    short_source = "function outer(x)\n    inner(y) = g(y)\n    inner(x)\nend\n"
    assert_nested_form(short_source, "function outer", "inner(y)")
end
