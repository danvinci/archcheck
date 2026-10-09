# Declared derived values: one producer, a key that names every evaluation, calls kept on the cache.

struct OneProducer <: Check end
struct CacheKeys <: Check end
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
    cache_key_findings(ctx)
end

function run(::CachedCalls, ctx)
    isempty(ctx.derived) && return Finding[]
    uncached_call_findings(ctx)
end

struct PlacedForm
    file::FileNode       # indexed file holding the form
    site::MethodSite     # scanner site of the calls in this form
    form::JS.SyntaxNode  # method form the scan recorded for that site
end

const IDENTITY_CALLS = Set{Symbol}([:IdDict, :objectid])

const CACHE_DETAIL = Dict{String,String}(
    "not_isbits" => "the key's inferred return is not an isbits value",
    "identity_cache" => "the producer caches by identity",
    "omitted_read" => "the producer reads a name the key does not take",
)

function index_forms(index)
    found = PlacedForm[]
    for file in index.files
        for (site, form) in file.scan.forms
            push!(found, PlacedForm(file, site, form))
        end
    end
    found
end

function form_site(file, form)
    for (site, node) in file.scan.forms
        node === form && return site
    end
    nothing
end

function function_forms(index, fn)
    found = PlacedForm[]
    for method in methods(fn)
        located = method_form(index, method)
        isnothing(located) && continue
        file = located.file
        form = located.form
        site = form_site(file, form)
        isnothing(site) && continue
        push!(found, PlacedForm(file, site, form))
    end
    found
end

function form_nodes(placed)
    found = Set{JS.SyntaxNode}()
    for item in placed
        push!(found, item.form)
    end
    found
end

function package_types(index)
    found = Set{Symbol}()
    for file in index.files
        for name in file.scan.types
            push!(found, name)
        end
    end
    found
end

function bare_name(node)
    value = node.val
    value isa Symbol && return value
    kids = child_nodes(node)
    isnothing(kids) && return nothing
    isempty(kids) && return nothing
    kind = JS.kind(node)
    if kind == K"."
        member = last(kids)
        member_name = member.val
        member_name isa Symbol && return member_name
        return bare_name(member)
    end
    if kind == K"curly" || kind == K"<:" || kind == K"where"
        head = first(kids)
        return bare_name(head)
    end
    nothing
end

function annotated_return(form)
    kids = child_nodes(form)
    isnothing(kids) && return nothing
    isempty(kids) && return nothing
    signature = kids[1]
    JS.kind(signature) == K"::" || return nothing
    parts = child_nodes(signature)
    isnothing(parts) && return nothing
    bare_name(last(parts))
end

function constructed_names(placed, types)
    found = Set{Symbol}()
    if placed.site.name in types
        push!(found, placed.site.name)
    end
    calls = get(placed.file.scan.callsites, placed.site, CallSite[])
    for call in calls
        call.callee in types || continue
        push!(found, call.callee)
    end
    found
end

# A return annotation names the type. With no annotation, the type is a package type the method constructs.
function returned_names(placed_forms, types)
    annotated = Set{Symbol}()
    constructed = Set{Symbol}()
    for placed in placed_forms
        named = annotated_return(placed.form)
        isnothing(named) || push!(annotated, named)
        built = constructed_names(placed, types)
        union!(constructed, built)
    end
    isempty(annotated) && return constructed
    annotated
end

function builds_returned(placed, returned)
    named = annotated_return(placed.form)
    !isnothing(named) && named in returned && return true
    placed.site.name in returned && return true
    calls = get(placed.file.scan.callsites, placed.site, CallSite[])
    for call in calls
        call.callee in returned && return true
    end
    false
end

function site_label(name, line)
    text = string(name)
    line_text = string(line)
    text * "@" * line_text
end

function join_sites(producer_forms, second)
    labels = String[]
    for placed in producer_forms
        line = source_line(placed.form)
        push!(labels, site_label(placed.site.name, line))
    end
    second_line = source_line(second.form)
    push!(labels, site_label(second.site.name, second_line))
    sort!(labels)
    unique!(labels)
    join(labels, " ")
end

function emit_second!(found, producer_name, labels, placed)
    symbol = string(placed.site.name)
    line = source_line(placed.form)
    evidence = Pair{Symbol,String}[:derived => producer_name, :producers => labels]
    detail = "a second method constructs the derived value"
    finding = Finding(placed.file.mod, :second_producer, placed.file.path, symbol, line, detail, evidence)
    push!(found, finding)
end

function append_second!(found, declared, forms, types, index)
    owned = function_forms(index, declared.producer)
    returned = returned_names(owned, types)
    isempty(returned) && return
    owned_nodes = form_nodes(owned)
    producer_name = string(nameof(declared.producer))
    for placed in forms
        placed.form in owned_nodes && continue
        builds_returned(placed, returned) || continue
        labels = join_sites(owned, placed)
        emit_second!(found, producer_name, labels, placed)
    end
end

function second_producer_findings(ctx)
    forms = index_forms(ctx.index)
    types = package_types(ctx.index)
    found = Finding[]
    for declared in ctx.derived
        append_second!(found, declared, forms, types, ctx.index)
    end
    found
end

function call_callee(node)
    kids = child_nodes(node)
    isnothing(kids) && return nothing
    isempty(kids) && return nothing
    naming = name_of_head(kids[1])
    isnothing(naming) && return nothing
    naming.callee
end

function macro_called(node)
    kids = child_nodes(node)
    isnothing(kids) && return nothing
    isempty(kids) && return nothing
    head = kids[1]
    parts = child_nodes(head)
    isnothing(parts) && return nothing
    isempty(parts) && return nothing
    parts[1].val
end

# One argument after the macro name caches by identity. A cache type beside it names that cache.
function is_bare_memoize(node)
    JS.kind(node) == K"macrocall" || return false
    kids = child_nodes(node)
    isnothing(kids) && return false
    length(kids) == 2 || return false
    macro_called(node) === :memoize
end

function memoizes_form(node, forms)
    is_bare_memoize(node) || return false
    kids = child_nodes(node)
    argument = kids[2]
    for form in forms
        argument === form && return true
    end
    false
end

function file_has_memoize(node, forms)
    memoizes_form(node, forms) && return true
    kids = child_nodes(node)
    isnothing(kids) && return false
    for child in kids
        file_has_memoize(child, forms) && return true
    end
    false
end

function producer_memoized(placed_forms)
    forms = JS.SyntaxNode[]
    for placed in placed_forms
        push!(forms, placed.form)
    end
    seen = Set{String}()
    for placed in placed_forms
        path = placed.file.path
        path in seen && continue
        push!(seen, path)
        file_has_memoize(placed.file.tree, forms) && return true
    end
    false
end

function as_type(value::Type)
    value
end

function as_type(::Any)
    nothing
end

function resolve_type(mod, node)
    if JS.kind(node) == K"curly"
        kids = child_nodes(node)
        isnothing(kids) && return nothing
        head = first(kids)
        return resolve_type(mod, head)
    end
    path = dotted_names(node)
    isnothing(path) && return nothing
    value = constant_value(mod, path)
    as_type(value)
end

function has_specific_hash(key_type::DataType)
    found = methods(hash, Tuple{key_type, UInt})
    for method in found
        signature = Base.unwrap_unionall(method.sig)
        parameters = signature.parameters
        length(parameters) < 2 && continue
        slot = parameters[2]
        slot == Any && continue
        return true
    end
    false
end

function is_mutable_key(key_type::DataType)
    isstructtype(key_type) || return false
    ismutabletype(key_type) || return false
    !has_specific_hash(key_type)
end

function is_mutable_key(::Any)
    false
end

function note_dict!(problems, node, mod)
    isnothing(mod) && return
    kids = child_nodes(node)
    isnothing(kids) && return
    isempty(kids) && return
    head = kids[1]
    JS.kind(head) == K"curly" || return
    type_name(head) === :Dict || return
    params = child_nodes(head)
    isnothing(params) && return
    length(params) < 2 && return
    key_node = params[2]
    key_type = resolve_type(mod, key_node)
    isnothing(key_type) && return
    is_mutable_key(key_type) || return
    push!(problems, "identity_cache")
end

function note_identity!(problems, node, mod)
    kind = JS.kind(node)
    kind == K"quote" && return
    if kind == K"call" || kind == K"dotcall"
        callee = call_callee(node)
        if !isnothing(callee)
            if callee in IDENTITY_CALLS
                push!(problems, "identity_cache")
            end
            callee === :Dict && note_dict!(problems, node, mod)
        end
    end
    kids = child_nodes(node)
    isnothing(kids) && return
    for child in kids
        note_identity!(problems, child, mod)
    end
end

function scan_identity!(problems, placed, modules)
    mod = get(modules, placed.file.mod, nothing)
    note_identity!(problems, placed.form, mod)
end

function argument_names(form)
    kids = child_nodes(form)
    isnothing(kids) && return Symbol[]
    sig_argnames(kids[1])
end

function body_node(form)
    kids = child_nodes(form)
    isnothing(kids) && return nothing
    length(kids) < 2 && return nothing
    kids[2]
end

function note_key_argument!(names, args, node)
    isnothing(args) && return
    value = node.val
    value isa Symbol || return
    value in args || return
    push!(names, value)
end

function note_key_field!(names, node)
    JS.kind(node) == K"." || return
    kids = child_nodes(node)
    isnothing(kids) && return
    length(kids) == 2 || return
    member = kids[2].val
    member isa Symbol || return
    push!(names, member)
end

function note_read_name!(names, args, node)
    note_key_argument!(names, args, node)
    note_key_field!(names, node)
end

function enqueue_name_nodes!(pending, node)
    JS.kind(node) == K"quote" && return
    kids = child_nodes(node)
    isnothing(kids) && return
    for child in kids
        push!(pending, child)
    end
end

function collect_read_names!(names, args, root)
    pending = JS.SyntaxNode[]
    push!(pending, root)
    while !isempty(pending)
        node = pop!(pending)
        note_read_name!(names, args, node)
        enqueue_name_nodes!(pending, node)
    end
end

function producer_reads(placed_forms)
    names = Set{Symbol}()
    for placed in placed_forms
        args = argument_names(placed.form)
        body = body_node(placed.form)
        isnothing(body) && continue
        arg_set = Set(args)
        collect_read_names!(names, arg_set, body)
    end
    names
end

function key_taken(placed_forms)
    names = Set{Symbol}()
    for placed in placed_forms
        args = argument_names(placed.form)
        union!(names, args)
        body = body_node(placed.form)
        isnothing(body) && continue
        collect_read_names!(names, nothing, body)
    end
    names
end

function omitted_names(producer_forms, key_forms)
    reads = producer_reads(producer_forms)
    taken = key_taken(key_forms)
    missing = setdiff(reads, taken)
    sort!(collect(missing))
end

# An isbits address still compares by identity. A content key is an isbits value other than an address.
function accepts_key_type(result::DataType)
    result <: Ptr && return false
    isbitstype(result)
end

function accepts_key_type(::Any)
    false
end

function key_returns_bits(key)
    results = Base.return_types(key)
    isempty(results) && return true
    for result in results
        accepts_key_type(result) || return false
    end
    true
end

function earliest(placed_forms)
    isempty(placed_forms) && return nothing
    chosen = first(placed_forms)
    chosen_line = source_line(chosen.form)
    chosen_path = chosen.file.path
    for placed in placed_forms
        line = source_line(placed.form)
        path = placed.file.path
        earlier_path = path < chosen_path
        same_path = path == chosen_path && line < chosen_line
        if earlier_path || same_path
            chosen = placed
            chosen_line = line
            chosen_path = path
        end
    end
    chosen
end

function modules_by_key(ctx)
    found = Dict{Symbol,Module}()
    for mod in package_modules(ctx)
        found[module_key(mod)] = mod
    end
    found
end

function note_identity_cache!(problems, placed_forms, modules)
    for placed in placed_forms
        scan_identity!(problems, placed, modules)
    end
    memoized = producer_memoized(placed_forms)
    memoized && push!(problems, "identity_cache")
end

function extend_key!(problems, omitted, owned, index, modules, ::Nothing)
    return
end

function extend_key!(problems, omitted, owned, index, modules, key::Function)
    key_forms = function_forms(index, key)
    note_identity_cache!(problems, key_forms, modules)
    key_returns_bits(key) || push!(problems, "not_isbits")
    missing = omitted_names(owned, key_forms)
    append!(omitted, missing)
end

function cache_problems(declared, owned, index, modules)
    problems = Set{String}()
    omitted = Symbol[]
    note_identity_cache!(problems, owned, modules)
    extend_key!(problems, omitted, owned, index, modules, declared.key)
    (problems = problems, omitted = omitted)
end

function emit_cache!(found, producer_name, problem, anchor, evidence)
    detail = CACHE_DETAIL[problem]
    line = source_line(anchor.form)
    finding = Finding(anchor.file.mod, :cache_key, anchor.file.path, producer_name, line, detail, evidence)
    push!(found, finding)
end

function append_cache!(found, declared, index, modules)
    owned = function_forms(index, declared.producer)
    anchor = earliest(owned)
    isnothing(anchor) && return
    gathered = cache_problems(declared, owned, index, modules)
    producer_name = string(nameof(declared.producer))
    ordered = sort!(collect(gathered.problems))
    for problem in ordered
        evidence = Pair{Symbol,String}[:derived => producer_name, :problem => problem]
        emit_cache!(found, producer_name, problem, anchor, evidence)
    end
    names = sort!(copy(gathered.omitted))
    for name in names
        text = string(name)
        evidence = Pair{Symbol,String}[
            :derived => producer_name,
            :problem => "omitted_read",
            :name => text,
        ]
        emit_cache!(found, producer_name, "omitted_read", anchor, evidence)
    end
end

function cache_key_findings(ctx)
    modules = modules_by_key(ctx)
    found = Finding[]
    for declared in ctx.derived
        append_cache!(found, declared, ctx.index, modules)
    end
    found
end

function field_store(lhs, cache)
    JS.kind(lhs) == K"." || return false
    parts = child_nodes(lhs)
    isnothing(parts) && return false
    length(parts) == 2 || return false
    parts[2].val === cache
end

function writes_field(node, cache)
    kind = JS.kind(node)
    kind == K"quote" && return false
    if kind == K"="
        kids = child_nodes(node)
        if !isnothing(kids) && length(kids) >= 2 && field_store(kids[1], cache)
            return true
        end
    end
    kids = child_nodes(node)
    isnothing(kids) && return false
    for child in kids
        writes_field(child, cache) && return true
    end
    false
end

function cache_writers(placed_forms, cache)
    writers = Set{Tuple{String,MethodSite}}()
    for placed in placed_forms
        writes_field(placed.form, cache) || continue
        key = (placed.file.path, placed.site)
        push!(writers, key)
    end
    writers
end

function producer_home(fn)
    home = parentmodule(fn)
    module_key(home)
end

function is_producer_call(call, producer_name, home, file_mod)
    call.callee === producer_name || return false
    if isempty(call.qualifier)
        return file_mod === home
    end
    parts = split(call.qualifier, ".")
    tail = last(parts)
    home_text = string(home)
    tail == home_text
end

function emit_uncached!(found, producer_name, file, site_name, call)
    line = call.line
    line_text = string(line)
    site = file.path * ":" * line_text
    evidence = Pair{Symbol,String}[:derived => producer_name, :site => site]
    symbol = string(site_name)
    detail = "the producer is called in a method that does not write the cache"
    finding = Finding(file.mod, :uncached_call, file.path, symbol, line, detail, evidence)
    push!(found, finding)
end

function append_uncached!(found, declared, index, ::Nothing)
    return
end

function append_uncached!(found, declared, index, cache::Symbol)
    forms = index_forms(index)
    writers = cache_writers(forms, cache)
    producer = declared.producer
    home = producer_home(producer)
    producer_name = nameof(producer)
    declared_name = string(producer_name)
    for file in index.files
        for (site, calls) in file.scan.callsites
            key = (file.path, site)
            key in writers && continue
            for call in calls
                is_producer_call(call, producer_name, home, file.mod) || continue
                emit_uncached!(found, declared_name, file, site.name, call)
            end
        end
    end
end

function uncached_call_findings(ctx)
    found = Finding[]
    for declared in ctx.derived
        append_uncached!(found, declared, ctx.index, declared.cache)
    end
    found
end
