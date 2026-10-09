# A method whose function and every argument type sit outside its owner: the package, or the defining module.
# An owner's subtree is every module whose full name starts with the owner's own.

# Every method a checked module defines, on any function, in source order.
function project_methods(mods)
    project = Set(mods)
    defined = Method[]
    Base.visit(Core.methodtable) do method
        method.module in project && push!(defined, method)
    end
    sort!(defined, by = method -> (string(method.file), method.line))
end

# A value parameter stands for its type. A Symbol parameter belongs to nobody, so it counts as owned.
is_foreign(@nospecialize(x), owns) = is_foreign(typeof(x), owns)
is_foreign(::Symbol, owns) = false
is_foreign(@nospecialize(typevar::TypeVar), owns) = is_foreign(typevar.ub, owns)
is_foreign(@nospecialize(vararg::Core.TypeofVararg), owns) = is_foreign(vararg.T, owns)

# A UnionAll is foreign when its body and its bound variable are both foreign.
function is_foreign(@nospecialize(unionall::UnionAll), owns)
    body_foreign = is_foreign(unionall.body, owns)
    body_foreign && is_foreign(unionall.var, owns)
end

function any_member_foreign(members, owns)
    for member in members
        is_foreign(member, owns) && return true
    end
    false
end

# One foreign member makes a Union foreign: Union{Owned,Int} claims Int as well.
function is_foreign(@nospecialize(union_type::Union), owns)
    members = Base.uniontypes(union_type)
    any_member_foreign(members, owns)
end

function parameters_foreign(datatype, owns)
    for param in datatype.parameters
        is_foreign(param, owns) || return false
    end
    true
end

# Type{T} belongs where T does. Any other type is foreign when its module and its parameters are.
function is_foreign(@nospecialize(datatype::DataType), owns)
    if Base.isType(datatype)
        held = only(datatype.parameters)
        return is_foreign(held, owns)
    end
    owns(parentmodule(datatype)) && return false
    parameters_foreign(datatype, owns)
end

function all_members_foreign(members, owns)
    for member in members
        is_foreign(member, owns) || return false
    end
    true
end

# Whether a module's full name is `scope` or starts with it; `exact` takes `scope` alone.
function is_in_scope(mod, scope, exact::Bool)
    full = fullname(mod)
    exact && return full == scope
    taken = min(length(full), length(scope))
    prefix = full[1:taken]
    prefix == scope
end

# module-piracy: the function is foreign to the owner, and every argument type to the owner's subtree. The owner
# is the package, or with `strict` the defining module. A keyword method is judged by the function it wraps.
function check_module_piracy(mods, root::Module; repo, strict::Bool)
    findings = Finding[]
    package_scope = fullname(root)
    for method in project_methods(mods)
        home = method.module
        scope = strict ? fullname(home) : package_scope
        function_type, arguments = split_signature(method.sig)
        # A Union in the function slot is foreign when every member is foreign.
        members = Base.uniontypes(function_type)
        owns_function = mod -> is_in_scope(mod, scope, strict)
        all_members_foreign(members, owns_function) || continue
        owns_argument = mod -> is_in_scope(mod, scope, false)
        arguments_foreign = true
        for argument in arguments
            is_foreign(argument, owns_argument) && continue
            arguments_foreign = false
            break
        end
        arguments_foreign || continue
        file, line = method_site(method, repo)
        owner = type_module(function_type)
        if isnothing(owner)
            owner_path = string(function_type)
        else
            full_owner = fullname(owner)
            owner_path = join(full_owner, ".")
        end
        signature = string(method.sig)
        evidence = [:owner => owner_path, :signature => signature]
        key = module_key(home)
        name = string(method.name)
        detail = "extends a function from outside its owner on no type its owner holds"
        finding = Finding(key, :module_piracy, file, name, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
