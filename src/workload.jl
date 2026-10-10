# The workload phase: the package's own run between the static checks and the checks that read what it did.

"""What the method table holds after one run of the workload, the probed calls that run made, and the waits those calls logged."""
struct Observation
    reached::Set{Method}             # live methods compiled during the run or earlier, read before the method graph's walk; a keyword body, a restored probe or an all-Any constructor credits its method
    records::Vector{ProbeRecord}     # probed calls of at least the probes' slow threshold; empty when nothing is probed
    waits::Vector{WaitRecord}        # waits those calls logged; empty when nothing is probed
    seconds::Float64                 # the workload's wall time (s)
end

"""The workload of a gate called where the package's code already ran, as at the end of `test/runtests.jl`: it runs
nothing, so the gate reads what the earlier run compiled. Probes armed after that run record nothing, so none may join it."""
struct PriorRun end

(::PriorRun)() = nothing

# Whether probes armed around the workload's call can record what it runs.
records_calls(_workload) = true
records_calls(::PriorRun) = false

function record_specializations!(existing, method::Method, modules)
    method.module in modules || return
    for instance in method_instances(method)
        push!(existing, instance)
    end
end

"""The specializations of the package's methods, read before the method graph's walk. Load, earlier runs and the
workload made each one; the walk, which makes one for every method it walks, has not run yet."""
function existing_specializations(modules)
    existing = Base.IdSet{Core.MethodInstance}()
    module_set = Set{Module}(modules)
    each_loaded_method() do method
        record_specializations!(existing, method, module_set)
    end
    existing
end

"""Whether a specialization ran, or was compiled to run: `existing`, from `existing_specializations`, holds it."""
specialization_ran(instance::Core.MethodInstance, existing) = instance in existing

function holds_specialization(method::Method, existing)
    for instance in method_instances(method)
        specialization_ran(instance, existing) && return true
    end
    false
end

# A keyword call compiles the body function, so that specialization counts for the method which declares the keywords.
function is_compiled(method::Method, existing)
    holds_specialization(method, existing) && return true
    body = body_function(method)
    isnothing(body) && return false
    for inner in methods(body)
        holds_specialization(inner, existing) && return true
    end
    false
end

function argument_is_any(@nospecialize(param))
    param === Any && return true
    param isa Core.TypeofVararg || return false
    param.T === Any
end

function all_arguments_any(method::Method)
    params = signature_types(method.sig)
    length(params) < 2 && return false
    last_index = length(params)
    for index in 2:last_index
        argument_is_any(params[index]) || return false
    end
    true
end

function is_type_constructor(method::Method)
    params = signature_types(method.sig)
    isempty(params) && return false
    held = type_object_held(params[1])
    !isnothing(held)
end

# A call written as Type{Params}(...) compiles the all-Any constructor Julia installs beside the typed one, so the
# typed constructor at that site ran.
function credit_typed_constructors!(reached, defined, existing)
    sites = Set{Tuple{Symbol,Symbol,Int,Int}}()
    typed = Method[]
    for method in defined
        is_type_constructor(method) || continue
        if !all_arguments_any(method)
            push!(typed, method)
            continue
        end
        holds_specialization(method, existing) || continue
        push!(sites, (method.name, method.file, method.line, method.nargs))
    end
    for method in typed
        site = (method.name, method.file, method.line, method.nargs)
        site in sites && push!(reached, method)
    end
end

function is_generated(method::Method)
    params = signature_types(method.sig)
    isempty(params) && return false
    ft = params[1]
    ft === typeof(Core.kwcall) && return true
    # A callable bound by a type variable, `(f::F)(x) where F`, has no function name to read.
    ft isa DataType || return false
    is_generated_function_type(ft)
end

# What the package has compiled so far. Read before the method graph's walk, whose specializations would count too.
function compiled_methods(modules)
    existing = existing_specializations(modules)
    reached = Set{Method}()
    each_loaded_method() do method
        record_compiled!(reached, method, modules, existing)
    end
    defined = project_methods(modules)
    credit_typed_constructors!(reached, defined, existing)
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
method_in_table(_value, ::Method) = false

function argument_types(method::Method)
    params = signature_types(method.sig)
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

function collect_compiled!(found, functions, modules, existing)
    module_set = Set{Module}(modules)
    for func in functions
        defined = methods(func)
        for method in defined
            record_compiled!(found, method, module_set, existing)
        end
    end
end

function compiled_probed(armed::ProbeHandle, modules)
    existing = existing_specializations(modules)
    found = Method[]
    collect_compiled!(found, armed.functions, modules, existing)
    found
end

function credit_restored!(reached, probed_compiled)
    for probed in probed_compiled
        restored = restored_method(probed)
        isnothing(restored) && continue
        push!(reached, restored)
    end
end

function record_compiled!(reached, method::Method, modules, existing)
    method.module in modules || return
    is_generated(method) && return
    is_live_method(method) || return
    is_compiled(method, existing) || return
    push!(reached, method)
end

"""Runs the workload, a zero-argument callable, once with the probes armed (`nothing` probes nothing), and reads
which of the package's methods it compiled. The gate calls it before it walks the method graph."""
function observe(workload, probes, ctx)
    records = ProbeRecord[]
    waits = WaitRecord[]
    elapsed = 0.0
    probed_compiled = Method[]
    modules = package_modules(ctx)
    if isnothing(probes)
        elapsed = @elapsed workload()
    else
        armed = arm!(probes, ctx)
        # arm! and disarm! define methods and keyword bodies after the caller's world began, so the workload and
        # every read of the method table run in the latest one. disarm! still runs when the workload throws.
        try
            elapsed = @elapsed Base.invokelatest(workload)
            probed_compiled = Base.invokelatest(compiled_probed, armed, modules)
        finally
            traced = disarm!(armed)
            records = traced.records
            waits = traced.waits
        end
    end
    reached = Base.invokelatest(compiled_methods, modules)
    Base.invokelatest(credit_restored!, reached, probed_compiled)
    Observation(reached, records, waits, elapsed)
end
