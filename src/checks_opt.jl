# Opt analysis: a corpus of concrete calls, each judged on Julia's own inference by the rules of JET's `report_opt`
# (JET src/analyzers/optanalyzer.jl)

"""One concrete call in the opt-analysis corpus: a callable and its argument types as a `Tuple` type."""
struct OptEntry{F, A<:Tuple}
    f::F                                # the callable the corpus names: a function or a type
    argtypes::Type{A}                   # concrete argument types, one specialization
    symbol::String                      # Finding.symbol; includes the signature so Dual and Float64 stay distinct
end

function entry_symbol(f, ::Type{T}) where {T <: Tuple}
    args = join(("::" * type_text(p) for p in T.parameters), ", ")
    "$(nameof(f))($args)"
end

function OptEntry(f::F, argtypes::Type{A}) where {F, A<:Tuple}
    symbol = entry_symbol(f, argtypes)
    OptEntry{F,A}(f, argtypes, symbol)
end

"""Configured through `gate(...; checks)` with a corpus of concrete calls. A call whose inferred code dispatches at runtime, or boxes a captured local, is a finding. An empty corpus reports nothing."""
struct OptAnalysis{E} <: Check
    entries::Vector{E}                  # corpus calls, each one specialization
end
OptAnalysis() = OptAnalysis(OptEntry[])

function entry_location(entry::OptEntry, recorded::RecordedPaths)
    m = which(entry.f, entry.argtypes)
    mod = module_key(m.module)
    file, line = method_site(m, recorded)
    (mod = mod, file = file, line = line)
end

# Each frame inference reaches from the entry, inferred again as its own frame. A judged frame counts each live call its
# optimized code leaves to runtime dispatch and each local its typed code boxes; a constant result counts neither
function opt_counts(entry::OptEntry, modules, interp)
    root = method_instance_at(entry.f, entry.argtypes)
    pending = Core.MethodInstance[root]
    seen = Base.IdSet{Core.MethodInstance}()
    dispatches = 0
    boxes = 0
    while !isempty(pending)   # bounded: each instance is judged once, and inference reaches finitely many
        instance = pop!(pending)
        instance in seen && continue
        push!(seen, instance)
        frame = inference_frame(instance, interp)
        isnothing(frame) && continue
        append!(pending, called_instances(frame))
        is_judged(instance, root, modules) || continue
        # The optimizer rewrites `frame.src` in place
        unoptimized = copy(frame.src)
        code = optimized_code(frame, interp)
        isnothing(code) && continue
        boxes += count_boxes(unoptimized)
        dispatches += count_dispatches(code, instance)
    end
    (; dispatches, boxes)
end

# A frame of a package module whose instance is the one Julia compiles for its signature, or the entry's own
function is_judged(instance::Core.MethodInstance, root::Core.MethodInstance, modules)
    method = instance.def
    method isa Method && method.module in modules || return false
    instance === root || is_compileable_instance(instance)
end

function count_boxes(code::Core.CodeInfo)
    count(eachindex(code.code)) do position
        statement = code.code[position]
        statement isa Expr && statement.head === :(=) || return false
        is_box_type(code.ssavaluetypes[position])
    end
end

# A call left to dispatch on a callee no builtin; one inlining copied in is the inlined frame's to count
function count_dispatches(code::Core.CodeInfo, instance::Core.MethodInstance)
    sptypes = static_parameter_types(instance)
    count(eachindex(code.code)) do position
        statement = code.code[position]
        statement isa Expr && statement.head === :call || return false
        callee = widened_argument_type(code, sptypes, first(statement.args))
        is_builtin_type(callee) && return false
        isnothing(inlined_instance(code.debuginfo, position))
    end
end

function check_opt_entries(entries; recorded, modules)
    findings = Finding[]
    module_set = Set{Module}(modules)
    interp = inference_interpreter()
    for entry in entries
        counts = opt_counts(entry, module_set, interp)
        counts.dispatches == 0 && counts.boxes == 0 && continue
        mod, file, line = entry_location(entry, recorded)
        if counts.dispatches > 0
            push!(findings, Finding(mod, :runtime_dispatch, file, entry.symbol, line,
                  "runtime dispatch in the inferred graph of this entry",
                  [:dispatches => string(counts.dispatches)]))
        end
        if counts.boxes > 0
            push!(findings, Finding(mod, :inferred_box, file, entry.symbol, line,
                  "a captured local is boxed in the inferred graph of this entry",
                  [:boxes => string(counts.boxes)]))
        end
    end
    findings
end

run(check::OptAnalysis, ctx) = check_opt_entries(check.entries; recorded = ctx.recorded, modules = package_modules(ctx))

kinds(::OptAnalysis) = (:runtime_dispatch => :advisory, :inferred_box => :advisory)
