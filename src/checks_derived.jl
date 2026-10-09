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
    found = Finding[]
    for declared in ctx.derived
        append_cache!(found, declared, ctx.index, ctx.root)
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

function function_forms(index, fn)
    found = LocatedForm[]
    for method in methods(fn)
        located = method_form(index, method)
        isnothing(located) && continue
        push!(found, located)
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

# A return annotation names the type. With no annotation, the type is a package type the method constructs.
function second_producer_findings(ctx)
    forms = index_forms(ctx.index)
    types = Set{Symbol}()
    for file in ctx.index.files
        union!(types, file.scan.types)
    end
    found = Finding[]
    detail = "a second method constructs the derived value"
    for declared in ctx.derived
        owned = function_forms(ctx.index, declared.producer)
        annotated = Set{Symbol}()
        constructed = Set{Symbol}()
        for placed in owned
            named = annotated_return(placed.form)
            isnothing(named) || push!(annotated, named)
            if placed.site.name in types
                push!(constructed, placed.site.name)
            end
            calls = get(placed.file.scan.callsites, placed.site, CallSite[])
            for call in calls
                call.callee in types || continue
                push!(constructed, call.callee)
            end
        end
        returned = constructed
        if !isempty(annotated)
            returned = annotated
        end
        isempty(returned) && continue
        owned_nodes = Set(placed.form for placed in owned)
        producer_name = string(nameof(declared.producer))
        for placed in forms
            placed.form in owned_nodes && continue
            named = annotated_return(placed.form)
            matched = false
            if !isnothing(named) && named in returned
                matched = true
            elseif placed.site.name in returned
                matched = true
            else
                calls = get(placed.file.scan.callsites, placed.site, CallSite[])
                for call in calls
                    call.callee in returned || continue
                    matched = true
                    break
                end
            end
            matched || continue
            labels = String[]
            for producer in owned
                label = string(producer.site.name, "@", source_line(producer.form))
                push!(labels, label)
            end
            line = source_line(placed.form)
            second_label = string(placed.site.name, "@", line)
            push!(labels, second_label)
            sort!(labels)
            unique!(labels)
            joined = join(labels, " ")
            symbol = string(placed.site.name)
            evidence = Pair{Symbol,String}[:derived => producer_name, :producers => joined]
            finding = Finding(placed.file.mod, :second_producer, placed.file.path, symbol, line, detail, evidence)
            push!(found, finding)
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
            kids = child_nodes(node)
            isnothing(kids) && continue
            length(kids) == 2 || continue
            head = kids[1]
            parts = child_nodes(head)
            isnothing(parts) && continue
            isempty(parts) && continue
            parts[1].val === :memoize || continue
            argument = kids[2]
            for form in forms
                argument === form && return true
            end
        end
    end
    false
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
    value isa Type || return nothing
    value
end

function is_mutable_key(key_type::DataType)
    isstructtype(key_type) || return false
    ismutabletype(key_type) || return false
    found = methods(hash, Tuple{key_type, UInt})
    for method in found
        signature = Base.unwrap_unionall(method.sig)
        parameters = signature.parameters
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
            kids = child_nodes(node)
            isnothing(kids) && continue
            isempty(kids) && continue
            naming = name_of_head(kids[1])
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

function collect_read_names!(names, args, root)
    for node in walk_nodes(root)
        value = node.val
        if !isnothing(args) && value isa Symbol && value in args
            push!(names, value)
        end
        JS.kind(node) == K"." || continue
        kids = child_nodes(node)
        isnothing(kids) && continue
        length(kids) == 2 || continue
        member = kids[2].val
        member isa Symbol || continue
        push!(names, member)
    end
end

function signature_names(form)
    kids = child_nodes(form)
    isnothing(kids) && return Symbol[]
    sig_argnames(kids[1])
end

function omitted_names(producer_forms, key_forms)
    reads = Set{Symbol}()
    for placed in producer_forms
        body = method_body(placed.form)
        isnothing(body) && continue
        args = signature_names(placed.form)
        arg_set = Set(args)
        collect_read_names!(reads, arg_set, body)
    end
    taken = Set{Symbol}()
    for placed in key_forms
        args = signature_names(placed.form)
        union!(taken, args)
        body = method_body(placed.form)
        isnothing(body) && continue
        collect_read_names!(taken, nothing, body)
    end
    missing = setdiff(reads, taken)
    sort!(collect(missing))
end

# An isbits address still compares by identity. A content key is an isbits value other than an address.
function key_returns_bits(key)
    results = Base.return_types(key)
    isempty(results) && return true
    for result in results
        result isa DataType || return false
        result <: Ptr && return false
        isbitstype(result) || return false
    end
    true
end

function form_place(placed)
    line = source_line(placed.form)
    (placed.file.path, line)
end

function extend_key!(problems, omitted, owned, index, pkg, ::Nothing) end

function extend_key!(problems, omitted, owned, index, pkg, key::Function)
    key_forms = function_forms(index, key)
    note_identity_cache!(problems, key_forms, pkg)
    key_returns_bits(key) || push!(problems, "not_isbits")
    missing = omitted_names(owned, key_forms)
    append!(omitted, missing)
end

function emit_cache!(found, producer_name, problem, anchor, evidence)
    detail = CACHE_DETAIL[problem]
    line = source_line(anchor.form)
    finding = Finding(anchor.file.mod, :cache_key, anchor.file.path, producer_name, line, detail, evidence)
    push!(found, finding)
end

function append_cache!(found, declared, index, pkg)
    owned = function_forms(index, declared.producer)
    isempty(owned) && return
    anchor = argmin(form_place, owned)
    problems = Set{String}()
    omitted = Symbol[]
    note_identity_cache!(problems, owned, pkg)
    extend_key!(problems, omitted, owned, index, pkg, declared.key)
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
        kids = child_nodes(node)
        isnothing(kids) && continue
        length(kids) < 2 && continue
        lhs = kids[1]
        JS.kind(lhs) == K"." || continue
        parts = child_nodes(lhs)
        isnothing(parts) && continue
        length(parts) == 2 || continue
        parts[2].val === cache && return true
    end
    false
end

function append_uncached!(found, declared, index, ::Nothing) end

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

