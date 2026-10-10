# A field whose stored type leaves dispatch open on an instance.

# Type variables bound by a UnionAll struct. A field type's own parameters are separate.
function struct_typevars(@nospecialize(declared))
    vars = TypeVar[]
    while declared isa UnionAll
        push!(vars, declared.var)
        declared = declared.body
    end
    vars
end

uses_struct_params(@nospecialize(param::TypeVar), vars) = param in vars

function uses_struct_params(@nospecialize(param::Union), vars)
    left_uses = uses_struct_params(param.a, vars)
    left_uses && return true
    uses_struct_params(param.b, vars)
end

uses_struct_params(@nospecialize(param::UnionAll), vars) = uses_struct_params(param.body, vars)

function uses_struct_params(@nospecialize(param::Core.TypeofVararg), vars)
    element_uses = uses_struct_params(param.T, vars)
    element_uses && return true
    isdefined(param, :N) || return false
    uses_struct_params(param.N, vars)
end

function uses_struct_params(@nospecialize(param::DataType), vars)
    for each in param.parameters
        uses_struct_params(each, vars) && return true
    end
    false
end

uses_struct_params(@nospecialize(::Any), ::Any) = false

# Type{Float64} names one type object. Type{<:T} names every subtype, so dispatch stays open.
function is_closed_type_object(@nospecialize(declared))
    unwrapped = Base.unwrap_unionall(declared)
    Base.isType(unwrapped) || return false
    held = only(unwrapped.parameters)
    held isa Type && isconcretetype(held)
end

# A vararg with no length parameter stays open, and so does one whose element type stays open.
# An integer length is closed. A length outside this struct's parameters stays open.
function vararg_is_open(@nospecialize(position), vars)
    held = position.T
    is_open_position(held, vars) && return true
    isdefined(position, :N) || return true
    length_param = position.N
    length_param isa Int && return false
    length_param isa TypeVar || return true
    !(length_param in vars)
end

is_open_position(@nospecialize(position::Core.TypeofVararg), vars) = vararg_is_open(position, vars)
is_open_position(@nospecialize(::UnionAll), ::Any) = true
is_open_position(@nospecialize(::Union), ::Any) = false
is_open_position(@nospecialize(position::TypeVar), vars) = !(position in vars)

function is_open_position(@nospecialize(position::DataType), vars)
    if Base.isType(position)
        held = only(position.parameters)
        return is_open_position(held, vars)
    end
    for param in position.parameters
        is_open_position(param, vars) && return true
    end
    isabstracttype(position)
end

is_open_position(@nospecialize(::Any), ::Any) = false

is_container_type(::Type{<:AbstractDict}) = true
is_container_type(::Type{<:AbstractArray}) = true
is_container_type(::Type{<:AbstractSet}) = true
is_container_type(@nospecialize(::Any)) = false

# A Dict element type is Pair, so its key and value are read apart.
# An array or a set is open when its element type is open.
function container_field_open(@nospecialize(declared))
    unwrapped = Base.unwrap_unionall(declared)
    isconcretetype(unwrapped) || return true
    if unwrapped <: AbstractDict && length(unwrapped.parameters) >= 2
        key_type = unwrapped.parameters[1]
        is_open_field(key_type) && return true
        value_type = unwrapped.parameters[2]
        return is_open_field(value_type)
    end
    element = eltype(declared)
    is_open_field(element)
end

is_open_field(@nospecialize(declared::TypeVar), vars) = !(declared in vars)
is_open_field(@nospecialize(::Union), ::Any) = false

# A small Union lowers into separate branches, so it stays closed.
# A struct parameter is fixed per instance; a free or abstract parameter stays open.
function is_open_field(@nospecialize(declared), vars = TypeVar[])
    is_closed_type_object(declared) && return false
    if uses_struct_params(declared, vars)
        return is_open_position(declared, vars)
    end
    if is_container_type(declared)
        return container_field_open(declared)
    end
    !isconcretetype(Base.unwrap_unionall(declared))
end

# The fields of a struct type, or of an instance an alias names, whose declared types leave dispatch open.
function open_fields(@nospecialize(declared))
    vars = struct_typevars(declared)
    body = Base.unwrap_unionall(declared)
    found = Tuple{Symbol,Any}[]
    # By position: a zip over `fieldnames` and `fieldtypes` compiles once per struct shape.
    for position in 1:fieldcount(body)
        field = fieldname(body, position)
        field_type = fieldtype(body, position)
        is_open_field(field_type, vars) || continue
        push!(found, (field, field_type))
    end
    found
end

# The name a `const name = ...` or `const name{T} = ...` binds; nothing for any other const form.
function const_bound_name(node)
    for assignment in child_nodes(node)
        JS.kind(assignment) == K"=" || continue
        target = first(child_nodes(assignment))
        if JS.kind(target) == K"curly"
            parts = child_nodes(target)
            target = first(parts)
        end
        return node_symbol(target)
    end
    nothing
end

# Where a module's code binds `name` with `const`. An alias has no def line of its own in the index's scans.
function const_site(index::SourceIndex, owner::Symbol, name::Symbol)
    for file in index.files
        file.mod === owner || continue
        for node in walk_nodes(file.tree)
            JS.kind(node) == K"const" || continue
            const_bound_name(node) === name || continue
            line = source_line(node)
            return (file.path, line)
        end
    end
    ("", 0)
end

function push_fields!(findings, owner, name, site, detail, fields)
    file, line = site
    for (field, declared) in fields
        symbol = string(name, ".", field)
        evidence = [:declared => string(declared)]
        finding = Finding(owner, :abstract_field, file, symbol, line, detail, evidence)
        push!(findings, finding)
    end
end

# A struct, judged by its own name at its definition.
function struct_findings!(findings, owner, @nospecialize(declared_type), name, sites)
    site = site_of(sites, owner, name, ("", 0))
    fields = open_fields(declared_type)
    detail = "the field's type leaves dispatch open"
    push_fields!(findings, owner, name, site, detail, fields)
end

# An alias of an instance opens a field only where the struct it names keeps that field closed.
function alias_findings!(findings, owner, @nospecialize(declared_type), name, family, index)
    struct_open = open_fields(family)
    kept_open = Set(first(each) for each in struct_open)
    instance_open = open_fields(declared_type)
    opened = filter(each -> !(first(each) in kept_open), instance_open)
    isempty(opened) && return
    site = const_site(index, owner, name)
    detail = "the instance this alias names opens a field its struct keeps closed"
    push_fields!(findings, owner, name, site, detail, opened)
end

function check_abstract_fields(mods, sites, index::SourceIndex)
    package = Set(mods)
    findings = Finding[]
    for mod in mods
        owner = module_key(mod)
        for name in names(mod; all = true)
            is_self = name === nameof(mod)
            is_internal = startswith(string(name), "#")
            (is_self || is_internal) && continue
            isdefined(mod, name) || continue
            declared_type = getproperty(mod, name)
            declared_type isa Type || continue
            body = Base.unwrap_unionall(declared_type)
            body isa DataType || continue
            isstructtype(body) || continue
            parentmodule(body) in package || continue
            family = body.name.wrapper
            is_own_name = declared_type === family && name === nameof(family) && parentmodule(body) === mod
            if is_own_name
                struct_findings!(findings, owner, declared_type, name, sites)
            else
                alias_findings!(findings, owner, declared_type, name, family, index)
            end
        end
    end
    findings
end
