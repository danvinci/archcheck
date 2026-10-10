# A local a closure captures and assigns in more than one place. Lowering boxes that local,
# which erases its type and the type of every value read from it.

has_box(stmt::GlobalRef) = stmt.mod === Core && stmt.name === :Box
has_box(stmt::Expr) = any(has_box, stmt.args)
has_box(@nospecialize(::Any)) = false

# Lowering emits one box allocation per captured local it boxes.
function count_boxes(method::Method)
    lowered = try
        Base.uncompressed_ast(method)
    catch
        return 0
    end
    lowered isa Core.CodeInfo || return 0
    count(has_box, lowered.code)
end

# Every method the package defines, a method on another package's function included.
function check_boxed_captures(defined; repo)
    findings = Finding[]
    seen = Set{Tuple{String,Int}}()
    for method in defined
        boxes = count_boxes(method)
        boxes == 0 && continue
        key = method_site(method, repo)
        key in seen && continue
        push!(seen, key)
        file, line = key
        symbol = written_name(method.name)
        detail = "a captured local is assigned in more than one place, so lowering boxes it"
        evidence = [:boxes => string(boxes)]
        owner = module_key(method.module)
        finding = Finding(owner, :boxed_capture, file, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
