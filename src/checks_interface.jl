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

function is_blanket_names_call(node)
    JS.kind(node) == K"call" || return false
    call_parts = child_nodes(node)
    child_count(call_parts) == 0 && return false
    call_parts[1].val === :names || return false
    any(has_all_keyword, call_parts)
end

function find_blanket_names(node)
    is_blanket_names_call(node) && return node
    children = child_nodes(node)
    isnothing(children) && return nothing
    for child in children
        found = find_blanket_names(child)
        isnothing(found) || return found
    end
    nothing
end

function check_blanket_exports(index::SourceIndex)
    findings = Finding[]
    for file in index.files
        is_wrapper(file) || continue
        hit = find_blanket_names(file.tree)
        isnothing(hit) && continue
        line = source_line(hit)
        detail = "module exports its whole namespace, so it declares no interface"
        push!(findings, Finding(file.mod, :blanket_export, file.path, "", line, detail))
    end
    findings
end

# The loaded modules a reference resolves against.
struct ReachModules
    by_key::Dict{Symbol,Module}   # each package module by its dotted key
    by_name::Dict{Symbol,Module}  # each package module and every module enclosing one, by name
    tracked::Set{Module}          # the package's own modules, the only ones a reach is judged in
    package::Module               # the package root, below which `as` renames resolve
end

function ReachModules(modules, package::Module)
    by_key = Dict{Symbol,Module}()
    by_name = Dict{Symbol,Module}()
    for loaded in modules
        key = module_key(loaded)
        by_key[key] = loaded
        by_name[nameof(loaded)] = loaded
        enclosing = parentmodule(loaded)
        while !haskey(by_name, nameof(enclosing))
            by_name[nameof(enclosing)] = enclosing
            enclosing = parentmodule(enclosing)
        end
    end
    tracked = Set{Module}(modules)
    ReachModules(by_key, by_name, tracked, package)
end

# The loaded module a qualifier names: a name `aliases` binds, else a loaded module of that name, else a member
# module of the module its own qualifier names. A name the code binds locally names no module.
function resolve_loaded_module(qualifier, by_name, aliases, bound)
    name = node_symbol(qualifier)
    if !isnothing(name)
        name in bound && return nothing
        haskey(aliases, name) && return aliases[name]
        return get(by_name, name, nothing)
    end
    JS.kind(qualifier) == K"." || return nothing
    path_parts = child_nodes(qualifier)
    child_count(path_parts) != 2 && return nothing
    enclosing = resolve_loaded_module(path_parts[1], by_name, aliases, bound)
    isnothing(enclosing) && return nothing
    member = node_symbol(path_parts[2])
    isnothing(member) && return nothing
    isdefined(enclosing, member) || return nothing
    named = getfield(enclosing, member)
    named isa Module ? named : nothing
end

function collect_const_alias!(aliases, assignment, by_name)
    JS.kind(assignment) == K"=" || return
    sides = child_nodes(assignment)
    child_count(sides) < 2 && return
    alias = node_symbol(sides[1])
    isnothing(alias) && return
    no_locals = Set{Symbol}()
    aliased = resolve_loaded_module(sides[2], by_name, aliases, no_locals)
    isnothing(aliased) && return
    aliases[alias] = aliased
end

# Each `const` binding of a loaded module, outside quoted code and nested scopes.
function collect_const_aliases!(aliases, node, by_name)
    kind = JS.kind(node)
    kind == K"quote" && return
    is_nested_scope(node) && return
    children = child_nodes(node)
    isnothing(children) && return
    if kind == K"const"
        for declaration in children
            collect_const_alias!(aliases, declaration, by_name)
        end
        return
    end
    for child in children
        collect_const_aliases!(aliases, child, by_name)
    end
end

# The loaded module behind each name an `as` clause binds; a rename of a module this Julia did not load drops out.
function loaded_aliases(renames, package::Module)
    aliases = Dict{Symbol,Module}()
    for (name, key) in renames
        renamed = loaded_module(package, key)
        isnothing(renamed) && continue
        aliases[name] = renamed
    end
    aliases
end

# A module's name as a finding states it: its dotted key in the package, its full path outside it.
function module_label(named::Module, modules::ReachModules)
    named in modules.tracked && return string(module_key(named))
    path = fullname(named)
    join(path, ".")
end

# Code in `from` reading `name` through `through`; nothing when `through` holds no such name or declares it.
function reach_finding(modules::ReachModules, through::Module, name::Symbol, from::Symbol, file, line, via::Symbol)
    isdefined(through, name) || return nothing
    Base.ispublic(through, name) && return nothing
    defining = Base.binding_module(through, name)
    owner = module_label(defining, modules)
    symbol = "$(module_key(through)).$name"
    detail = "reads a name through a module that neither exports it nor declares it public"
    evidence = [:via => string(via), :owner => owner]
    Finding(from, :reaches_internal, file, symbol, line, detail, evidence)
end

# Each name a using or import clause binds from one of the package's modules.
function clause_reaches!(findings, refs, modules::ReachModules)
    for ref in refs
        is_clause = ref.via === :using || ref.via === :import
        is_clause || continue
        through = get(modules.by_key, ref.to, nothing)
        isnothing(through) && continue
        for name in ref.names
            found = reach_finding(modules, through, name, ref.from, ref.file, ref.line, ref.via)
            isnothing(found) || push!(findings, found)
        end
    end
end

# One piece of code references are read in: a source file's module code, or an entry script.
struct ReachUnit
    path::String                   # repo-relative path, or an entry script's walked path
    tree::JS.SyntaxNode            # the code
    from::Symbol                   # key of the module the code belongs to; :Entry for an entry script
    renames::Dict{Symbol,Symbol}   # each name an `as` clause binds -> the key of the project module it names
end

# Source code resolves the renames its whole module makes, an entry script its own.
function reach_units(index::SourceIndex, module_names::ModuleNames)
    units = ReachUnit[]
    for file in index.files
        renames = get(index.aliases, file.mod, Dict{Symbol,Symbol}())
        push!(units, ReachUnit(file.path, file.tree, file.mod, renames))
    end
    for (path, tree) in index.scripts
        no_scope = Symbol[]
        renames = code_aliases!(Dict{Symbol,Symbol}(), module_names, no_scope, tree)
        push!(units, ReachUnit(path, tree, :Entry, renames))
    end
    units
end

# The scoped walk's callback over one unit: each step of a qualified path, judged where the walk meets it.
struct QualifiedReader
    findings::Vector{Finding}       # where each reach is recorded
    modules::ReachModules           # what a qualifier resolves against
    aliases::Dict{Symbol,Module}    # names the unit binds to a loaded module: `as` renames and `const` aliases
    unit::ReachUnit                 # the code walked
end

function (reader::QualifiedReader)(qualifier, member, line, bound)
    modules = reader.modules
    through = resolve_loaded_module(qualifier, modules.by_name, reader.aliases, bound)
    isnothing(through) && return
    through in modules.tracked || return
    unit = reader.unit
    home = get(modules.by_key, unit.from, nothing)
    through === home && return
    found = reach_finding(modules, through, member, unit.from, unit.path, line, :qualified)
    isnothing(found) || push!(reader.findings, found)
end

function qualified_reaches!(findings, unit::ReachUnit, modules::ReachModules)
    aliases = loaded_aliases(unit.renames, modules.package)
    collect_const_aliases!(aliases, unit.tree, modules.by_name)
    reader = QualifiedReader(findings, modules, aliases, unit)
    scan = empty_scan()
    target = :_
    scan.refs[target] = Set{Symbol}()
    scope = ScanScope(target, Set{Symbol}(), 0, 0, nothing, false)
    walk_scoped!(scan, unit.tree, scope, reader)
end

# reaches-internal: a name read through a package module that neither exports nor declares it: each qualified step,
# each name a clause binds, in source and entry scripts alike. A module reading its own names is no reach.
function check_reaches_internal(index::SourceIndex, mods, package::Module)
    modules = ReachModules(mods, package)
    findings = Finding[]
    clause_reaches!(findings, index.refs, modules)
    keys_known = Set{Symbol}(keys(modules.by_key))
    package_name = nameof(package)
    module_names = ModuleNames(keys_known, package_name)
    for (path, tree) in index.scripts
        script_refs = ModRef[]
        walk_modrefs!(script_refs, :Entry, Symbol[], path, module_names, tree)
        clause_reaches!(findings, script_refs, modules)
    end
    for unit in reach_units(index, module_names)
        qualified_reaches!(findings, unit, modules)
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
function check_declared_extensions(defined, mods; repo)
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
        is_documented = !isnothing(docs)
        is_public && is_documented && continue
        owner = string(module_key(owning_module))
        file, line = method_site(method, repo)
        evidence = [:owner => owner, :function => string(name),
                    :public => string(is_public), :documented => string(is_documented)]
        detail = "adds a method to a function its owner does not declare public and document"
        finding = Finding(module_key(home), :private_extension, file, "$owner.$name", line, detail, evidence)
        push!(findings, finding)
    end
    findings
end

# undeclared-module: a reference to a module its source's wrapper does not name in a using or import line.
# Qualified paths count, so the wrapper's using and import lines list every module the module reaches.
function check_declared_modules(index::SourceIndex)
    wrappers = Dict(file.mod => file.path for file in index.files if is_wrapper(file))
    declared = Dict{Symbol,Set{Symbol}}()
    for ref in index.refs
        is_clause = ref.via === :using || ref.via === :import
        is_clause || continue
        wrapper_path = get(wrappers, ref.from, "")
        wrapper_path == ref.file || continue
        listed = get!(Set{Symbol}, declared, ref.from)
        push!(listed, ref.to)
    end
    findings = Finding[]
    for ref in index.refs
        haskey(wrappers, ref.from) || continue
        named = get(declared, ref.from, Set{Symbol}())
        ref.to in named && continue
        target = string(ref.to)
        detail = "reaches a module its wrapper does not name in a using or import line"
        evidence = [:via => string(ref.via)]
        push!(findings, Finding(ref.from, :undeclared_module, ref.file, target, ref.line, detail, evidence))
    end
    findings
end

# The concrete type a module binds under `name`; nothing for any other binding.
function concrete_type_named(home::Module, name::Symbol)
    name === nameof(home) && return nothing
    startswith(string(name), "#") && return nothing
    isdefined(home, name) || return nothing
    bound = getfield(home, name)
    bound isa Type || return nothing
    unwrapped = Base.unwrap_unionall(bound)
    unwrapped isa DataType || return nothing
    isabstracttype(unwrapped) && return nothing
    unwrapped
end

# Every concrete subtype of `super` answers each (reader, extra-argument types) pair, including inherited methods.
function check_reader_set(mods, super::Type, required; sites = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}())
    findings = Finding[]
    seen = Set{Type}()
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
