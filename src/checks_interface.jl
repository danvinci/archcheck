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

# The loaded modules a reference resolves against, and the outside ones whose internals the package reads on purpose.
struct ReachModules
    by_key::Dict{Symbol,Module}   # each package module by its dotted key
    tracked::Set{Module}          # the package's own modules, which a finding names by key
    package::Module               # the package root, which an entry script knows by its name
    allowed::Set{Module}          # outside modules whose internal names the package reads on purpose
    top::Dict{Symbol,Module}      # each loaded top-level module by name, where a path with no leading dot opens
end

# Every top-level module this Julia has loaded, by name. A name two loaded packages share names neither.
function top_modules()
    by_name = Dict{Symbol,Module}()
    shared = Set{Symbol}()
    for loaded in values(Base.loaded_modules)
        name = nameof(loaded)
        held = get(by_name, name, loaded)
        held === loaded || push!(shared, name)
        by_name[name] = loaded
    end
    for name in shared
        delete!(by_name, name)
    end
    by_name
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

# Where an import path opens, and the names after its opening. With no leading dot it opens at the loaded top-level
# module its first name names; with dots, at the module its first name binds in `home` or a parent per further dot.
function path_opening(modules::ReachModules, home, dots, path)
    rest = path[2:end]
    if dots == 0
        opened = get(modules.top, first(path), nothing)
        return opened, rest
    end
    isnothing(home) && return nothing, rest
    enclosing = home
    for _ in 2:dots
        enclosing = parentmodule(enclosing)
    end
    opened = bound_module(enclosing, first(path))
    isnothing(opened) && return enclosing, path   # a name such as `..f`, read through the enclosing module
    opened, rest
end

# What an import path reads from `home`: each name after its opening, through the module before it, and the module
# the path names whole, if it does; nothing when the path opens at no loaded module.
function path_target(modules::ReachModules, home, dots, path)
    isempty(path) && return nothing
    current, rest = path_opening(modules, home, dots, path)
    isnothing(current) && return nothing
    reads = Tuple{Module,Symbol}[]
    for name in rest
        push!(reads, (current, name))
        member = bound_module(current, name)
        isnothing(member) && return (; reads, named = nothing)
        current = member
    end
    (; reads, named = current)
end

# The modules an entry script binds by name. A script runs where the package is loaded, so it knows the package by
# its name; every other name comes from its own using, import and `const` lines.
struct ScriptNames
    bound::Dict{Symbol,Module}   # name -> the loaded module it binds
    used::Vector{Module}         # modules a `using` line brings in whole, whose exported modules the script sees
    home::Union{Nothing,Module}  # the loaded module a script's module block stands for; nothing at a file's top level
end

function bound_module(script::ScriptNames, name::Symbol)
    named = get(script.bound, name, nothing)
    isnothing(named) || return named
    for used in script.used
        Base.isexported(used, name) || continue
        exported = bound_module(used, name)
        isnothing(exported) || return exported
    end
    nothing
end

function collect_const_alias!(script::ScriptNames, assignment)
    JS.kind(assignment) == K"=" || return
    sides = child_nodes(assignment)
    child_count(sides) < 2 && return
    alias = node_symbol(sides[1])
    isnothing(alias) && return
    no_locals = Set{Symbol}()
    aliased = resolve_loaded_module(sides[2], script, no_locals)
    isnothing(aliased) && return
    script.bound[alias] = aliased
end

# Each `const` binding of a loaded module, outside quoted code and nested scopes.
function collect_const_aliases!(script::ScriptNames, node)
    kind = JS.kind(node)
    kind == K"quote" && return
    is_nested_scope(node) && return
    children = child_nodes(node)
    isnothing(children) && return
    if kind == K"const"
        for declaration in children
            collect_const_alias!(script, declaration)
        end
        return
    end
    for child in children
        collect_const_aliases!(script, child)
    end
end

# The loaded module an entry script's import path names whole; nothing for a path to a name inside a module.
function script_path_module(modules::ReachModules, path_node)
    dots, path = importpath_parts(path_node)
    target = path_target(modules, nothing, dots, path)
    isnothing(target) && return nothing
    target.named
end

# A listed name's path in a `:` clause and the name it binds in the script: itself, or the name after its `as`.
function listed_source_binding(item)
    if JS.kind(item) == K"as"
        renamed = renamed_parts(item)
        return renamed.path, renamed.bound
    end
    _, path = importpath_parts(item)
    bound = length(path) == 1 ? only(path) : nothing
    path, bound
end

# The modules one clause binds in a script: a path naming a module whole binds its last name, or the name after
# `as`, and `using` it brings its exports; a listed name binds when it names a module.
function script_clause!(script::ScriptNames, modules::ReachModules, clause, line_kind)
    kind = JS.kind(clause)
    if kind == K"as"
        renamed = renamed_parts(clause)
        target = path_target(modules, nothing, renamed.dots, renamed.path)
        isnothing(target) && return
        named = target.named
        isnothing(named) && return
        isnothing(renamed.bound) && return
        script.bound[renamed.bound] = named
        return
    end
    if kind == K"importpath"
        loaded = script_path_module(modules, clause)
        isnothing(loaded) && return
        _, path = importpath_parts(clause)
        script.bound[last(path)] = loaded
        if line_kind == K"using"
            push!(script.used, loaded)
        end
        return
    end
    kind == K":" || return
    children = child_nodes(clause)
    base = script_path_module(modules, first(children))
    isnothing(base) && return
    for item in children[2:end]
        path, bound = listed_source_binding(item)
        length(path) == 1 || continue
        isnothing(bound) && continue
        member = bound_module(base, only(path))
        if !isnothing(member)
            script.bound[bound] = member
        end
    end
end

# The loaded top-level module a script's module block names, as a fixture package's spine read as a script does.
function script_home(modules::ReachModules, tree)
    block = tree.parent
    isnothing(block) && return nothing
    is_module_block(block) || return nothing
    name = module_name(block)
    isnothing(name) && return nothing
    get(modules.top, name, nothing)
end

# The modules a script binds by name: Core and Base, as every module does, the package, and its own clauses.
function script_names(tree, modules::ReachModules, home)
    package = modules.package
    bound = Dict{Symbol,Module}(:Core => Core, :Base => Base)
    bound[nameof(package)] = package
    script = ScriptNames(bound, Module[], home)
    each_clause((clause, line_kind) -> script_clause!(script, modules, clause, line_kind), tree)
    collect_const_aliases!(script, tree)
    script
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
    from::Symbol          # key of the module the code belongs to; :Entry for an entry script
end

# The module the code of a unit sits in, which reads its own names freely; an entry script sits in none.
code_home(names::Module) = names
code_home(script::ScriptNames) = script.home

# The unit's code reading `name` through `through`; nothing when `through` is the code's own module or one the
# package reads on purpose, holds no such name, or declares it.
function reach_finding(modules::ReachModules, unit::ReachUnit, home, through::Module, name::Symbol, line, via::Symbol)
    through === home && return nothing
    through in modules.allowed && return nothing
    isdefined(through, name) || return nothing
    Base.ispublic(through, name) && return nothing
    defining = which(through, name)
    owner = module_label(defining, modules)
    reached = module_label(through, modules)
    symbol = "$reached.$name"
    detail = "reads a name through a module that neither exports it nor declares it public"
    evidence = [:via => string(via), :owner => owner]
    Finding(unit.from, :reaches_internal, unit.path, symbol, line, detail, evidence)
end

# Each name one clause reads, with the module it reads it through: its path's names after the opening, and each
# name a `:` list binds from the module that path names whole.
function clause_reads(modules::ReachModules, home, clause)
    kind = JS.kind(clause)
    if kind == K"as"
        source = first(child_nodes(clause))
        return clause_reads(modules, home, source)
    end
    if kind == K"importpath"
        dots, path = importpath_parts(clause)
        target = path_target(modules, home, dots, path)
        isnothing(target) && return nothing
        return target.reads
    end
    kind == K":" || return nothing
    children = child_nodes(clause)
    dots, path = importpath_parts(first(children))
    base = path_target(modules, home, dots, path)
    isnothing(base) && return nothing
    named = base.named
    isnothing(named) && return nothing
    reads = copy(base.reads)
    for item in children[2:end]
        source = clause_source(item)
        _, item_names = importpath_parts(source)
        for name in item_names
            push!(reads, (named, name))
        end
    end
    reads
end

# Whether a child of an `if` or `elseif` runs when this Julia loads it: the condition does, an `elseif` does unless an
# earlier condition is decided true, and a branch does when the load takes it.
function is_live_child(conditional, child)
    children = child_nodes(conditional)
    child === first(children) && return true
    if JS.kind(child) == K"elseif"
        condition = static_condition(first(children))
        return condition !== true
    end
    any(branch -> branch === child, live_branches(conditional))
end

# Whether `node` sits, below `root`, in a branch this Julia skips while it loads, judged by the load's own rule.
function in_skipped_branch(node, root)
    child = node
    current = node.parent
    while !isnothing(current) && child !== root
        kind = JS.kind(current)
        is_conditional = kind == K"if" || kind == K"elseif"
        is_conditional && !is_live_child(current, child) && return true
        child = current
        current = current.parent
    end
    false
end

function clause_reach!(findings, modules::ReachModules, unit::ReachUnit, home, clause, line_kind)
    in_skipped_branch(clause, unit.tree) && return
    reads = clause_reads(modules, home, clause)
    isnothing(reads) && return
    via = Symbol(string(line_kind))
    line = source_line(clause.parent)
    for (through, name) in reads
        found = reach_finding(modules, unit, home, through, name, line, via)
        isnothing(found) || push!(findings, found)
    end
end

# Each name a using or import clause of the unit binds through a module.
function clause_reaches!(findings, unit::ReachUnit, modules::ReachModules, home)
    each_clause((clause, line_kind) -> clause_reach!(findings, modules, unit, home, clause, line_kind), unit.tree)
end

# Whether `node` sits in a module block inside `root`: that block's code is a unit of its own.
function in_inner_module(node, root)
    current = node.parent
    while !isnothing(current) && current !== root
        JS.kind(current) == K"module" && return true
        current = current.parent
    end
    false
end

# The scoped walk's callback over one unit: each step of a qualified path, judged where the walk meets it.
struct QualifiedReader{N}
    findings::Vector{Finding}   # where each reach is recorded
    modules::ReachModules       # the modules a reference resolves against
    names::N                    # what a bare name binds where the code sits: its loaded module, or a script's names
    unit::ReachUnit             # the code walked
end

function (reader::QualifiedReader)(qualifier, member, line, bound)
    unit = reader.unit
    in_inner_module(qualifier, unit.tree) && return
    through = resolve_loaded_module(qualifier, reader.names, bound)
    isnothing(through) && return
    home = code_home(reader.names)
    found = reach_finding(reader.modules, unit, home, through, member, line, :qualified)
    isnothing(found) && return
    in_skipped_branch(qualifier, unit.tree) && return
    push!(reader.findings, found)
end

function qualified_reaches!(findings, unit::ReachUnit, modules::ReachModules, names)
    reader = QualifiedReader(findings, modules, names, unit)
    scan = empty_scan()
    target = :_
    scan.refs[target] = Set{Symbol}()
    scope = ScanScope(target, Set{Symbol}(), 0, 0, nothing, false)
    walk_scoped!(scan, unit.tree, scope, reader)
end

# reaches-internal: a name read through any module that neither exports nor declares it, by a qualified step or a
# clause, in source and entry scripts alike. A module reading its own names is no reach.
function check_reaches_internal(index::SourceIndex, mods, package::Module; allowed = ())
    modules = ReachModules(mods, package, allowed)
    findings = Finding[]
    for file in index.files
        home = get(modules.by_key, file.mod, nothing)
        isnothing(home) && continue
        unit = ReachUnit(file.path, file.tree, file.mod)
        clause_reaches!(findings, unit, modules, home)
        qualified_reaches!(findings, unit, modules, home)
    end
    for (path, tree) in index.scripts
        unit = ReachUnit(path, tree, :Entry)
        home = script_home(modules, tree)
        clause_reaches!(findings, unit, modules, home)
        names = script_names(tree, modules, home)
        qualified_reaches!(findings, unit, modules, names)
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
