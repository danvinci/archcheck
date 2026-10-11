# A method whose function and every argument type sit outside its owner: the package, or the defining module, with
# an extension owning what the root owns. An owner's subtree is every module whose full name starts with its own.

# How a union counts. A value may hold any member, so one foreign member claims it: Union{Owned,Int} claims Int as
# well. A type object names one type, foreign only when every member is.
struct ValueUnion end
struct TypeObjectUnion end

# A value parameter stands for its type. A Symbol parameter belongs to nobody, so it counts as owned.
is_foreign(@nospecialize(x), owns, rule) = is_foreign(typeof(x), owns, rule)
is_foreign(::Symbol, _owns, _rule) = false
is_foreign(@nospecialize(vararg::Core.TypeofVararg), owns, rule) = is_foreign(vararg.T, owns, rule)

# A variable bounded by a union may stand for any member, so that bound is judged as a value; any other bound keeps
# the rule it sits under.
function is_foreign(@nospecialize(typevar::TypeVar), owns, rule)
    bound = typevar.ub
    bound isa Union && return is_foreign(bound, owns, ValueUnion())
    is_foreign(bound, owns, rule)
end

# A UnionAll is foreign when its body and its bound variable are both foreign.
function is_foreign(@nospecialize(unionall::UnionAll), owns, rule)
    body_foreign = is_foreign(unionall.body, owns, rule)
    body_foreign && is_foreign(unionall.var, owns, rule)
end

function is_foreign(@nospecialize(union_type::Union), owns, rule)
    members = union_members(union_type)
    union_foreign(members, owns, rule)
end

union_foreign(members, owns, rule::ValueUnion) = any_foreign(members, owns, rule)
union_foreign(members, owns, rule::TypeObjectUnion) = all_foreign(members, owns, rule)

# Type{T} belongs where T does, and names one type. Any other type is foreign when its module and its parameters are.
function is_foreign(@nospecialize(datatype::DataType), owns, rule)
    held = type_object_held(datatype)
    isnothing(held) || return is_foreign(held, owns, TypeObjectUnion())
    owns(parentmodule(datatype)) && return false
    all_foreign(datatype.parameters, owns, rule)
end

function any_foreign(types, owns, rule)
    for type in types
        is_foreign(type, owns, rule) && return true
    end
    false
end

function all_foreign(types, owns, rule = ValueUnion())
    for type in types
        is_foreign(type, owns, rule) || return false
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
function check_module_piracy(defined, root::Module; recorded::RecordedPaths, strict::Bool)
    findings = Finding[]
    repo = recorded.repo
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
        file, line = method_site(method, recorded)
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
