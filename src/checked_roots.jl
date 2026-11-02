# The code a syntax rule reads: the package's indexed source, and each file under the directories the rule names

# One piece of code a syntax rule walks: a module's indexed code, or a code root of a file outside src/
struct CheckedRoot
    mod::Symbol           # owning module; :Entry for a file outside the loaded modules
    path::String          # repo-relative path
    tree::JS.SyntaxNode   # the code, a module block in it walked as a root of its own
end

# Each entry script's code roots by its normalized absolute path, so a file the index already parsed parses once
function scripted_roots(index::SourceIndex)
    roots = Dict{String,Vector{JS.SyntaxNode}}()
    for code in index.scripts
        joined = isabspath(code.path) ? code.path : joinpath(index.repo, code.path)
        absolute = normpath(joined)
        held = get!(Vector{JS.SyntaxNode}, roots, absolute)
        push!(held, code.tree)
    end
    roots
end

# The code roots of one file outside the index: the entry scripts' when the index read it, else its own parse; none
# for a file that fails to parse
function outside_roots(scripted, parses::Parses, path::String)
    held = get(scripted, path, nothing)
    isnothing(held) || return held
    tree = parsed_tree(parses, path)
    isnothing(tree) && return JS.SyntaxNode[]
    code_roots(tree)
end

# The package's indexed code, then each `.jl` file under `dirs` the index does not hold as source. A directory is
# relative to the package root, as an entry dir is, or absolute
function checked_roots(index::SourceIndex, dirs::Vector{String})
    roots = CheckedRoot[]
    held = Set{String}()
    for file in index.files
        push!(roots, CheckedRoot(file.mod, file.path, file.tree))
        push!(held, file.path)
    end
    isempty(dirs) && return roots
    scripted = scripted_roots(index)
    parses = Parses(index.repo)
    for dir in dirs
        joined = isabspath(dir) ? dir : joinpath(index.repo, dir)
        for path in julia_files(joined)
            relative = relpath(path, index.repo)
            relative in held && continue
            push!(held, relative)
            for tree in outside_roots(scripted, parses, path)
                push!(roots, CheckedRoot(:Entry, relative, tree))
            end
        end
    end
    roots
end
