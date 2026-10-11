# The workload phase: the package's own run between the static checks and the checks that read what it did.

"""What the method table holds after one run of the workload."""
struct Observation
    reached::Set{Method}             # live methods compiled during the run or earlier, read before the method graph's walk; a keyword body or an all-Any constructor credits its method
    specializations::Base.IdSet{Core.MethodInstance}   # the package's specializations when the run ended, before the walk adds its own
    seconds::Float64                 # the workload's wall time (s)
end

"""The workload of a gate called where the package's code already ran, as at the end of `test/runtests.jl`: it runs
nothing, so the gate reads what the earlier run compiled."""
struct PriorRun end

(::PriorRun)() = nothing

function record_specializations!(existing, method::Method, modules)
    method.module in modules || return
    for instance in method_instances(method)
        push!(existing, instance)
    end
end

# A method Julia has specialized: `method_instances` lists what it compiled or inferred for the method.
has_instance(method::Method) = !isempty(method_instances(method))

# `modules` holds the package's modules. A method compiled there, read at the same instant as its instances.
function holds_compiled(method::Method, modules)
    method.module in modules || return false
    has_instance(method)
end

# A keyword call compiles the body function, so that specialization counts for the method which declares the keywords.
function is_compiled(method::Method, modules)
    holds_compiled(method, modules) && return true
    body = body_function(method)
    isnothing(body) && return false
    for inner in methods(body)
        holds_compiled(inner, modules) && return true
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
function credit_typed_constructors!(reached, defined, modules)
    sites = Set{Tuple{Symbol,Symbol,Int,Int}}()
    typed = Method[]
    for method in defined
        is_type_constructor(method) || continue
        if !all_arguments_any(method)
            push!(typed, method)
            continue
        end
        holds_compiled(method, modules) || continue
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

# `nameof` and `parentmodule` on a function infer as untyped, so each assert selects one method.
function package_owned_function(method::Method, project)
    found = method_function(method)
    isnothing(found) && return nothing
    value = found::Function
    owner = parentmodule(value)::Module
    owner in project || return nothing
    name = nameof(value)::Symbol
    is_generated_name(name) && return nothing
    value
end

# Functions the package owns among the methods its modules define: the function's module is one of them, and the
# name is one the source wrote.
function owned_functions(defined, project)
    owned = IdSet{Function}()
    for method in defined
        value = package_owned_function(method, project)
        isnothing(value) || push!(owned, value)
    end
    owned
end

method_place(method::Method) = (string(method.file), method.line)

# The function type's module is read here, and the function itself only for a module the package owns.
# A direct child the package's module list omits keeps its own latest methods beside that.
function classify_method!(defined, foreign, nested, method::Method, project)
    is_latest(method) || return
    if method.module in project
        push!(defined, method)
        return
    end
    parent = parentmodule(method.module)
    if parent in project
        push!(nested, method)
    end
    owner = function_type_module(method)
    isnothing(owner) && return
    owner in project || return
    push!(foreign, method)
end

function methods_on(foreign, owned)
    added = Method[]
    for method in foreign
        found = method_function(method)
        isnothing(found) && continue
        value = found::Function
        value in owned || continue
        push!(added, method)
    end
    added
end

function finish_methods(defined, foreign, nested, project)
    sort!(defined, by = method_place)
    sort!(nested, by = method_place)
    owned = owned_functions(defined, project)
    added = methods_on(foreign, owned)
    (defined = defined, added = added, nested = nested)
end

# What the package defines and what it has compiled, from one walk. Read before the method graph's walk, whose
# specializations would count too.
function read_run_methods(modules)
    project = Set{Module}(modules)
    defined = Method[]
    foreign = Method[]
    nested = Method[]
    specializations = Base.IdSet{Core.MethodInstance}()
    reached = Set{Method}()
    each_loaded_method() do method
        record_specializations!(specializations, method, project)
        classify_method!(defined, foreign, nested, method, project)
        record_compiled!(reached, method, project)
    end
    census = finish_methods(defined, foreign, nested, project)
    credit_typed_constructors!(reached, census.defined, project)
    (census = census, specializations = specializations, reached = reached)
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

function record_compiled!(reached, method::Method, modules)
    method.module in modules || return
    is_generated(method) && return
    is_live_method(method) || return
    is_compiled(method, modules) || return
    push!(reached, method)
end

"""Runs the workload, a zero-argument callable, once, and reads which of the package's methods it compiled. Returns
what the run left in the method table and the method lists the same walk of the table read. The gate calls it before
it walks the method graph."""
function observe(workload, ctx)
    modules = package_modules(ctx)
    elapsed = @elapsed workload()
    # The workload can define methods after the caller's world began, so the table is read in the latest one.
    table = Base.invokelatest(read_run_methods, modules)
    observed = Observation(table.reached, table.specializations, elapsed)
    (observed, table.census)
end
