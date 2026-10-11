# Storage overloads: one function, two methods, one kernel for each array storage.

"""Runs in `CHECKS`. Two methods of one function take the same values in different array storage."""
struct StorageOverloads <: Check end

kinds(::StorageOverloads) = (:storage_overload => :error,)

function run(::StorageOverloads, ctx)
    modules = package_modules(ctx)
    check_storage_overloads(ctx.defined, modules, ctx.index)
end

# A signature slot may name a type variable. The pair is judged on its upper bound.
function bound_type(@nospecialize(slot))
    slot isa TypeVar || return slot
    bound_type(slot.ub)
end

# The AbstractArray a slot's datatype sits under, its where-variables free.
function abstract_array_type(@nospecialize(slot))
    array = declared_datatype(slot)
    isnothing(array) && return nothing
    abstract_array = declared_datatype(AbstractArray)
    array_name = abstract_array.name
    while array.name !== array_name
        array = supertype(array)
    end
    array
end

# The element type an array slot holds, closed over its method's type variables so slots of two methods compare.
# `eltype` reads an element with free type variables as `Any`.
function element_type(@nospecialize(slot), @nospecialize(signature))
    array = abstract_array_type(slot)
    isnothing(array) && return Any
    held = first(array.parameters)
    within_slot = under_clauses_of(held, slot)
    under_clauses_of(within_slot, signature)
end

# The rank an array slot declares. A where-variable in that parameter is a free rank.
function array_rank(@nospecialize(slot))
    array = abstract_array_type(slot)
    isnothing(array) && return nothing
    rank_parameter = 2
    rank = array.parameters[rank_parameter]
    rank isa Int || return nothing
    rank
end

function is_storage_argument(@nospecialize(earlier), @nospecialize(later), earlier_method::Method, later_method::Method)
    earlier isa Type || return false
    later isa Type || return false
    earlier <: AbstractArray || return false
    later <: AbstractArray || return false
    earlier <: later && return false
    later <: earlier && return false
    earlier_rank = array_rank(earlier)
    later_rank = array_rank(later)
    if earlier_rank isa Int && later_rank isa Int
        earlier_rank == later_rank || return false
    end
    earlier_element = element_type(earlier, earlier_method.sig)
    later_element = element_type(later, later_method.sig)
    earlier_element == later_element || return false
    earlier <: Array || later <: Array
end

# Repeated types share one print.
function cached_type_text(@nospecialize(slot), texts)
    haskey(texts, slot) && return texts[slot]
    text = type_text(slot)
    texts[slot] = text
    text
end

# The first signature slot is the function. Argument slots start at the second.
function storage_labels(earlier::Method, later::Method, texts)
    earlier_params = signature_types(earlier.sig)
    later_params = signature_types(later.sig)
    length(earlier_params) == length(later_params) || return nothing
    labels = String[]
    for index in 2:length(earlier_params)
        earlier_bound = bound_type(earlier_params[index])
        later_bound = bound_type(later_params[index])
        earlier_bound == later_bound && continue
        is_storage_argument(earlier_bound, later_bound, earlier, later) || return nothing
        earlier_text = cached_type_text(earlier_bound, texts)
        later_text = cached_type_text(later_bound, texts)
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

function has_array_argument(method::Method)
    params = signature_types(method.sig)
    for index in 2:length(params)
        bound = bound_type(params[index])
        bound isa Type && bound <: AbstractArray && return true
    end
    false
end

# A function one of the package's modules defines under a written name; a keyword body or closure is generated.
function is_owned_function(value::Function, project)
    parentmodule(value) in project || return false
    name = nameof(value)
    !is_generated_name(name)
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

# Functions in the order their first method appears. A pair is judged on a slot where both methods take an array,
# so a method with no array argument pairs with none.
function check_storage_overloads(defined, modules, index)
    findings = Finding[]
    project = Set{Module}(modules)
    places = load_places(index)
    repo = index.repo
    texts = IdDict{Any,String}()
    grouped = methods_by_function(defined)
    judged = IdSet{Function}()
    for method in defined
        value = method_function(method)
        isnothing(value) && continue
        value in judged && continue
        push!(judged, value)
        is_owned_function(value, project) || continue
        owned = filter(has_array_argument, grouped[value])
        length(owned) < 2 && continue
        ordered = order_methods(owned, places, repo)
        append_pairs!(findings, ordered, repo, texts)
    end
    findings
end
