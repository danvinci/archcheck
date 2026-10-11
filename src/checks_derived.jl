# Declared derived values: one producer, a key that names every evaluation, calls kept on the cache.

"""Runs in `CHECKS`. With no declared derived value it is quiet. A second method constructs a declared value."""
struct OneProducer <: Check end
"""Runs in `CHECKS`. With no declared derived value it is quiet. A declared key is not isbits, caches by identity, or omits a name the producer reads."""
struct CacheKeys <: Check end
"""Runs in `CHECKS`. With no declared derived value it is quiet. A method calls the producer and does not write the declared cache field."""
struct CachedCalls <: Check end

kinds(::OneProducer) = (:second_producer => :advisory,)
kinds(::CacheKeys) = (:cache_key => :advisory,)
kinds(::CachedCalls) = (:uncached_call => :advisory,)

function run(::OneProducer, ctx)
    isempty(ctx.derived) && return Finding[]
    second_producer_findings(ctx)
end

function run(::CacheKeys, ctx)
    isempty(ctx.derived) && return Finding[]
    found = Finding[]
    for declared in ctx.derived
        append_cache!(found, declared, ctx.index, ctx.recorded, ctx.root)
    end
    found
end

function run(::CachedCalls, ctx)
    isempty(ctx.derived) && return Finding[]
    found = Finding[]
    for declared in ctx.derived
        append_uncached!(found, declared, ctx.index, declared.cache)
    end
    found
end

const LocatedForm = NamedTuple{(:file, :site, :form), Tuple{FileNode, MethodSite, JS.SyntaxNode}}

const IDENTITY_CALLS = Set{Symbol}([:IdDict, :objectid])

const CACHE_DETAIL = Dict{String,String}(
    "not_isbits" => "the key's inferred return is not an isbits value",
    "identity_cache" => "the producer caches by identity",
    "omitted_read" => "the producer reads a name the key does not take",
)

function index_forms(index)
    found = LocatedForm[]
    for file in index.files
        for (site, form) in file.scan.forms
            placed = (file = file, site = site, form = form)
            push!(found, placed)
        end
    end
    found
end

function function_forms(index, recorded, fn)
    found = LocatedForm[]
    for method in methods(fn)
        located = method_form(index, recorded, method)
        isnothing(located) && continue
        push!(found, located)
    end
    found
end

"""The structs a package module defines among the types inference gives the producer at each method's declared
signature."""
function returned_structs(producer, modules)
    found = DataType[]
    for result in inferred_return_types(producer)
        for member in union_members(result)
            body = declared_datatype(member)
            isnothing(body) && continue
            isstructtype(body) || continue
            parentmodule(body) in modules || continue
            push!(found, body)
        end
    end
    found
end

# The type node a method's return annotation writes; nothing without one.
function annotated_return(form)
    children = child_nodes(form)
    child_count(children) == 0 && return nothing
    signature = children[1]
    JS.kind(signature) == K"::" || return nothing
    parts = child_nodes(signature)
    isnothing(parts) && return nothing
    last(parts)
end

# The name of the type a type node writes in `home`, its parameters left off; nothing when it names no type there.
function written_type_name(home, node)
    head = node
    while JS.kind(head) == K"curly"
        head = first(child_nodes(head))
    end
    written = written_type(home, head)
    body = declared_datatype(written)
    isnothing(body) && return nothing
    body.name
end

# The value a written callee names where the code sits: its qualifier's module, then the callee bound there.
function resolve_name(home, written)
    isnothing(home) && return nothing
    isnothing(written) && return nothing
    holder = home
    qualifier = written.qualifier
    if !isempty(qualifier)
        segments = key_segments(Symbol(qualifier))
        holder = path_module(home, segments)
    end
    isnothing(holder) && return nothing
    isdefined(holder, written.callee) || return nothing
    getfield(holder, written.callee)
end

# A method builds the value when its return annotation names a returned struct or it calls one's constructor. Each
# name resolves in the module the method's file loads into, so a type of the same name elsewhere is another type.
function builds_returned(file, site, form, home, returned)
    annotation = annotated_return(form)
    if !isnothing(annotation)
        named = written_type_name(home, annotation)
        !isnothing(named) && named in returned && return true
    end
    calls = get(file.scan.callsites, site, CallSite[])
    for call in calls
        called = resolve_name(home, call)
        called isa Type || continue
        body = declared_datatype(called)
        isnothing(body) && continue
        body.name in returned && return true
    end
    false
end

function second_producer(file, site, form, producer_name, owned_labels)
    line = source_line(form)
    label = string(site.name, "@", line)
    labels = vcat(owned_labels, label)
    sort!(labels)
    unique!(labels)
    joined = join(labels, " ")
    symbol = string(site.name)
    evidence = Pair{Symbol,String}[:derived => producer_name, :producers => joined]
    detail = "a second method constructs the derived value"
    Finding(file.mod, :second_producer, file.path, symbol, line, detail, evidence)
end

# The derived value is each struct a package module defines that the producer returns; an exception it throws, a
# part it builds and a foreign result are none.
function second_producer_findings(ctx)
    modules = Set{Module}(package_modules(ctx))
    found = Finding[]
    for declared in ctx.derived
        structs = returned_structs(declared.producer, modules)
        returned = Set{Core.TypeName}(body.name for body in structs)
        isempty(returned) && continue
        owned = function_forms(ctx.index, ctx.recorded, declared.producer)
        owned_nodes = Base.IdSet{JS.SyntaxNode}(placed.form for placed in owned)
        owned_labels = [string(placed.site.name, "@", source_line(placed.form)) for placed in owned]
        producer_name = string(nameof(declared.producer))
        for file in ctx.index.files
            home = loaded_module(ctx.root, file.mod)
            isnothing(home) && continue
            for (site, form) in file.scan.forms
                form in owned_nodes && continue
                builds_returned(file, site, form, home, returned) || continue
                finding = second_producer(file, site, form, producer_name, owned_labels)
                push!(found, finding)
            end
        end
    end
    found
end

# One argument after the macro name caches by identity. A cache type beside it names that cache.
function producer_memoized(placed_forms)
    forms = JS.SyntaxNode[]
    for placed in placed_forms
        push!(forms, placed.form)
    end
    for placed in placed_forms
        for node in walk_nodes(placed.file.tree)
            JS.kind(node) == K"macrocall" || continue
            children = child_nodes(node)
            child_count(children) == 2 || continue
            head = children[1]
            parts = child_nodes(head)
            child_count(parts) == 0 && continue
            parts[1].val === :memoize || continue
            argument = children[2]
            for form in forms
                argument === form && return true
            end
        end
    end
    false
end

function is_mutable_key(key_type::DataType)
    isstructtype(key_type) || return false
    ismutabletype(key_type) || return false
    found = methods(hash, Tuple{key_type, UInt})
    for method in found
        parameters = signature_types(method.sig)
        length(parameters) < 2 && continue
        slot = parameters[2]
        slot == Any && continue
        return false
    end
    true
end

is_mutable_key(::Any) = false

function note_dict!(problems, node, mod)
    isnothing(mod) && return
    children = child_nodes(node)
    child_count(children) == 0 && return
    head = children[1]
    JS.kind(head) == K"curly" || return
    type_name(head) === :Dict || return
    params = child_nodes(head)
    child_count(params) < 2 && return
    key_node = params[2]
    applied = written_type(mod, key_node)
    isnothing(applied) && return
    key_type = type_head(applied)
    isnothing(key_type) && return
    is_mutable_key(key_type) || return
    push!(problems, "identity_cache")
end

# The package's own files are keyed by its name. A key below that name is a field path.
function note_identity_cache!(problems, placed_forms, pkg)
    for placed in placed_forms
        key = placed.file.mod
        owner = pkg
        if key !== nameof(pkg)
            owner = loaded_module(pkg, key)
        end
        for node in walk_nodes(placed.form)
            kind = JS.kind(node)
            kind == K"call" || kind == K"dotcall" || continue
            children = child_nodes(node)
            child_count(children) == 0 && continue
            naming = name_of_head(children[1])
            isnothing(naming) && continue
            callee = naming.callee
            if callee in IDENTITY_CALLS
                push!(problems, "identity_cache")
            end
            callee === :Dict && note_dict!(problems, node, owner)
        end
    end
    producer_memoized(placed_forms) && push!(problems, "identity_cache")
end

function member_name(node)
    JS.kind(node) == K"." || return nothing
    children = child_nodes(node)
    child_count(children) == 2 || return nothing
    member = children[2].val
    member isa Symbol ? member : nothing
end

function note_members!(names, root)
    for node in walk_nodes(root)
        member = member_name(node)
        isnothing(member) || push!(names, member)
    end
end

# The declaring identifiers of the arguments a method's signature binds; its `where` variables are no argument.
function argument_identifiers(form)
    found = Base.IdSet{JS.SyntaxNode}()
    children = child_nodes(form)
    child_count(children) == 0 && return found
    parts = call_parts(children[1])
    isnothing(parts) && return found
    bound = call_argnames!(Bindings(), parts)
    union!(found, values(bound.declared))
    found
end

function is_argument(scan, node, arguments)
    binding = local_binding(scan, node)
    !isnothing(binding) && binding in arguments
end

# The inputs a producer's method reads: each argument, and each member read along a path that starts at one.
function note_inputs!(reads, placed)
    body = method_body(placed.form)
    isnothing(body) && return
    arguments = argument_identifiers(placed.form)
    scan = placed.file.scan
    for node in walk_nodes(body)
        value = node.val
        if value isa Symbol && is_argument(scan, node, arguments)
            push!(reads, value)
        end
        member = member_name(node)
        isnothing(member) && continue
        root = path_root(node)
        is_argument(scan, root, arguments) && push!(reads, member)
    end
end

function signature_names(form)
    children = child_nodes(form)
    isnothing(children) && return Symbol[]
    sig_argnames(children[1])
end

function omitted_names(producer_forms, key_forms)
    reads = Set{Symbol}()
    for placed in producer_forms
        note_inputs!(reads, placed)
    end
    taken = Set{Symbol}()
    for placed in key_forms
        args = signature_names(placed.form)
        union!(taken, args)
        body = method_body(placed.form)
        isnothing(body) && continue
        note_members!(taken, body)
    end
    unread = setdiff(reads, taken)
    sort!(collect(unread))
end

# An isbits address still compares by identity, so a content key returns an isbits value other than an address. Only
# a concrete result names what the key returns: an abstract one, or the `Union{}` of a method that throws, names none.
function key_returns_bits(key)
    for result in inferred_return_types(key)
        for member in union_members(result)
            isconcretetype(member) || continue
            member <: Ptr && return false
            isbitstype(member) || return false
        end
    end
    true
end

function form_place(placed)
    line = source_line(placed.form)
    (placed.file.path, line)
end

function extend_key!(_problems, _omitted, _owned, _index, _recorded, _pkg, ::Nothing) end

function extend_key!(problems, omitted, owned, index, recorded, pkg, key::Function)
    key_forms = function_forms(index, recorded, key)
    note_identity_cache!(problems, key_forms, pkg)
    key_returns_bits(key) || push!(problems, "not_isbits")
    unkeyed = omitted_names(owned, key_forms)
    append!(omitted, unkeyed)
end

function emit_cache!(found, producer_name, problem, anchor, evidence)
    detail = CACHE_DETAIL[problem]
    line = source_line(anchor.form)
    finding = Finding(anchor.file.mod, :cache_key, anchor.file.path, producer_name, line, detail, evidence)
    push!(found, finding)
end

function append_cache!(found, declared, index, recorded, pkg)
    owned = function_forms(index, recorded, declared.producer)
    isempty(owned) && return
    anchor = argmin(form_place, owned)
    problems = Set{String}()
    omitted = Symbol[]
    note_identity_cache!(problems, owned, pkg)
    extend_key!(problems, omitted, owned, index, recorded, pkg, declared.key)
    producer_name = string(nameof(declared.producer))
    ordered = sort!(collect(problems))
    for problem in ordered
        evidence = Pair{Symbol,String}[:derived => producer_name, :problem => problem]
        emit_cache!(found, producer_name, problem, anchor, evidence)
    end
    sort!(omitted)
    for name in omitted
        text = string(name)
        evidence = Pair{Symbol,String}[:derived => producer_name, :problem => "omitted_read", :name => text]
        emit_cache!(found, producer_name, "omitted_read", anchor, evidence)
    end
end

function writes_field(root, cache)
    for node in walk_nodes(root)
        JS.kind(node) == K"=" || continue
        children = child_nodes(node)
        child_count(children) < 2 && continue
        lhs = children[1]
        JS.kind(lhs) == K"." || continue
        parts = child_nodes(lhs)
        child_count(parts) == 2 || continue
        parts[2].val === cache && return true
    end
    false
end

function append_uncached!(_found, _declared, _index, ::Nothing) end

function append_uncached!(found, declared, index, cache::Symbol)
    forms = index_forms(index)
    writers = Set{Tuple{String,MethodSite}}()
    for placed in forms
        writes_field(placed.form, cache) || continue
        push!(writers, (placed.file.path, placed.site))
    end
    producer = declared.producer
    home = module_key(parentmodule(producer))
    producer_name = nameof(producer)
    declared_name = string(producer_name)
    detail = "the producer is called in a method that does not write the cache"
    for file in index.files
        for (site, calls) in file.scan.callsites
            (file.path, site) in writers && continue
            for call in calls
                call.callee === producer_name || continue
                if isempty(call.qualifier)
                    file.mod === home || continue
                else
                    parts = split(call.qualifier, ".")
                    tail = last(parts)
                    tail == string(home) || continue
                end
                line = call.line
                site_text = string(file.path, ":", line)
                evidence = Pair{Symbol,String}[:derived => declared_name, :site => site_text]
                symbol = string(site.name)
                finding = Finding(file.mod, :uncached_call, file.path, symbol, line, detail, evidence)
                push!(found, finding)
            end
        end
    end
end

