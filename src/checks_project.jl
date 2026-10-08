# Parameterized checks a package configures: who may call a name, which public functions return a
# sentinel, and where a string-keyed dictionary carries another value.

struct CallerWhitelist{C<:NTuple{N,Symbol} where N, A<:NTuple{M,Tuple{String,Symbol}} where M, E<:NTuple{K,String} where K} <: Check
    callees::C       # function names a body may reference only from an allowed def
    allowed::A       # (repo-relative path, def name) pairs that may reference them
    exempt_dirs::E   # path prefixes skipped entirely
end

function CallerWhitelist(callees, allowed, exempt_dirs = ())
    names = Tuple(Symbol(name) for name in callees)
    pairs = Tuple((String(pair[1]), Symbol(pair[2])) for pair in allowed)
    prefixes = Tuple(String(prefix) for prefix in exempt_dirs)
    CallerWhitelist(names, pairs, prefixes)
end

struct SentinelReturns{D<:NTuple{N,String} where N, S<:NTuple{M,Symbol} where M} <: Check
    directories::D   # repo-relative directories whose public functions are read
    sentinels::S     # literal results that encode absence
end

function SentinelReturns(directories, sentinels = (:nothing, :Inf, :NaN, :missing))
    roots = Tuple(String(directory) for directory in directories)
    literals = Tuple(Symbol(name) for name in sentinels)
    SentinelReturns(roots, literals)
end

struct StringPayloads{D<:NTuple{N,String} where N} <: Check
    directories::D   # repo-relative directories read for a Dict{String,V} type
end

function StringPayloads(directories)
    roots = Tuple(String(directory) for directory in directories)
    StringPayloads(roots)
end

kinds(::CallerWhitelist) = (:unlisted_caller => :error,)
kinds(::SentinelReturns) = (:sentinel_return => :advisory,)
kinds(::StringPayloads) = (:string_payload => :advisory,)

# A path sits in a directory when it is that directory or a file inside it.
function is_under(path, directory)
    path == directory && return true
    prefix = endswith(directory, "/") ? directory : directory * "/"
    startswith(path, prefix)
end

# The index lists files under src, so a directory outside it has no file.
function require_covered(index, directory)
    for file in index.files
        is_under(file.path, directory) && return
    end
    message = "no indexed file under " * directory
    throw(ArgumentError(message))
end

# The directory's module, and every module nested in it, are where a name can be declared public.
function is_tree_public(ctx, root_key, name)
    root = string(root_key)
    nested = root * "."
    modules = package_modules(ctx)
    for mod in modules
        key = string(module_key(mod))
        in_tree = key == root || startswith(key, nested)
        in_tree || continue
        isdefined(mod, name) || continue
        Base.ispublic(mod, name) && return true
    end
    false
end

# A leading minus keeps the literal: -Inf is the sentinel Inf, written negated.
function is_sentinel_literal(node, sentinels)
    if node.val isa Symbol && node.val in sentinels
        return true
    end
    JS.kind(node) == K"call" || return false
    children = child_nodes(node)
    children === nothing && return false
    length(children) == 2 || return false
    op = children[1]
    op.val === :- || return false
    is_sentinel_literal(children[2], sentinels)
end

function sentinel_text(node)
    JS.sourcetext(node)
end

# Nested functions, closures and quotes keep their own bodies.
function returned_sentinel(node, sentinels)
    kind = JS.kind(node)
    kind == K"function" && return nothing
    kind == K"->" && return nothing
    kind == K"quote" && return nothing
    if kind == K"return"
        children = child_nodes(node)
        one_value = children !== nothing && length(children) == 1
        if one_value && is_sentinel_literal(children[1], sentinels)
            return sentinel_text(children[1])
        end
    end
    children = child_nodes(node)
    children === nothing && return nothing
    for child in children
        found = returned_sentinel(child, sentinels)
        isnothing(found) || return found
    end
    nothing
end

function last_body_expr(node)
    JS.kind(node) == K"block" || return node
    children = child_nodes(node)
    children === nothing && return nothing
    isempty(children) && return nothing
    tail = last(children)
    last_body_expr(tail)
end

function observed_sentinel(body, sentinels)
    returned = returned_sentinel(body, sentinels)
    isnothing(returned) || return returned
    tail = last_body_expr(body)
    isnothing(tail) && return nothing
    is_sentinel_literal(tail, sentinels) || return nothing
    sentinel_text(tail)
end

function method_at_top(node)
    kind = JS.kind(node)
    if kind == K"doc" || kind == K"macrocall"
        children = child_nodes(node)
        children === nothing && return nothing
        return method_at_top(last(children))
    end
    is_method_form(node) || return nothing
    node
end

function defined_name(node)
    children = child_nodes(node)
    children === nothing && return nothing
    isempty(children) && return nothing
    named = sig_name(children[1])
    isnothing(named) || return named
    callable_receiver(children[1])
end

function method_body(node)
    children = child_nodes(node)
    children === nothing && return nothing
    length(children) < 2 && return nothing
    children[2]
end

function is_dict_head(node)
    node.val === :Dict && return true
    JS.kind(node) == K"." || return false
    children = child_nodes(node)
    children === nothing && return false
    length(children) == 2 || return false
    children[2].val === :Dict
end

function is_string_payload(node)
    JS.kind(node) == K"curly" || return false
    children = child_nodes(node)
    children === nothing && return false
    length(children) == 3 || return false
    is_dict_head(children[1]) || return false
    children[2].val === :String || return false
    children[3].val !== :String
end

function run(check::CallerWhitelist, ctx)
    findings = Finding[]
    for prefix in check.exempt_dirs
        require_covered(ctx.index, prefix)
    end
    names = Set(check.callees)
    allowed = Set(check.allowed)
    for file in ctx.index.files
        any(prefix -> is_under(file.path, prefix), check.exempt_dirs) && continue
        for (def, used) in file.scan.refs
            called = intersect(used, names)
            isempty(called) && continue
            pair = (file.path, def)
            pair in allowed && continue
            called_names = collect(called)
            ordered = sort!(called_names; by = string)
            listed = join(ordered, " ")
            prose = join(ordered, ", ")
            detail = "calls " * prose
            line = Int(get(file.scan.line, def, 0))
            evidence = [:calls => listed]
            symbol = string(def)
            finding = Finding(file.mod, :unlisted_caller, file.path, symbol, line, detail, evidence)
            push!(findings, finding)
        end
    end
    findings
end

function run(check::SentinelReturns, ctx)
    findings = Finding[]
    seen = Set{Tuple{String,String}}()
    src_root = joinpath(ctx.index.repo, "src")
    for directory in check.directories
        require_covered(ctx.index, directory)
        probe = joinpath(ctx.index.repo, directory, "_.jl")
        root_key = module_of(probe, src_root, ctx.index.dir2mod)
        for file in ctx.index.files
            is_under(file.path, directory) || continue
            children = child_nodes(file.tree)
            children === nothing && continue
            for child in children
                def = method_at_top(child)
                isnothing(def) && continue
                name = defined_name(def)
                isnothing(name) && continue
                body = method_body(def)
                isnothing(body) && continue
                marker = observed_sentinel(body, check.sentinels)
                isnothing(marker) && continue
                key = isnothing(root_key) ? file.mod : root_key
                is_tree_public(ctx, key, name) || continue
                identity = (file.path, string(name))
                identity in seen && continue
                push!(seen, identity)
                line = source_line(def)
                detail = "returns " * marker
                evidence = [:sentinel => marker]
                symbol = string(name)
                finding = Finding(file.mod, :sentinel_return, file.path, symbol, line, detail, evidence)
                push!(findings, finding)
            end
        end
    end
    findings
end

function collect_payloads!(found, node)
    if is_string_payload(node)
        push!(found, node)
    end
    children = child_nodes(node)
    children === nothing && return
    for child in children
        collect_payloads!(found, child)
    end
end

function run(check::StringPayloads, ctx)
    findings = Finding[]
    for directory in check.directories
        require_covered(ctx.index, directory)
        for file in ctx.index.files
            is_under(file.path, directory) || continue
            nodes = JS.SyntaxNode[]
            collect_payloads!(nodes, file.tree)
            for node in nodes
                type_text = JS.sourcetext(node)
                line = source_line(node)
                detail = "a string-keyed dictionary holds " * type_text
                evidence = [:type => type_text]
                finding = Finding(file.mod, :string_payload, file.path, type_text, line, detail, evidence)
                push!(findings, finding)
            end
        end
    end
    findings
end
