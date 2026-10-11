# Arguments, locals and parameter positions no code reads, judged on the scoped walk's record of each binding and of
# each read with the binding it resolves to; a macro from outside the language by what its expansion writes.

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

# Stands for every name: code a splice computes into the form's own body, as `@eval` code holds, or a macro whose
# expansion failed, may read any.
const EVERY_NAME = Symbol("\$")

# A syntax node and the module its macro calls expand in, which decides the expansion.
struct ExpandedIn
    node::JS.SyntaxNode           # a macro call, or a form holding macro calls
    home::Union{Nothing,Module}   # module the calls expand in; nothing when none is loaded
end

# What one UnusedBindings run reads off macro calls, each call expanded at most once per module and only when a
# binding's verdict waits on it.
struct MacroReads
    root::Module                                                # the package, whose loaded modules expand the calls
    expansions::IdDict{ExpandedIn,Union{Nothing,Set{Symbol}}}   # call -> names its expansion writes; nothing on a throw
    written::IdDict{ExpandedIn,Set{Symbol}}                     # form -> names its macro calls write
end

function MacroReads(root::Module)
    expansions = IdDict{ExpandedIn,Union{Nothing,Set{Symbol}}}()
    written = IdDict{ExpandedIn,Set{Symbol}}()
    MacroReads(root, expansions, written)
end

# A macro Base or Core binds; its expansion reads only the names its call writes.
function is_base_macro(call)
    name = macro_call_name(call)
    isnothing(name) && return false
    isdefined(Base, name) || isdefined(Core, name)
end

# A macro from outside the language: only its expansion shows what it reads.
function is_foreign_macro(node)
    JS.kind(node) == K"macrocall" || return false
    is_argument_hint(node) && return false
    !is_base_macro(node)
end

# The foreign macro calls under `node` that run with the form: outside quoted code, each outside any other.
function foreign_macro_calls!(calls, node)
    JS.kind(node) == K"quote" && return calls
    if is_foreign_macro(node)
        push!(calls, node)
        return calls
    end
    children = child_nodes(node)
    isnothing(children) && return calls
    for child in children
        foreign_macro_calls!(calls, child)
    end
    calls
end

# The process's stdout and stderr are one pair every task shares, so one expansion at a time swaps them.
const EXPANSION_LOCK = ReentrantLock()

# The code `macroexpand` makes of a call in `home`, as `Some`, since a macro may expand to `nothing`; nothing when the
# package's macro throws. What it prints is discarded.
function macro_expansion(home::Module, call)
    expression = Expr(call)
    try
        lock(EXPANSION_LOCK) do
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    expanded = macroexpand(home, expression)
                    Some(expanded)
                end
            end
        end
    catch failure
        failure isa InterruptException && rethrow()
        nothing
    end
end

# The names expanded code writes: a symbol, a quoted symbol, or a global reference's name.
add_written!(names, value::Symbol) = push!(names, value)
add_written!(names, value::QuoteNode) = add_written!(names, value.value)
add_written!(names, value::GlobalRef) = push!(names, value.name)
add_written!(names, @nospecialize(_value)) = names

function add_written!(names, value::Expr)
    for argument in value.args
        add_written!(names, argument)
    end
    names
end

function expansion_names!(reads::MacroReads, home, call)
    key = ExpandedIn(call, home)
    get!(reads.expansions, key) do
        isnothing(home) && return nothing
        expansion = macro_expansion(home, call)
        isnothing(expansion) && return nothing
        add_written!(Set{Symbol}(), something(expansion))
    end
end

# Every word a Base macro call or a command string writes inside a form, raw text included, and every name a foreign
# macro call's expansion in `home` writes.
function macro_names(form, home, reads::MacroReads)
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
            is_base_macro(node) || continue
        elseif kind != K"cmdstring"
            continue
        end
        text = JS.sourcetext(node)
        for word in eachmatch(WORD, text)
            push!(names, Symbol(word.match))
        end
    end
    EVERY_NAME in names && return names
    for call in foreign_macro_calls!(JS.SyntaxNode[], form)
        expanded = expansion_names!(reads, home, call)
        isnothing(expanded) && return push!(names, EVERY_NAME)
        union!(names, expanded)
    end
    names
end

function written_names(reads::MacroReads, form, home)
    key = ExpandedIn(form, home)
    get!(() -> macro_names(form, home, reads), reads.written, key)
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
function is_unread(binding::LocalBinding, reads_of, reads::MacroReads, home)
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
    written = written_names(reads, binding.method, home)
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

function add_unused_findings!(findings, file::FileNode, reads_of, reads::MacroReads)
    home = loaded_module(reads.root, file.mod)
    for binding in file.scan.bindings
        is_unread(binding, reads_of, reads, home) || continue
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

# The identifier of a position no read resolves to, `:unnamed` for a bare `::T`; nothing when a read does.
function unread_node(argument, signature, reads_of)
    carries_read_parameter(argument, signature, reads_of) && return nothing
    node = position_node(argument)
    node === :unnamed && return node
    isnothing(node) && return nothing
    get(reads_of, node, 0) > 0 && return nothing
    node
end

function cached_path!(paths, file, repo)
    cached = get(paths, file, nothing)
    isnothing(cached) || return cached
    path = recorded_path(file, repo)
    paths[file] = path
    path
end

# The parsed form a loaded method was defined by; nothing when the index holds none at its site.
function site_form(index::SourceIndex, method::Method, paths)
    path = cached_path!(paths, method.file, index.repo)
    key = (path, Int(method.line))
    held = get(index.forms, key, NO_PLACED_FORMS)
    for placed in held
        site_names_method(placed.site, method) && return placed.form
    end
    nothing
end

# Each position a method leaves unread, read off its parsed form once; none for a method the parse holds no form
# for, a `@generated` one, or a vararg tail.
function unread_positions(method::Method, index::SourceIndex, paths, reads_of, reads::MacroReads)
    unread = falses(Int(method.nargs) - 1)
    form = site_form(index, method, paths)
    isnothing(form) && return unread
    is_generated_form(form) && return unread
    signature = first(child_nodes(form))
    parts = call_parts(signature)
    isnothing(parts) && return unread
    arguments = filter(argument -> JS.kind(argument) != K"parameters", parts.arguments)
    last_named = method.isva ? length(unread) - 1 : length(unread)
    for position in 1:min(last_named, length(arguments))
        node = unread_node(arguments[position], signature, reads_of)
        isnothing(node) && continue
        if node === :unnamed
            unread[position] = true
            continue
        end
        written = written_names(reads, form, method.module)
        unread[position] = !(EVERY_NAME in written) && !(node.val in written)
    end
    unread
end

function position_type(method::Method, position::Int)
    parameters = signature_types(method.sig)
    under_clauses_of(parameters[position + 1], method.sig)
end

function group_owned!(found, owned, methods)
    for method in methods
        value = method_function(method)
        isnothing(value) && continue
        value in owned || continue
        held = get!(Vector{Method}, found, value)
        push!(held, method)
    end
    found
end

# Each live method of each function the package owns: the methods its modules define, then the ones other modules add.
function owned_methods(defined, added, owned)
    found = IdDict{Function,Vector{Method}}()
    group_owned!(found, owned, defined)
    group_owned!(found, owned, added)
    found
end

# Whether every method declares `position` as `declared`. Unspecialized: a type value is its own type, so a closure
# capturing it would compile once per declared type.
function shares_declared_type(methods, position::Int, @nospecialize(declared))
    for method in methods
        position_type(method, position) == declared || return false
    end
    true
end

# Each position every method of a package-owned function leaves unread under one declared type.
function add_ignored_findings!(findings, value::Function, all_methods, project, index, paths, reads_of, reads)
    own = filter(method -> method.module in project, all_methods)
    isempty(own) && return findings
    sorted = sort(own, by = method -> (string(method.file), method.line))
    home = first(sorted)
    unread = [unread_positions(method, index, paths, reads_of, reads) for method in all_methods]
    widest = maximum(length, unread)
    function_name = written_name(nameof(value))
    owner = module_key(home.module)
    for position in 1:widest
        all(flags -> position <= length(flags) && flags[position], unread) || continue
        declared = position_type(home, position)
        shares_declared_type(all_methods, position, declared) || continue
        file, line = method_site(home, index.repo)
        symbol = string(function_name, ":", position)
        detail = "every method of the function leaves this position unread under one declared type"
        count = string(length(all_methods))
        evidence = [:position => string(position), :methods => count, :type => string(declared)]
        finding = Finding(owner, :ignored_parameter, file, symbol, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

function check_unused_bindings(index::SourceIndex, defined, added, project, owned, root::Module)
    reads_of = read_counts(index)
    reads = MacroReads(root)
    findings = Finding[]
    for file in index.files
        add_unused_findings!(findings, file, reads_of, reads)
    end
    paths = Dict{Symbol,String}()
    for (value, all_methods) in owned_methods(defined, added, owned)
        add_ignored_findings!(findings, value, all_methods, project, index, paths, reads_of, reads)
    end
    findings
end
