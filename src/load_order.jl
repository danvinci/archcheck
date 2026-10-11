# The load as the index walk runs it: where each piece of loaded code starts, where each include call and module block
# in it ends, and the names its forms bind.

"""One name a form of loaded code binds, and where the form sits."""
struct BindingSite
    mod::Symbol    # key of the module the name is bound in
    name::Symbol   # the name bound
    byte::Int      # first byte of the binding form in its file; 0 for a module's own name, bound as the module opens
end

"""One point the load reaches in a piece of loaded code: its start, or the end of one include call or module block."""
struct LoadStep
    byte::Int      # first byte of the include call or module block in its file; 0 for the code's start
    started::Int   # includes the load has started by this point
    tick::Int      # this point's place among every step of the load, earliest first
end

"""One piece of loaded code as the load ran it."""
struct CodeLoad
    steps::Vector{LoadStep}      # its start, then the end of each include call and module block, in source order
    sites::Vector{BindingSite}   # the names it binds as it runs, in source order; its import clauses are its scan's
end

# The last step the load finished before it reaches `byte` in this code.
function step_before(load::CodeLoad, byte::Integer)
    found = first(load.steps)
    for step in load.steps
        step.byte < byte || break
        found = step
    end
    found
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

function is_enum_macro(node)
    JS.kind(node) == K"macrocall" || return false
    children = child_nodes(node)
    head = children[1]
    JS.kind(head) == K"macro_name" || return false
    parts = child_nodes(head)
    child_count(parts) == 1 || return false
    parts[1].val === :enum
end

# A named method binds its function, and `function f end` binds `f`. A method on another module's function, a
# callable type or a type's curly constructor adds to a binding made elsewhere.
function method_names!(names, form)
    children = child_nodes(form)
    head = children[1]
    if child_count(children) == 1
        name = node_symbol(head)
    else
        is_type_constructor(head) && return names
        name = sig_name(head)
    end
    isnothing(name) || push!(names, name)
    names
end

# `global x` and `global x = v` bind `x` wherever the line sits; `@enum E a b` binds the type and each instance.
function declared_names!(names, node, kind)
    if kind == K"global"
        for declared in child_nodes(node)
            target = declared
            if JS.kind(declared) == K"="
                target = first(child_nodes(declared))
            end
            _argname!(names, target)
        end
        return names
    end
    for argument in child_nodes(node)[2:end]
        listed = JS.kind(argument) == K"block" ? child_nodes(argument) : [argument]
        for item in listed
            _argname!(names, item)
        end
    end
    names
end

# The names a form Julia binds as a whole binds in its module; nothing for a form whose parts may bind. A method, a
# type, an assignment and an `@enum` bind outside local scopes; macro definitions, calls and import lines bind none.
function form_names(node, is_global::Bool)
    kind = JS.kind(node)
    names = Symbol[]
    kind == K"global" && return declared_names!(names, node, kind)
    if is_method_form(node)
        is_global && method_names!(names, node)
        return names
    end
    if is_type_form(kind)
        name = type_name(first(child_nodes(node)))
        is_global && !isnothing(name) && push!(names, name)
        return names
    end
    if kind == K"="
        is_global && _argname!(names, first(child_nodes(node)))
        return names
    end
    if is_enum_macro(node)
        is_global && declared_names!(names, node, kind)
        return names
    end
    is_opaque = kind == K"macro" || kind == K"call" || kind == K"dotcall" || kind == K"using" || kind == K"import"
    is_opaque ? names : nothing
end

# What the load runs among `node`'s children, in source order: each include call and module block on a branch the
# load takes, and while `binds` holds, the names each form binds in `owner`. Quoted code and method bodies run later.
function collect_parts!(events, sites, owner::Symbol, node, is_global::Bool, binds::Bool)
    inner_global = is_global && !is_local_scope(JS.kind(node))
    for child in live_children(node)
        if is_module_block(child) || is_include_call(child)
            push!(events, child)
        end
        JS.kind(child) == K"quote" && continue
        named = binds ? form_names(child, inner_global) : nothing
        if !isnothing(named)
            byte = JS.first_byte(child)
            for name in named
                push!(sites, BindingSite(owner, name, byte))
            end
        end
        is_method_form(child) && continue
        collect_parts!(events, sites, owner, child, inner_global, binds && isnothing(named))
    end
    events
end
