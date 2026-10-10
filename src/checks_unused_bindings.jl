# Arguments, locals and parameter positions no code reads, judged on the scoped walk's record of each binding and of
# each read with the binding it resolves to.

# How many reads resolve to each binding, by its declaring identifier, across the package's code.
function read_counts(index::SourceIndex)
    counts = IdDict{JS.SyntaxNode,Int}()
    for file in index.files, name_read in file.scan.reads
        is_local_read(name_read) || continue
        held = get(counts, name_read.binding, 0)
        counts[name_read.binding] = held + 1
    end
    counts
end

# The nearest method, macro or closure form around a node.
function enclosing_form(node)
    current = node.parent
    while !isnothing(current) && !is_argument_form(current)
        current = current.parent
    end
    current
end

# Whether a node sits in a form of `kind` below `stop`; an argument hint around it is no macro call.
function has_ancestor(node, kind, stop)
    current = node.parent
    while !isnothing(current) && current !== stop
        is_hint = is_argument_hint(current)
        !is_hint && JS.kind(current) == kind && return true
        current = current.parent
    end
    false
end

# A `@generated` method's arguments reach its generated code, which no reading here sees.
function is_generated_form(form)
    parent = form.parent
    isnothing(parent) && return false
    JS.kind(parent) == K"macrocall" || return false
    macro_call_name(parent) === Symbol("@generated")
end

function runs_at(form)
    current = form
    while !isnothing(current)
        is_argument_form(current) && is_generated_form(current) && return "compile time"
        current = current.parent
    end
    "call time"
end

const WORD = r"[A-Za-z_][A-Za-z0-9_]*"

# Stands for every name: code a splice computes into the form's own body, as `@eval` code holds, or a macro from
# outside Base and Core expands to, may read any.
const EVERY_NAME = Symbol("\$")

# A macro Base or Core binds; its expansion reads only the names its call writes.
function is_base_macro(call)
    name = macro_call_name(call)
    isnothing(name) && return false
    isdefined(Base, name) || isdefined(Core, name)
end

# Every word a macro call or a command string writes inside a form, raw text included: the macro may read any name
# it is given.
function macro_names(form)
    names = Set{Symbol}()
    signature = first(child_nodes(form))
    for node in walk_nodes(form)
        kind = JS.kind(node)
        if kind == K"$"
            node_inside(node, signature) || push!(names, EVERY_NAME)
            continue
        end
        if kind == K"macrocall"
            is_argument_hint(node) && continue
            is_base_macro(node) || push!(names, EVERY_NAME)
        elseif kind != K"cmdstring"
            continue
        end
        text = JS.sourcetext(node)
        for word in eachmatch(WORD, text)
            push!(names, Symbol(word.match))
        end
    end
    names
end

# The name a finding gives a binding: the nearest named method, macro or callable around it.
function owner_name(form, fallback)
    current = form
    while !isnothing(current)
        if JS.kind(current) == K"macro"
            named = sig_name(first(child_nodes(current)))
            isnothing(named) || return string("@", named)
        elseif is_method_form(current)
            named = method_name_of(first(child_nodes(current)))
            isnothing(named) || return string(named)
        end
        current = current.parent
    end
    string(fallback)
end

# A binding no read resolves to and no macro call writes, in code a method, macro or closure holds.
function is_unread(binding::LocalBinding, reads_of, macros)
    is_judged = binding.kind === :argument || binding.kind === :local
    is_judged || return false
    isnothing(binding.method) && return false
    text = string(binding.name)
    # A `catch` with no variable holds an empty name in the variable's place.
    isempty(text) && return false
    startswith(text, "_") && return false
    haskey(reads_of, binding.node) && return false
    has_ancestor(binding.node, K"quote", nothing) && return false
    has_ancestor(binding.node, K"macrocall", binding.method) && return false
    written = get!(() -> macro_names(binding.method), macros, binding.method)
    EVERY_NAME in written && return false
    !(binding.name in written)
end

function unused_finding(file::FileNode, binding::LocalBinding, form)
    kind = binding.kind === :argument ? :unused_argument : :unused_local
    symbol = string(owner_name(form, binding.def), ":", binding.name)
    detail = kind === :unused_argument ? "the method never reads this argument" :
             "the method assigns this local and never reads it"
    evidence = [:name => string(binding.name), :runs_at => runs_at(form)]
    Finding(file.mod, kind, file.path, symbol, binding.line, detail, evidence)
end

function add_unused_findings!(findings, file::FileNode, reads_of, macros)
    for binding in file.scan.bindings
        is_unread(binding, reads_of, macros) || continue
        form = enclosing_form(binding.node)
        is_generated = binding.kind === :argument && is_generated_form(form)
        is_generated && continue
        finding = unused_finding(file, binding, form)
        push!(findings, finding)
    end
    findings
end

# The identifier a positional argument binds at its slot, `:unnamed` for a bare `::T`, nothing when the slot names
# no single identifier the walk binds.
function position_node(argument)
    kind = JS.kind(argument)
    children = child_nodes(argument)
    kind == K"=" && return position_node(first(children))
    is_argument_hint(argument) && return position_node(last(children))
    if kind == K"::"
        length(children) == 1 && return :unnamed
        return position_node(first(children))
    end
    isnothing(node_symbol(argument)) && return nothing
    argument
end

# Whether a position's annotation names a `where` parameter some read outside that annotation resolves to.
function carries_read_parameter(argument, signature, reads_of)
    parameters = Bindings()
    where_vars!(parameters, signature)
    for (name, node) in parameters.declared
        inside = count(inner -> node_symbol(inner) === name, walk_nodes(argument))
        get(reads_of, node, 0) > inside && return true
    end
    false
end

function ignores_argument(argument, signature, written, reads_of)
    carries_read_parameter(argument, signature, reads_of) && return false
    node = position_node(argument)
    node === :unnamed && return true
    isnothing(node) && return false
    get(reads_of, node, 0) > 0 && return false
    EVERY_NAME in written && return false
    !(node.val in written)
end

"""Each parsed method form by its file and line, read once, so a loaded method finds its form in one lookup."""
struct FormSites
    forms::Dict{Tuple{String,Int},Vector{Pair{MethodSite,JS.SyntaxNode}}}   # (path, line) -> the forms defined there
    paths::Dict{Symbol,String}                                              # a recorded file -> its repo-relative path
    repo::String                                                            # root the paths are relative to
end

function FormSites(index::SourceIndex)
    forms = Dict{Tuple{String,Int},Vector{Pair{MethodSite,JS.SyntaxNode}}}()
    for file in index.files, (site, form) in file.scan.forms
        held = get!(Vector{Pair{MethodSite,JS.SyntaxNode}}, forms, (file.path, site.line))
        push!(held, site => form)
    end
    FormSites(forms, Dict{Symbol,String}(), index.repo)
end

# The parsed form a loaded method was defined by; nothing when the parse holds none at its site.
function site_form(sites::FormSites, method::Method)
    path = get!(() -> recorded_path(method.file, sites.repo), sites.paths, method.file)
    key = (path, Int(method.line))
    for (site, form) in get(sites.forms, key, ())
        site_names_method(site, method) && return form
    end
    nothing
end

# Each position a method leaves unread, read off its parsed form once; none for a method the parse holds no form
# for, a `@generated` one, or a vararg tail.
function unread_positions(method::Method, sites::FormSites, reads_of)
    unread = falses(Int(method.nargs) - 1)
    form = site_form(sites, method)
    isnothing(form) && return unread
    is_generated_form(form) && return unread
    signature = first(child_nodes(form))
    parts = call_parts(signature)
    isnothing(parts) && return unread
    arguments = filter(argument -> JS.kind(argument) != K"parameters", parts.arguments)
    written = macro_names(form)
    last_named = method.isva ? length(unread) - 1 : length(unread)
    for position in 1:min(last_named, length(arguments))
        unread[position] = ignores_argument(arguments[position], signature, written, reads_of)
    end
    unread
end

function position_type(method::Method, position::Int)
    parameters = signature_types(method.sig)
    under_clauses_of(parameters[position + 1], method.sig)
end

# Each live method of each function the package owns, every module's included, from one walk of the method table.
function owned_methods(defined, project)
    owned = IdSet{Function}()
    for method in defined
        value = method_function(method)
        isnothing(value) && continue
        parentmodule(value) in project || continue
        is_generated_name(nameof(value)) && continue
        push!(owned, value)
    end
    found = IdDict{Function,Vector{Method}}()
    each_loaded_method() do method
        is_latest(method) || return
        value = method_function(method)
        isnothing(value) && return
        value in owned || return
        held = get!(Vector{Method}, found, value)
        push!(held, method)
    end
    found
end

# Each position every method of a package-owned function leaves unread under one declared type.
function add_ignored_findings!(findings, value::Function, all_methods, project, sites, reads_of)
    own = filter(method -> method.module in project, all_methods)
    isempty(own) && return findings
    sorted = sort(own, by = method -> (string(method.file), method.line))
    home = first(sorted)
    unread = [unread_positions(method, sites, reads_of) for method in all_methods]
    widest = maximum(length, unread)
    function_name = written_name(nameof(value))
    owner = module_key(home.module)
    for position in 1:widest
        all(flags -> position <= length(flags) && flags[position], unread) || continue
        declared = position_type(home, position)
        all(method -> position_type(method, position) == declared, all_methods) || continue
        file, line = method_site(home, sites.repo)
        symbol = string(function_name, ":", position)
        detail = "every method of the function leaves this position unread under one declared type"
        count = string(length(all_methods))
        evidence = [:position => string(position), :methods => count, :type => string(declared)]
        finding = Finding(owner, :ignored_parameter, file, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

function check_unused_bindings(index::SourceIndex, defined, mods)
    project = Set{Module}(mods)
    reads_of = read_counts(index)
    macros = IdDict{JS.SyntaxNode,Set{Symbol}}()
    findings = Finding[]
    for file in index.files
        add_unused_findings!(findings, file, reads_of, macros)
    end
    sites = FormSites(index)
    for (value, all_methods) in owned_methods(defined, project)
        add_ignored_findings!(findings, value, all_methods, project, sites, reads_of)
    end
    findings
end
