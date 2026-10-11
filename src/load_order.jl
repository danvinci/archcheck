# The package's load as the parse reads it: where each include starts, and where the load first binds each name
# of each module.

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
    bodies::IdDict{JS.SyntaxNode,Int}               # a code's syntax -> its position
    loads::Dict{Int,CodeLoad}                       # code -> its place, once the walk has left it
    order::Vector{Int}                              # codes in the order the load enters them
    entered::Set{Int}                               # codes the walk has entered
    names::Dict{Symbol,Dict{Symbol,NameBinding}}    # module key -> each name -> where the load first binds it
end

function code_bodies(index::SourceIndex)
    bodies = IdDict{JS.SyntaxNode,Int}()
    for (position, file) in enumerate(index.files)
        bodies[file.tree] = position
    end
    bodies
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

const NO_CODES = Int[]

# A module block runs in place; an include starts one more include for each file it runs, then runs that file.
function event_load!(walk::LoadWalk, event, started::Int)
    if is_module_block(event)
        body = module_body(event)
        inner = get(walk.bodies, body, nothing)
        isnothing(inner) && return started
        return walk_load!(walk, inner, started)
    end
    opened = get(walk.index.opened, event, NO_CODES)
    for target in opened
        started = walk_load!(walk, target, started + 1)
    end
    started
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
        started = event_load!(walk, event, started)
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
    bodies = code_bodies(index)
    loads = Dict{Int,CodeLoad}()
    names = Dict{Symbol,Dict{Symbol,NameBinding}}()
    walk = LoadWalk(index, root, bodies, loads, Int[], Set{Int}(), names)
    started = 0
    for position in load_roots(index)
        started = walk_load!(walk, position, started)
    end
    walk
end
