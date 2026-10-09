# Storage overloads: one function, two methods, one kernel for each array storage.

"""Runs in `CHECKS`. Two methods of one function take the same values in different array storage."""
struct StorageOverloads <: Check end

kinds(::StorageOverloads) = (:storage_overload => :error,)

function run(::StorageOverloads, ctx)
    modules = package_modules(ctx)
    check_storage_overloads(modules, ctx.index)
end

# A signature slot may name a type variable. The pair is judged on its upper bound.
function bound_type(@nospecialize(slot))
    slot isa TypeVar || return slot
    bound_type(slot.ub)
end

# The element type an array slot holds, closed over its method's type variables so slots of two methods compare.
# `eltype` reads an element with free type variables as `Any`.
function element_type(@nospecialize(slot), @nospecialize(signature))
    array = Base.unwrap_unionall(slot)
    array isa DataType || return Any
    array_name = Base.typename(AbstractArray)
    while array.name !== array_name
        array = supertype(array)
    end
    held = first(array.parameters)
    within_slot = Base.rewrap_unionall(held, slot)
    Base.rewrap_unionall(within_slot, signature)
end

function is_storage_argument(@nospecialize(earlier), @nospecialize(later), earlier_method::Method, later_method::Method)
    earlier isa Type || return false
    later isa Type || return false
    earlier <: AbstractArray || return false
    later <: AbstractArray || return false
    earlier <: later && return false
    later <: earlier && return false
    earlier_element = element_type(earlier, earlier_method.sig)
    later_element = element_type(later, later_method.sig)
    earlier_element == later_element || return false
    earlier <: Array || later <: Array
end

# Printing a type searches its module for an alias. Repeated types share one print.
function type_text(@nospecialize(slot), texts)
    haskey(texts, slot) && return texts[slot]
    text = string(slot)
    texts[slot] = text
    text
end

# The first signature slot is the function. Argument slots start at the second.
function storage_labels(earlier::Method, later::Method, texts)
    earlier_sig = Base.unwrap_unionall(earlier.sig)
    later_sig = Base.unwrap_unionall(later.sig)
    earlier_params = earlier_sig.parameters
    later_params = later_sig.parameters
    length(earlier_params) == length(later_params) || return nothing
    labels = String[]
    for index in 2:length(earlier_params)
        earlier_bound = bound_type(earlier_params[index])
        later_bound = bound_type(later_params[index])
        earlier_bound == later_bound && continue
        is_storage_argument(earlier_bound, later_bound, earlier, later) || return nothing
        earlier_text = type_text(earlier_bound, texts)
        later_text = type_text(later_bound, texts)
        push!(labels, earlier_text)
        push!(labels, later_text)
    end
    isempty(labels) && return nothing
    join(labels, " ")
end

# Load place, then path, then line: the order a reader meets each method.
function order_methods(owned, places, repo)
    keyed = Vector{Pair{Tuple{Vector{Int},String,Int},Method}}()
    for method in owned
        file, line = method_site(method, repo)
        owner = module_key(method.module)
        place = get(places, (owner, file), Int[])
        key = (place, file, line)
        push!(keyed, key => method)
    end
    sort!(keyed; by = first)
    ordered = Method[]
    for pair in keyed
        push!(ordered, last(pair))
    end
    ordered
end

function methods_in(fn::Function, project)
    owned = Method[]
    for method in methods(fn)
        method.module in project || continue
        push!(owned, method)
    end
    owned
end

function push_pair!(findings, earlier::Method, later::Method, labels, repo)
    file, line = method_site(earlier, repo)
    earlier_site = string(file, ":", line)
    later_file, later_line = method_site(later, repo)
    later_site = string(later_file, ":", later_line)
    sites = join((earlier_site, later_site), " ")
    owner = module_key(earlier.module)
    name = string(earlier.name)
    detail = "two methods of one function take the same values in different array storage"
    evidence = [:methods => sites, :storage => labels]
    finding = Finding(owner, :storage_overload, file, name, line, detail, evidence)
    push!(findings, finding)
end

function append_pairs!(findings, ordered, repo, texts)
    count = length(ordered)
    for i in 1:count
        earlier = ordered[i]
        for j in (i + 1):count
            later = ordered[j]
            labels = storage_labels(earlier, later, texts)
            isnothing(labels) && continue
            push_pair!(findings, earlier, later, labels, repo)
        end
    end
end

# eval and include are bindings every module carries. Their methods sit outside the package.
function scan_module!(findings, mod, seen, project, places, repo, texts)
    for name in names(mod; all = true, imported = false)
        text = string(name)
        startswith(text, "#") && continue
        name in (:eval, :include) && continue
        isdefined(mod, name) || continue
        owner = Base.binding_module(mod, name)
        owner === mod || continue
        value = getfield(mod, name)
        value isa Function || continue
        value in seen && continue
        push!(seen, value)
        owned = methods_in(value, project)
        length(owned) < 2 && continue
        ordered = order_methods(owned, places, repo)
        append_pairs!(findings, ordered, repo, texts)
    end
end

function check_storage_overloads(modules, index)
    findings = Finding[]
    seen = IdSet{Function}()
    project = Set{Module}(modules)
    places = load_places(index)
    repo = index.repo
    texts = IdDict{Any,String}()
    for mod in modules
        scan_module!(findings, mod, seen, project, places, repo, texts)
    end
    findings
end
