# The workload phase: the package's own run between the static checks and the checks that read what it did.

"""What the method table holds after one run of the workload, and the probed calls that run made."""
struct Observation
    reached::Set{Method}             # live methods compiled during the run or earlier; a keyword body or a restored probe credits its method
    records::Vector{ProbeRecord}     # probed calls of at least the probes' slow threshold; empty when nothing is probed
    seconds::Float64                 # the workload's wall time (s)
end

# A keyword call compiles the body function, so that specialization counts for the method which declares the keywords.
function is_compiled(method::Method)
    specs = Base.specializations(method)
    isempty(specs) || return true
    keywords = Base.kwarg_decl(method)
    isempty(keywords) && return false
    body = Base.bodyfunction(method)
    isnothing(body) && return false
    body_compiled(body)
end

function body_compiled(body::Function)
    for inner in methods(body)
        specs = Base.specializations(inner)
        isempty(specs) || return true
    end
    false
end

# A function type carries one leading hash plus its name. A second hash marks a keyword body, a closure, or a local function.
function is_generated(method::Method)
    sig = Base.unwrap_unionall(method.sig)
    sig isa DataType || return false
    params = sig.parameters
    isempty(params) && return false
    ft = params[1]
    ft === typeof(Core.kwcall) && return true
    # A callable bound by a type variable, `(f::F)(x) where F`, has no function name to read.
    ft isa DataType || return false
    name = nameof(ft)
    generated_function_name(name)
end

function generated_function_name(name::Symbol)
    label = string(name)
    startswith(label, "#") || return false
    rest = chop(label; head = 1, tail = 0)
    occursin('#', rest)
end

function compiled_methods(modules)
    reached = Set{Method}()
    Base.visit(Core.methodtable) do method
        record_compiled!(reached, method, modules)
    end
    reached
end

function defined_callable(method::Method)
    owner = method.module
    isdefined(owner, method.name) || return nothing
    getfield(owner, method.name)
end

function is_live_method(method::Method)
    value = defined_callable(method)
    isnothing(value) && return false
    method_in_table(value, method)
end

method_in_table(value::Function, method::Method) = method in methods(value)
method_in_table(value::Type, method::Method) = method in methods(value)
method_in_table(value, ::Method) = false

function argument_types(method::Method)
    unwrapped = Base.unwrap_unionall(method.sig)
    params = unwrapped.parameters
    positional = params[2:end]
    Tuple{positional...}
end

# The probed definition was compiled, then replaced. The table holds the later method of the same signature.
function restored_method(probed::Method)
    value = defined_callable(probed)
    isnothing(value) && return nothing
    types = argument_types(probed)
    matched = methods(value, types)
    chosen = nothing
    for method in matched
        method.sig == probed.sig || continue
        if isnothing(chosen) || method.primary_world > chosen.primary_world
            chosen = method
        end
    end
    chosen
end

function collect_compiled!(found, functions, modules)
    module_set = Set{Module}(modules)
    for func in functions
        defined = methods(func)
        for method in defined
            record_compiled!(found, method, module_set)
        end
    end
end

function compiled_probed(probes, modules)
    found = Method[]
    collect_compiled!(found, probes.functions, modules)
    collect_compiled!(found, probes.ambient, modules)
    found
end

function credit_restored!(reached, probed_compiled)
    for probed in probed_compiled
        restored = restored_method(probed)
        isnothing(restored) && continue
        push!(reached, restored)
    end
end

function record_compiled!(reached, method::Method, modules)
    method.module in modules || return
    is_generated(method) && return
    is_live_method(method) || return
    is_compiled(method) || return
    push!(reached, method)
end

"""Runs the workload, a zero-argument callable, once with the probes armed (`nothing` probes nothing), and reads
which of the package's methods it compiled."""
function observe(workload, probes, ctx)
    records = ProbeRecord[]
    elapsed = 0.0
    probed_compiled = Method[]
    modules = package_modules(ctx)
    if isnothing(probes)
        elapsed = @elapsed workload()
    else
        armed = arm!(probes, ctx)
        # arm! defines the probed methods after the caller's world began, so the workload runs in the latest one.
        # disarm! still runs when the workload throws, and that exception propagates.
        try
            elapsed = @elapsed Base.invokelatest(workload)
            probed_compiled = compiled_probed(probes, modules)
        finally
            records = disarm!(armed)
        end
    end
    reached = compiled_methods(modules)
    credit_restored!(reached, probed_compiled)
    Observation(reached, records, elapsed)
end
