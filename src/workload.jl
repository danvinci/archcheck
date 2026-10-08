# The workload phase: the package's own run between the static checks and the checks that read what it did.

"""What the method table holds after one run of the workload, and the probed calls that run made."""
struct Observation
    reached::Set{Method}             # specialized after the run, keyword bodies credited to their method; earlier compilation in the process counts
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

function record_compiled!(reached, method::Method, modules)
    method.module in modules || return
    is_generated(method) && return
    is_compiled(method) || return
    push!(reached, method)
end

"""Runs the workload, a zero-argument callable, once with the probes armed (`nothing` probes nothing), and reads
which of the package's methods it compiled."""
function observe(workload, probes, ctx)
    records = ProbeRecord[]
    elapsed = 0.0
    if isnothing(probes)
        elapsed = @elapsed workload()
    else
        armed = arm!(probes, ctx)
        # arm! defines the probed methods after the caller's world began, so the workload runs in the latest one.
        # disarm! still runs when the workload throws, and that exception propagates.
        try
            elapsed = @elapsed Base.invokelatest(workload)
        finally
            records = disarm!(armed)
        end
    end
    modules = package_modules(ctx)
    reached = compiled_methods(modules)
    Observation(reached, records, elapsed)
end
