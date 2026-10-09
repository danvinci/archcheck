# A method whose function and every argument type sit outside the defining module's subtree.
# The subtree is every module whose full name starts with the defining module's own.

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

function owns_subtree(mod, home_name, depth)
    full = fullname(mod)
    taken = min(length(full), depth)
    prefix = full[1:taken]
    prefix == home_name
end

# module-piracy: the function is foreign to the defining module, and every argument type is foreign
# to its subtree. A keyword method is judged by the function it wraps.
function check_module_piracy(mods; repo)
    findings = Finding[]
    for method in project_methods(mods)
        home = method.module
        home_name = fullname(home)
        depth = length(home_name)
        function_type, arguments = split_signature(method.sig)
        # A Union in the function slot is foreign when every member is foreign.
        members = Base.uniontypes(function_type)
        owns_home = ==(home)
        all_members_foreign(members, owns_home) || continue
        owns_argument = mod -> owns_subtree(mod, home_name, depth)
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
        detail = "extends a function another module owns on no type its own subtree owns"
        finding = Finding(key, :module_piracy, file, name, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
