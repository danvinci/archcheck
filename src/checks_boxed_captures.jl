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

function check_boxed_captures(mods; repo)
    findings = Finding[]
    seen = Set{Tuple{String,Int}}()
    for mod in mods
        for name in names(mod; all = true)
            is_self = name === nameof(mod)
            is_builtin = name in (:eval, :include)
            (is_self || is_builtin) && continue
            isdefined(mod, name) || continue
            value = getproperty(mod, name)
            value isa Function || continue
            for method in methods(value)
                method.module === mod || continue
                boxes = count_boxes(method)
                boxes == 0 && continue
                key = method_site(method, repo)
                key in seen && continue
                push!(seen, key)
                file, line = key
                symbol = written_name(name)
                detail = "a captured local is assigned in more than one place, so lowering boxes it"
                evidence = [:boxes => string(boxes)]
                owner = module_key(mod)
                finding = Finding(owner, :boxed_capture, file, symbol, line, detail, evidence)
                push!(findings, finding)
            end
        end
    end
    findings
end
