# The package's load as the parse reads it: which branches this Julia runs, where each include starts, and where
# the load first binds each name of each module.

# ---- branches this Julia decides while it loads ----

# A `v"..."` literal's version; nothing for any other node.
function version_literal(node)
    JS.kind(node) == K"macrocall" || return nothing
    children = child_nodes(node)
    child_count(children) == 2 || return nothing
    children[1].val === :v || return nothing
    text = static_string(children[2])
    isnothing(text) && return nothing
    tryparse(VersionNumber, text)
end

# The version a comparison operand stands for: the running Julia's `VERSION`, or a literal's.
function operand_version(node)
    node.val === :VERSION && return VERSION
    path = dotted_names(node)
    path == [:Base, :VERSION] && return VERSION
    version_literal(node)
end

function compare_versions(operator, left::VersionNumber, right::VersionNumber)::Union{Nothing,Bool}
    operator === :< && return left < right
    operator === :<= && return left <= right
    operator === :> && return left > right
    operator === :>= && return left >= right
    operator === :(==) && return left == right
    operator === :!= && return left != right
    nothing
end

function version_comparison(node)::Union{Nothing,Bool}
    JS.is_infix_op_call(node) || return nothing
    children = child_nodes(node)
    child_count(children) == 3 || return nothing
    left = operand_version(children[1])
    right = operand_version(children[3])
    isnothing(left) && return nothing
    isnothing(right) && return nothing
    compare_versions(children[2].val, left, right)
end

# `isdefined(Base, :name)` or `isdefined(Core, :name)`, answered by the running Julia.
function base_isdefined(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    child_count(children) == 3 || return nothing
    children[1].val === :isdefined || return nothing
    holder = children[2].val
    holder === :Base || holder === :Core || return nothing
    JS.kind(children[3]) == K"quote" || return nothing
    quoted = child_nodes(children[3])
    child_count(quoted) == 1 || return nothing
    name = node_symbol(quoted[1])
    isnothing(name) && return nothing
    loaded = holder === :Base ? Base : Core
    isdefined(loaded, name)
end

function static_and(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    left = static_condition(children[1])
    right = static_condition(children[2])
    left === false && return false
    right === false && return false
    left === true && return right
    nothing
end

function static_or(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    left = static_condition(children[1])
    right = static_condition(children[2])
    left === true && return true
    right === true && return true
    left === false && return right
    nothing
end

function static_not(node)::Union{Nothing,Bool}
    children = child_nodes(node)
    child_count(children) == 2 || return nothing
    children[1].val === :! || return nothing
    operand = static_condition(children[2])
    isnothing(operand) && return nothing
    !operand
end

# The value an `if` condition takes on this Julia when a literal, a `VERSION` comparison or `isdefined` on Base or
# Core decides it; nothing when only the load can.
function static_condition(node)::Union{Nothing,Bool}
    value = node.val
    value isa Bool && return value
    kind = JS.kind(node)
    kind == K"&&" && return static_and(node)
    kind == K"||" && return static_or(node)
    kind == K"call" || return nothing
    JS.is_prefix_op_call(node) && return static_not(node)
    compared = version_comparison(node)
    isnothing(compared) || return compared
    base_isdefined(node)
end

# The parts of an `if` or `elseif` the load runs: the taken branch when this Julia decides the condition, else all.
function live_branches(node::JS.SyntaxNode)
    children = child_nodes(node)
    condition = static_condition(children[1])
    branches = children[2:end]
    isnothing(condition) && return branches
    condition && return branches[1:1]
    length(branches) < 2 && return JS.SyntaxNode[]
    rest = branches[2]
    JS.kind(rest) == K"elseif" && return live_branches(rest)
    [rest]
end

# The children the load runs: the live branches of a conditional, every child of anything else.
function live_children(node)
    kind = JS.kind(node)
    kind == K"if" && return live_branches(node)
    kind == K"elseif" && return live_branches(node)
    children = child_nodes(node)
    isnothing(children) && return JS.SyntaxNode[]
    children
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

# What loaded code includes and opens, in source order, past branches this Julia skips and method bodies, which
# include only when called.
function collect_live_events!(events, node)
    JS.kind(node) == K"quote" && return events
    is_method_form(node) && return events
    for child in live_children(node)
        if is_module_block(child) || is_include_call(child)
            push!(events, child)
        end
        collect_live_events!(events, child)
    end
    events
end

live_load_events(root) = collect_live_events!(JS.SyntaxNode[], root)

# ---- where the load binds each name ----

"""One name a top-level form of loaded code binds, and where the form sits."""
struct BindingSite
    name::Symbol      # the name bound
    byte::Int         # first byte of the binding form in its file
    is_import::Bool   # a using or import clause binds it
end

"""Where the load first binds one name in one module."""
struct NameBinding
    started::Int      # includes the load has started when it makes the binding
    code::Int         # position in `index.files` of the code that makes it
    is_import::Bool   # a using or import clause makes it, so a module the code uses may resolve the name sooner
end

# A scope whose assignments stay local, so a name assigned inside binds nothing in the module.
function is_local_scope(kind)
    kind == K"let" && return true
    kind == K"for" && return true
    kind == K"while" && return true
    kind == K"try" && return true
    kind == K"comprehension" && return true
    kind == K"generator" && return true
    kind == K"->" && return true
    kind == K"do" && return true
    false
end

function add_site!(sites, name, node, is_import)
    isnothing(name) && return sites
    byte = JS.first_byte(node)
    site = BindingSite(name, byte, is_import)
    push!(sites, site)
end

# A named method binds its function, and `function f end` binds `f`. A method on another module's function, a
# callable type or a type's curly constructor adds to a binding made elsewhere.
function add_method_site!(sites, node)
    children = child_nodes(node)
    head = children[1]
    if child_count(children) == 1
        add_site!(sites, node_symbol(head), node, false)
        return sites
    end
    is_type_constructor(head) && return sites
    add_site!(sites, sig_name(head), node, false)
end

function add_type_site!(sites, node)
    children = child_nodes(node)
    name = type_name(children[1])
    add_site!(sites, name, node, false)
end

# The name one using or import clause binds: each listed name, a rename, or the path's last name.
function add_clause_sites!(sites, node, clause)
    kind = JS.kind(clause)
    if kind == K":"
        items = child_nodes(clause)
        for item in items[2:end]
            add_clause_sites!(sites, node, item)
        end
        return sites
    end
    if kind == K"as"
        renamed = renamed_parts(clause)
        add_site!(sites, renamed.bound, node, true)
        return sites
    end
    kind == K"importpath" || return sites
    _, path = importpath_parts(clause)
    isempty(path) && return sites
    add_site!(sites, last(path), node, true)
end

function add_assigned_sites!(sites, node, target)
    names = Symbol[]
    _argname!(names, target)
    for name in names
        add_site!(sites, name, node, false)
    end
    sites
end

function is_enum_macro(node)
    JS.kind(node) == K"macrocall" || return false
    children = child_nodes(node)
    head = children[1]
    JS.kind(head) == K"macro_name" || return false
    parts = child_nodes(head)
    child_count(parts) == 1 || return false
    parts[1].val === :enum
end

# `@enum E a b` binds the type and each instance; the instances may sit in a block.
function add_enum_sites!(sites, node)
    children = child_nodes(node)
    for argument in children[2:end]
        listed = JS.kind(argument) == K"block" ? child_nodes(argument) : [argument]
        for item in listed
            add_assigned_sites!(sites, node, item)
        end
    end
    sites
end

function collect_assignment_sites!(sites, node, is_global)
    children = child_nodes(node)
    is_global && add_assigned_sites!(sites, node, children[1])
    sites
end

function collect_global_sites!(sites, node)
    for declared in child_nodes(node)
        target = declared
        if JS.kind(declared) == K"="
            target = first(child_nodes(declared))
        end
        add_assigned_sites!(sites, node, target)
    end
    sites
end

# The names a piece of loaded code binds in its module, in source order. `is_global` holds while no local scope
# encloses the form. Methods' bodies, quoted code and module blocks bind nothing here.
function collect_bindings!(sites, node, is_global::Bool)
    kind = JS.kind(node)
    kind == K"quote" && return sites
    if is_method_form(node)
        is_global && add_method_site!(sites, node)
        return sites
    end
    kind == K"macro" && return sites
    if is_type_form(kind)
        is_global && add_type_site!(sites, node)
        return sites
    end
    if kind == K"using" || kind == K"import"
        for clause in child_nodes(node)
            add_clause_sites!(sites, node, clause)
        end
        return sites
    end
    kind == K"=" && return collect_assignment_sites!(sites, node, is_global)
    kind == K"call" && return sites
    kind == K"dotcall" && return sites
    kind == K"global" && return collect_global_sites!(sites, node)
    if is_enum_macro(node)
        is_global && add_enum_sites!(sites, node)
        return sites
    end
    inner = is_global && !is_local_scope(kind)
    for child in live_children(node)
        collect_bindings!(sites, child, inner)
    end
    sites
end

# ---- the load walk ----

"""One include call or module block in a piece of loaded code, and how many includes the load has started once its
code has run."""
struct LoadStep
    byte::Int      # first byte of the include call or module block in its file
    started::Int   # includes the load has started once the step's code has run
end

"""Where one piece of indexed code sits in the package's load: the includes started before it begins, then its steps."""
struct CodeLoad
    start::Int                # includes the load has started when this code begins
    steps::Vector{LoadStep}   # this code's live include calls and module blocks, in source order
end

# How many includes the load has started when it reaches `byte` in this code.
function started_at(load::CodeLoad, byte::Integer)
    started = load.start
    for step in load.steps
        step.byte < byte || break
        started = step.started
    end
    started
end

"""The package's load over the index, by each code's position in `index.files`: where each code sits, and where the
load first binds each name."""
struct LoadWalk
    index::SourceIndex                              # the codes walked
    root::Symbol                                    # the package's module key
    openers::Dict{String,Vector{Int}}               # repo-relative path -> the codes that open the file, one per module
    bodies::IdDict{JS.SyntaxNode,Int}               # a code's syntax -> its position
    loads::Dict{Int,CodeLoad}                       # code -> its place, once the walk has left it
    order::Vector{Int}                              # codes in the order the load enters them
    entered::Set{Int}                               # codes the walk has entered
    names::Dict{Symbol,Dict{Symbol,NameBinding}}    # module key -> each name -> where the load first binds it
end

# The codes that open each file: those whose syntax starts first, a directory module's entry before its blocks.
function file_openers(index::SourceIndex)
    earliest = Dict{String,Int}()
    for file in index.files
        byte = JS.first_byte(file.tree)
        known = get(earliest, file.path, typemax(Int))
        earliest[file.path] = min(known, byte)
    end
    openers = Dict{String,Vector{Int}}()
    for (position, file) in enumerate(index.files)
        byte = JS.first_byte(file.tree)
        byte == earliest[file.path] || continue
        listed = get!(Vector{Int}, openers, file.path)
        push!(listed, position)
    end
    openers
end

function code_bodies(index::SourceIndex)
    bodies = IdDict{JS.SyntaxNode,Int}()
    for (position, file) in enumerate(index.files)
        bodies[file.tree] = position
    end
    bodies
end

# The code an include call loads: the file's opener in the including module, else the module whose entry it is.
function include_target(walk::LoadWalk, position::Int, call)
    file = walk.index.files[position]
    argument = first(call_args(call))
    spec = include_spec(argument)
    isnothing(spec) && return nothing
    absolute = joinpath(walk.index.repo, file.path)
    joined = joinpath(dirname(absolute), spec)
    normalized = normpath(joined)
    target = relpath(normalized, walk.index.repo)
    candidates = get(walk.openers, target, Int[])
    isempty(candidates) && return nothing
    for candidate in candidates
        walk.index.files[candidate].mod === file.mod && return candidate
    end
    first(candidates)
end

# A module's own code binds the module's name in the module that encloses it, as the load opens it.
function bind_module!(walk::LoadWalk, position::Int, started::Int)
    file = walk.index.files[position]
    is_module_code = is_wrapper(file) && file.filerank == 0 && length(file.modrank) >= 2
    is_module_code || return
    segments = key_segments(file.mod)
    name = last(segments)
    enclosing = walk.root
    if length(segments) > 1
        outer = segments[1:(end - 1)]
        enclosing = Symbol(join(outer, "."))
    end
    bound = get!(Dict{Symbol,NameBinding}, walk.names, enclosing)
    binding = NameBinding(started, position, false)
    get!(bound, name, binding)
end

# Binds each site before `byte` at the includes started so far, keeping a name's first binding; returns the next site.
function bind_sites!(walk::LoadWalk, position::Int, sites, pending::Int, byte::Int, started::Int)
    file = walk.index.files[position]
    bound = get!(Dict{Symbol,NameBinding}, walk.names, file.mod)
    while pending <= length(sites) && sites[pending].byte < byte
        site = sites[pending]
        binding = NameBinding(started, position, site.is_import)
        get!(bound, site.name, binding)
        pending += 1
    end
    pending
end

# A module block runs in place; an include starts one more include, then runs the file it names.
function event_load!(walk::LoadWalk, position::Int, event, started::Int)
    if is_module_block(event)
        body = module_body(event)
        inner = get(walk.bodies, body, nothing)
        isnothing(inner) && return started
        return walk_load!(walk, inner, started)
    end
    counted = started + 1
    target = include_target(walk, position, event)
    isnothing(target) && return counted
    walk_load!(walk, target, counted)
end

# Runs one code as the load does: its bindings and its include calls and module blocks in source order. Returns the
# includes started once it is done.
function walk_load!(walk::LoadWalk, position::Int, started::Int)
    position in walk.entered && return started
    push!(walk.entered, position)
    push!(walk.order, position)
    file = walk.index.files[position]
    bind_module!(walk, position, started)
    sites = collect_bindings!(BindingSite[], file.tree, true)
    start = started
    steps = LoadStep[]
    pending = 1
    for event in live_load_events(file.tree)
        byte = JS.first_byte(event)
        pending = bind_sites!(walk, position, sites, pending, byte, started)
        started = event_load!(walk, position, event, started)
        push!(steps, LoadStep(byte, started))
    end
    bind_sites!(walk, position, sites, pending, typemax(Int), started)
    walk.loads[position] = CodeLoad(start, steps)
    started
end

# The package's entry, then each loaded extension's in rank order: the codes no include of the package reaches.
function load_roots(index::SourceIndex)
    roots = Int[]
    for (position, file) in enumerate(index.files)
        is_root = is_wrapper(file) && file.filerank == 0 && length(file.modrank) == 1
        is_root && push!(roots, position)
    end
    sort!(roots; by = position -> index.files[position].modrank)
end

function load_walk(index::SourceIndex, root::Symbol)
    openers = file_openers(index)
    bodies = code_bodies(index)
    loads = Dict{Int,CodeLoad}()
    names = Dict{Symbol,Dict{Symbol,NameBinding}}()
    walk = LoadWalk(index, root, openers, bodies, loads, Int[], Set{Int}(), names)
    started = 0
    for position in load_roots(index)
        started = walk_load!(walk, position, started)
    end
    walk
end
