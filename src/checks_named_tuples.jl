# Named tuple crossings: a function hands back a named tuple literal, and another file keeps the result as a record
# whose fields no type declares

"""Configured through `gate(...; checks)`. A top-level function hands back a named tuple literal, as a `return` value or as its body's last expression, and another file keeps the result: a file of another module that reads the function, or a file of its own module with a call that does not destructure the result by name where it lands (`(; a, b) = f(x)` or `for (; a, b) in f(x)`). `allowed` lists the (repo-relative path, function name) pairs the package hands back as named tuples on purpose; a pair naming no such function is a stale allowance, an error as `CallerAllowlist`'s is"""
struct NamedTupleCrossings{A<:NTuple{N,Tuple{String,Symbol}} where N} <: Check
    allowed::A   # (repo-relative path, function name) pairs that hand back named tuples on purpose
end

function NamedTupleCrossings(; allowed = ())
    pairs = definition_pairs(allowed)
    NamedTupleCrossings(pairs)
end

# `CallerAllowlist` declares `stale_allowance` an error too, so either check running leaves it one severity
kinds(::NamedTupleCrossings) = (:named_tuple_crossing => :advisory, :stale_allowance => :error)

# One compiled run for every length of `allowed`
function run(@nospecialize(check::NamedTupleCrossings), ctx)
    allowed = collect(Tuple{String,Symbol}, check.allowed)
    check_named_tuple_crossings(ctx.index, ctx.root, allowed)
end

# One method of a top-level function that hands back a named tuple literal
struct NamedTupleProducer
    owner::Symbol    # key of the module the function's file belongs to
    name::Symbol     # the function's name
    path::String     # repo-relative path of the method
    line::Int        # source line of the method
    fields::String   # the first literal's fields as written, comma-joined
end

# A named tuple literal, `(; a, b)` or `(a = x, b = y)`
function is_named_tuple(node)
    JS.kind(node) == K"tuple" || return false
    slots = child_nodes(node)
    child_count(slots) > 0 || return false
    opening = first(slots)
    JS.kind(opening) == K"parameters" && return true
    all(slot -> JS.kind(slot) == K"=", slots)
end

# Each `return` value, past nested methods, closures and quoted code
function returned_values!(handed, node)
    kind = JS.kind(node)
    is_nested = is_method_form(node) || kind == K"->" || kind == K"do" || kind == K"quote"
    is_nested && return handed
    children = child_nodes(node)
    isnothing(children) && return handed
    is_return = kind == K"return" && child_count(children) == 1
    is_return && push!(handed, only(children))
    for child in children
        returned_values!(handed, child)
    end
    handed
end

# The last expression, through each block's final statement, each branch's arms, a comprehension's element and the
# closures a call passes, as `map(xs) do x ... end` builds its elements
function tail_values!(handed, node)
    kind = JS.kind(node)
    children = child_nodes(node)
    if kind == K"block" || kind == K"let"
        child_count(children) > 0 && tail_values!(handed, last(children))
    elseif is_branch_kind(kind)
        for arm in children[2:end]
            tail_values!(handed, arm)
        end
    elseif kind == K"comprehension" || kind == K"generator"
        tail_values!(handed, first(children))
    elseif kind == K"call"
        for argument in children
            argument_kind = JS.kind(argument)
            argument_kind == K"do" || argument_kind == K"->" || continue
            closure_parts = child_nodes(argument)
            tail_values!(handed, last(closure_parts))
        end
    elseif kind != K"return"
        push!(handed, node)
    end
    handed
end

# What a method body hands back: its `return` values and its last expression, and each value assigned to a local it
# hands back
function handed_back(body)
    handed = JS.SyntaxNode[]
    returned_values!(handed, body)
    tail_values!(handed, body)
    held = Set{Symbol}()
    for node in handed
        name = node_symbol(node)
        isnothing(name) || push!(held, name)
    end
    for node in walk_nodes(body)
        JS.kind(node) == K"=" || continue
        sides = child_nodes(node)
        child_count(sides) == 2 || continue
        target = node_symbol(first(sides))
        target in held && push!(handed, last(sides))
    end
    handed
end

# A named tuple literal's fields as written, in order: `a` in `a = x`, `s.b` in `(; s.b)`
function field_names(literal)
    slots = child_nodes(literal)
    opening = first(slots)
    entries = JS.kind(opening) == K"parameters" ? child_nodes(opening) : slots
    fields = String[]
    for entry in entries
        is_assigned = JS.kind(entry) == K"="
        named = is_assigned ? first(child_nodes(entry)) : entry
        text = JS.sourcetext(named)
        push!(fields, String(text))
    end
    fields
end

# Each method of a top-level function that hands back a named tuple literal, in file order
function named_tuple_producers(index::SourceIndex)
    producers = NamedTupleProducer[]
    for file in index.files
        sites = sort!(collect(keys(file.scan.forms)); by = site -> site.line)
        for site in sites
            site.name in file.scan.funcs || continue
            form = file.scan.forms[site]
            isnothing(enclosing_form(form)) || continue
            body = method_body(form)
            isnothing(body) && continue
            handed = handed_back(body)
            literal = findfirst(is_named_tuple, handed)
            isnothing(literal) && continue
            fields = field_names(handed[literal])
            joined = join(fields, ",")
            producer = NamedTupleProducer(file.mod, site.name, file.path, site.line, joined)
            push!(producers, producer)
        end
    end
    producers
end

# Whether a call's result is destructured by name where it lands, `(; a, b) = f(x)` or `for (; a, b) in f(x)`
function is_destructured(call)
    holder = call.parent
    isnothing(holder) && return false
    holder_kind = JS.kind(holder)
    holder_kind == K"=" || holder_kind == K"in" || return false
    parts = child_nodes(holder)
    child_count(parts) == 2 && last(parts) === call || return false
    target = first(parts)
    JS.kind(target) == K"tuple" || return false
    slots = child_nodes(target)
    child_count(slots) > 0 && JS.kind(first(slots)) == K"parameters"
end

# Whether an identifier is `name` as the module binds it, rather than a local of that name
is_global_name(scan::FileScan, node, name::Symbol) = node_symbol(node) === name && isnothing(local_binding(scan, node))

# Where a file reads `name` past its imports, method signatures and quoted code: each call of it, and the bare name
# passed as a value
function call_sites(file::FileNode, name::Symbol)
    signatures = Base.IdSet{JS.SyntaxNode}()
    for node in walk_nodes(file.tree)
        is_method_form(node) || continue
        signature = first(child_nodes(node))
        call = signature_call(signature)
        isnothing(call) || push!(signatures, call)
    end
    sites = JS.SyntaxNode[]
    call_sites!(sites, file.scan, file.tree, name, signatures)
end

function call_sites!(sites, scan::FileScan, node, name, signatures)
    kind = JS.kind(node)
    (kind == K"import" || kind == K"using" || kind == K"quote") && return sites
    is_global_name(scan, node, name) && push!(sites, node)
    children = child_nodes(node)
    isnothing(children) && return sites
    if kind == K"call" || kind == K"dotcall"
        callee = callee_node(node)
        is_called = !isnothing(callee) && is_global_name(scan, callee, name)
        is_called && !(node in signatures) && push!(sites, node)
        for child in children
            is_called && child === callee && continue
            call_sites!(sites, scan, child, name, signatures)
        end
    elseif kind == K"."
        # `x.name` reads a field: only the object is a read
        call_sites!(sites, scan, first(children), name, signatures)
    else
        for child in children
            call_sites!(sites, scan, child, name, signatures)
        end
    end
    sites
end

# Whether a file's code reads `name`, in its definitions or outside them
function reads_name(scan::FileScan, name::Symbol)
    name in scan.modrefs && return true
    any(read_names -> name in read_names, values(scan.refs))
end

# Whether a file of another module reaches the producer: through a qualified path or an import clause the index
# records, or through a binding its module takes from the producer's
function reaches_producer(file::FileNode, root::Module, producer::NamedTupleProducer, qualified)
    is_qualified = (file.mod, producer.owner, file.path, producer.name) in qualified
    is_qualified && return true
    producing = loaded_module(root, producer.owner)
    isnothing(producing) && return false
    reading = loaded_module(root, file.mod)
    isnothing(reading) && return false
    binding_owner(reading, producer.name) === producing
end

# The files that keep what the producer hands back, sorted
function keeping_files(index::SourceIndex, root::Module, producer::NamedTupleProducer, qualified)
    kept = Set{String}()
    for file in index.files
        file.path == producer.path && continue
        reads_name(file.scan, producer.name) || continue
        is_same = file.mod === producer.owner
        is_same || reaches_producer(file, root, producer, qualified) || continue
        sites = call_sites(file, producer.name)
        is_ended = site -> is_same && JS.kind(site) == K"call" && is_destructured(site)
        all(is_ended, sites) && continue
        push!(kept, file.path)
    end
    sort!(collect(kept))
end

# Each (from, to, file, name) a qualified path or an import clause of the index reads
function qualified_reads(index::SourceIndex)
    reads = Set{Tuple{Symbol,Symbol,String,Symbol}}()
    for ref in index.refs, name in ref.names
        push!(reads, (ref.from, ref.to, ref.file, name))
    end
    reads
end

# An allowed pair at which no method hands back a named tuple literal; a file the index lacks is cited under the
# package's own module
function stale_crossing_allowance(index::SourceIndex, root::Module, pair)
    path, name = pair
    held = findfirst(file -> file.path == path, index.files)
    mod = isnothing(held) ? nameof(root) : index.files[held].mod
    symbol = string(name)
    detail = symbol * " is allowed to hand back a named tuple and hands back none"
    Finding(mod, :stale_allowance, path, symbol, 0, detail)
end

function check_named_tuple_crossings(index::SourceIndex, root::Module, allowed::Vector{Tuple{String,Symbol}})
    producers = named_tuple_producers(index)
    handing = Set((producer.path, producer.name) for producer in producers)
    findings = Finding[]
    for pair in allowed
        pair in handing && continue
        stale = stale_crossing_allowance(index, root, pair)
        push!(findings, stale)
    end
    qualified = qualified_reads(index)
    seen = Set{Tuple{Symbol,Symbol}}()
    for producer in producers
        key =(producer.owner, producer.name)
        key in seen && continue
        push!(seen, key)
        (producer.path, producer.name) in allowed && continue
        kept = keeping_files(index, root, producer, qualified)
        isempty(kept) && continue
        evidence = [:fields => producer.fields, :called_in => join(kept, ",")]
        symbol = string(producer.name)
        detail = "hands back a named tuple another file keeps"
        finding = Finding(producer.owner, :named_tuple_crossing, producer.path, symbol, producer.line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
