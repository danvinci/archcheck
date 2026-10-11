# Interface checks: does a module declare what it publishes, and does anything reach past that declaration.
# A module that exports its whole namespace has no interface to hold, so nothing behind it can move.

function is_all_keyword(argument)
    JS.kind(argument) == K"=" || return false
    keyword_parts = child_nodes(argument)
    child_count(keyword_parts) < 2 && return false
    keyword_parts[1].val === :all && keyword_parts[2].val === true
end

function has_all_keyword(call_part)
    JS.kind(call_part) == K"parameters" || return false
    arguments = child_nodes(call_part)
    isnothing(arguments) && return false
    any(is_all_keyword, arguments)
end

# `@__MODULE__` with no arguments: the wrapper the call is written in.
function is_this_module_macro(argument)
    JS.kind(argument) == K"macrocall" || return false
    parts = child_nodes(argument)
    child_count(parts) == 1 || return false
    macro_name = first(parts)
    named_symbol(macro_name) === Symbol("@__MODULE__")
end

# A bare name or a dotted path that spells this wrapper's module.
function is_own_module_argument(argument, module_key)
    path = dotted_names(argument)
    isnothing(path) && return false
    written = join(path, ".")
    written_key = Symbol(written)
    written_key === module_key && return true
    length(path) == 1 || return false
    segments = key_segments(module_key)
    own_name = last(segments)
    only(path) === own_name
end

# `names(...; all = true)` lists this wrapper when its argument is `@__MODULE__` or the module's own name.
function is_blanket_names_call(node, module_key)
    JS.kind(node) == K"call" || return false
    call_parts = child_nodes(node)
    child_count(call_parts) == 0 && return false
    call_parts[1].val === :names || return false
    any(has_all_keyword, call_parts) || return false
    arguments = call_args(node)
    length(arguments) == 1 || return false
    subject = only(arguments)
    lists_this_module = is_this_module_macro(subject)
    lists_this_module && return true
    is_own_module_argument(subject, module_key)
end

function find_blanket_names(node, module_key)
    is_blanket_names_call(node, module_key) && return node
    children = child_nodes(node)
    isnothing(children) && return nothing
    for child in children
        found = find_blanket_names(child, module_key)
        isnothing(found) || return found
    end
    nothing
end

function check_blanket_exports(index::SourceIndex)
    findings = Finding[]
    for file in index.files
        is_wrapper(file) || continue
        hit = find_blanket_names(file.tree, file.mod)
        isnothing(hit) && continue
        line = source_line(hit)
        detail = "module exports its whole namespace, so it declares no interface"
        push!(findings, Finding(file.mod, :blanket_export, file.path, "", line, detail))
    end
    findings
end

function ReachModules(modules, package::Module, allowed)
    by_key = Dict{Symbol,Module}()
    for loaded in modules
        key = module_key(loaded)
        by_key[key] = loaded
    end
    tracked = Set{Module}(modules)
    opened = Set{Module}(allowed)
    top = top_modules()
    ReachModules(by_key, tracked, package, opened, top)
end

# A module's name as a finding states it: its dotted key in the package, its full path outside it.
function module_label(named::Module, modules::ReachModules)
    named in modules.tracked && return string(module_key(named))
    path = fullname(named)
    join(path, ".")
end

# One piece of code references are read in: a source file's module code, or an entry script.
struct ReachUnit
    path::String          # repo-relative path, or an entry script's walked path
    tree::JS.SyntaxNode   # the code
    from::Symbol          # key of the module the code belongs to; :Entry for an entry script, its name for an extension
end

# The unit's code reading `name` through `through`; nothing when `through` is the code's own module or one the
# package reads on purpose, holds no such name, or declares it.
function reach_finding(modules::ReachModules, unit::ReachUnit, home, through::Module, name::Symbol, line, via::Symbol)
    through === home && return nothing
    through in modules.allowed && return nothing
    isdefined(through, name) || return nothing
    Base.ispublic(through, name) && return nothing
    defining = binding_owner(through, name)
    # A binding `through` imported from more than one module has no single owner; the module read through names it.
    labelled = isnothing(defining) ? through : defining
    owner = module_label(labelled, modules)
    reached = module_label(through, modules)
    symbol = "$reached.$name"
    detail = "reads a name through a module that neither exports it nor declares it public"
    evidence = [:via => string(via), :owner => owner]
    Finding(unit.from, :reaches_internal, unit.path, symbol, line, detail, evidence)
end

# Each name one clause reads, with the module it reads it through: its path's names after the opening, and each
# name a `:` list binds from the module that path names whole. A list from no module reads nothing.
function clause_reads(clause::ImportClause)
    reads = Tuple{Module,Symbol}[]
    named = named_module(clause)
    is_list = !isempty(clause.items)
    is_list && isnothing(named) && return reads
    for (step, through) in enumerate(clause.modules)
        position = clause.opening + step
        position > length(clause.path) && break
        push!(reads, (through, clause.path[position]))
    end
    add_listed_reads!(reads, named, clause.items)
end

function add_listed_reads!(reads, named::Module, items)
    for item in items, name in item.path
        push!(reads, (named, name))
    end
    reads
end

add_listed_reads!(reads, ::Nothing, _items) = reads

# Each name a using or import clause of the unit binds through a module, in a branch this Julia runs.
function clause_reaches!(findings, unit::ReachUnit, modules::ReachModules, home, clauses)
    for clause in clauses
        in_skipped_branch(clause.node, unit.tree) && continue
        for (through, name) in clause_reads(clause)
            found = reach_finding(modules, unit, home, through, name, clause.line, clause.keyword)
            isnothing(found) || push!(findings, found)
        end
    end
end

# Each member the unit's code reads through a loaded module, the module its qualifier names resolved by the walk.
function qualified_reaches!(findings, unit::ReachUnit, modules::ReachModules, home, reads)
    for read in reads
        is_member(read) || continue
        through = read.through
        isnothing(through) && continue
        found = reach_finding(modules, unit, home, through, read.name, read.line, :qualified)
        isnothing(found) && continue
        in_skipped_branch(read.qualifier, unit.tree) && continue
        push!(findings, found)
    end
end

# reaches-internal: a name read through any module that neither exports nor declares it, by a qualified step or a
# clause, in source, entry scripts and unloaded extensions alike. A module reading its own names is no reach.
function check_reaches_internal(index::SourceIndex, mods, package::Module; allowed = ())
    modules = ReachModules(mods, package, allowed)
    findings = Finding[]
    for file in index.files
        home = get(modules.by_key, file.mod, nothing)
        isnothing(home) && continue
        unit = ReachUnit(file.path, file.tree, file.mod)
        clause_reaches!(findings, unit, modules, home, file.scan.clauses)
        qualified_reaches!(findings, unit, modules, home, file.scan.reads)
    end
    for code in index.scripts
        unit = ReachUnit(code.path, code.tree, code.owner)
        home = script_home(modules, code.tree)
        clause_reaches!(findings, unit, modules, home, code.scan.clauses)
        qualified_reaches!(findings, unit, modules, home, code.scan.reads)
    end
    unique(found -> (found.file, found.line, found.symbol), findings)
end

# The function a method adds to, when its signature names a singleton function.
function extended_function(method::Method)
    function_type, _ = split_signature(method.sig)
    function_type isa DataType || return nothing
    function_type <: Function || return nothing
    isdefined(function_type, :instance) || return nothing
    function_type.instance
end

# private-extension: a method one project module adds to a function another owns, unless the owner declares the
# function public and documents it. Extending an undeclared function reaches into its owner's implementation.
function check_declared_extensions(defined, mods; recorded::RecordedPaths)
    project = Set(mods)
    reported = Set{Tuple{Module,Module,Symbol}}()   # (owner, home, function): one finding for all of a home's methods
    findings = Finding[]
    for method in defined
        extended = extended_function(method)
        isnothing(extended) && continue
        owning_module = parentmodule(extended)
        home = method.module
        owning_module in project || continue
        owning_module === home && continue
        name = nameof(extended)
        key = (owning_module, home, name)
        key in reported && continue
        push!(reported, key)
        is_public = Base.ispublic(owning_module, name)
        docs = recorded_docs(owning_module, name)
        is_documented = !isempty(docs)
        is_public && is_documented && continue
        owner = string(module_key(owning_module))
        file, line = method_site(method, recorded)
        evidence = [:owner => owner, :function => string(name),
                    :public => string(is_public), :documented => string(is_documented)]
        detail = "adds a method to a function its owner does not declare public and document"
        finding = Finding(module_key(home), :private_extension, file, "$owner.$name", line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# undeclared-module: a reference to a module no using or import line of the module names, in any of its files.
# Qualified paths count, so the module's using and import lines list every module it reaches.
function check_declared_modules(index::SourceIndex)
    wrapped = Set(file.mod for file in index.files if is_wrapper(file))
    declared = Dict{Symbol,Set{Symbol}}()
    for ref in index.refs
        is_clause = ref.via === :using || ref.via === :import
        is_clause || continue
        listed = get!(Set{Symbol}, declared, ref.from)
        push!(listed, ref.to)
    end
    findings = Finding[]
    for ref in index.refs
        ref.from in wrapped || continue
        named = get(declared, ref.from, Set{Symbol}())
        ref.to in named && continue
        target = string(ref.to)
        detail = "reaches a module none of its using or import lines names"
        evidence = [:via => string(ref.via)]
        push!(findings, Finding(ref.from, :undeclared_module, ref.file, target, ref.line, detail, evidence))
    end
    findings
end

# The concrete type a module binds under `name`; nothing for any other binding.
function concrete_type_named(home::Module, name::Symbol)
    name === nameof(home) && return nothing
    is_generated_name(name) && return nothing
    isdefined(home, name) || return nothing
    bound = getfield(home, name)
    unwrapped = declared_datatype(bound)
    isnothing(unwrapped) && return nothing
    isabstracttype(unwrapped) && return nothing
    unwrapped
end

# Every concrete subtype of `super` answers each (reader, extra-argument types) pair, including inherited methods.
function check_reader_set(mods, super::Type, required; sites = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}())
    findings = Finding[]
    seen = Base.IdSet{Type}()
    for home in mods, name in names(home; all = true)
        unwrapped = concrete_type_named(home, name)
        isnothing(unwrapped) && continue
        family = unwrapped.name.wrapper
        family <: super || continue
        family == super && continue
        family in seen && continue
        push!(seen, family)
        owner = module_key(parentmodule(unwrapped))
        type_name = nameof(unwrapped)
        file, line = site_of(sites, owner, type_name, ("", 0))
        for (reader, extras) in required
            signature = Tuple{family, extras.parameters...}
            hasmethod(reader, signature) && continue
            reader_name = nameof(reader)
            symbol = "$(type_name).$(reader_name)"
            detail = "the type answers no method matching this reader"
            evidence = [:reader => string(reader_name)]
            found = Finding(owner, :reader_set, file, symbol, line, detail, evidence)
            push!(findings, found)
        end
    end
    findings
end
