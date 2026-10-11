# A local a closure captures and assigns in more than one place. Lowering boxes that local,
# which erases its type and the type of every value read from it.

has_box(stmt::GlobalRef) = stmt.mod === Core && stmt.name === :Box
has_box(stmt::Expr) = any(has_box, stmt.args)
has_box(@nospecialize(::Any)) = false

# Lowering emits one box allocation per captured local it boxes. A `@generated` method holds no lowered body of
# its own; its generator is a method of its own, read where it is defined.
function count_boxes(method::Method)
    isdefined(method, :source) || return 0
    lowered = Base.uncompressed_ast(method)
    lowered isa Core.CodeInfo || return 0
    count(has_box, lowered.code)
end

# The function whose body runs at compile time to write a `@generated` method's code; nothing for a generator
# Julia's lowering did not write.
generator_function(stub::Core.GeneratedFunctionStub) = stub.gen
generator_function(@nospecialize(::Any)) = nothing

# Each generator function among the defined methods, keyed to the `@generated` method it writes code for.
function generated_methods(defined)
    written_for = IdDict{Any,Method}()
    for method in defined
        isdefined(method, :generator) || continue
        generator = generator_function(method.generator)
        isnothing(generator) && continue
        written_for[generator] = method
    end
    written_for
end

# The method whose source holds a boxing body, and when that body runs. Lowering records a generator at no file,
# so its body is reported at the `@generated` method it belongs to.
function written_body(method::Method, written_for)
    value = method_function(method)
    generated = isnothing(value) ? nothing : get(written_for, value, nothing)
    isnothing(generated) && return (method, "call time")
    (generated, "compile time")
end

# Every method the package defines, a method on another package's function included.
function check_boxed_captures(defined; recorded::RecordedPaths)
    findings = Finding[]
    seen = Set{Tuple{String,Int,String}}()
    written_for = generated_methods(defined)
    for method in defined
        boxes = count_boxes(method)
        boxes == 0 && continue
        written, runs_at = written_body(method, written_for)
        file, line = method_site(written, recorded)
        key = (file, line, runs_at)
        key in seen && continue
        push!(seen, key)
        symbol = written_name(written.name)
        detail = "a captured local is assigned in more than one place, so lowering boxes it"
        evidence = [:boxes => string(boxes), :runs_at => runs_at]
        owner = module_key(written.module)
        finding = Finding(owner, :boxed_capture, file, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
