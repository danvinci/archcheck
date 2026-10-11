# A method whose function and every argument type sit outside its owner: the package, or the defining module, with
# an extension owning what the root owns. An owner's subtree is every module whose full name starts with its own.

# A value parameter stands for its type. A Symbol parameter belongs to nobody, so it counts as owned.
is_foreign(@nospecialize(x), owns) = is_foreign(typeof(x), owns)
is_foreign(::Symbol, _owns) = false
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
    members = union_members(union_type)
    any_member_foreign(members, owns)
end

# Type{T} belongs where T does. Any other type is foreign when its module and its parameters are.
function is_foreign(@nospecialize(datatype::DataType), owns)
    held = type_object_held(datatype)
    isnothing(held) || return is_foreign(held, owns)
    owns(parentmodule(datatype)) && return false
    all_foreign(datatype.parameters, owns)
end

function all_foreign(types, owns)
    for type in types
        is_foreign(type, owns) || return false
    end
    true
end

# A module's full name, `fullname(mod)`: the root's name, then each enclosing module's, then its own.
const ModulePath = Tuple{Vararg{Symbol}}

# Whether a module's full name is `scope` or starts with it; `exact` takes `scope` alone.
function is_in_scope(mod::Module, scope::ModulePath, exact::Bool)
    full = fullname(mod)
    exact && return full == scope
    full_length = length(full)
    scope_length = length(scope)
    taken = min(full_length, scope_length)
    prefix = full[1:taken]
    prefix == scope
end

function is_in_any_scope(mod, scopes, exact::Bool)
    for scope in scopes
        is_in_scope(mod, scope, exact) && return true
    end
    false
end

# Whether a module's `module` line sits in the package's extension directory.
function is_extension(mod::Module, repo)
    file, _ = module_site(mod, repo)
    parts = splitpath(file)
    first(parts) == EXTENSION_DIR
end

# The full module names whose functions and subtree types a method's module owns: the package's, or with `strict` its
# own. An extension adds the root's methods to its own and other packages' types, so it owns both in either mode.
function owner_scopes(home::Module, root::Module, strict::Bool, repo)
    package_scope = fullname(root)
    own_scope = fullname(home)
    is_extension(home, repo) && return ModulePath[own_scope, package_scope]
    strict && return ModulePath[own_scope]
    ModulePath[package_scope]
end

# module-piracy: the function is foreign to every owner scope, and every argument type to their subtrees. A keyword
# method is judged by the function it wraps.
function check_module_piracy(defined, root::Module; repo, strict::Bool)
    findings = Finding[]
    homes = unique(method.module for method in defined)
    scopes_by_home = Dict(home => owner_scopes(home, root, strict, repo) for home in homes)
    for method in defined
        home = method.module
        scopes = scopes_by_home[home]
        function_type, arguments = split_signature(method.sig)
        # A Union in the function slot is foreign when every member is foreign.
        members = union_members(function_type)
        owns_function = mod -> is_in_any_scope(mod, scopes, strict)
        all_foreign(members, owns_function) || continue
        owns_argument = mod -> is_in_any_scope(mod, scopes, false)
        all_foreign(arguments, owns_argument) || continue
        file, line = method_site(method, repo)
        owner = type_module(function_type)
        if isnothing(owner)
            owner_path = type_text(function_type)
        else
            full_owner = fullname(owner)
            owner_path = join(full_owner, ".")
        end
        signature = type_text(method.sig)
        evidence = [:owner => owner_path, :signature => signature]
        key = module_key(home)
        name = string(method.name)
        detail = "extends a function from outside its owner on no type its owner holds"
        finding = Finding(key, :module_piracy, file, name, line, detail, evidence)
        push!(findings, finding)
    end
    findings
end
