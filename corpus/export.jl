# Export one pinned tree per state and instantiate its environment.

function resolve_commit(repo, commit)
    raw = read(`git -C $repo rev-parse $commit`, String)
    strip(raw)
end

function stamp_text(lines)
    joined = join(lines, "\n")
    joined * "\n"
end

function same_stamp(path, text)
    isfile(path) || return false
    held = read(path, String)
    held == text
end

function file_digest(path)
    bytes = read(path)
    digest = sha256(bytes)
    bytes2hex(digest)
end

function reset_dir(path)
    rm(path; force = true, recursive = true)
    mkpath(path)
end

function export_commit(repo, commit, tree)
    reset_dir(tree)
    archive = `git -C $repo archive --format=tar $commit`
    extract = `tar -x -C $tree`
    stream = pipeline(archive, extract)
    run(stream)
end

function prepare_export(label, repo, commit, tree, stamp_path, archcheck)
    text = stamp_text(["commit=$commit", "archcheck=$archcheck"])
    if same_stamp(stamp_path, text)
        println("prepare ", label, " export reused")
        return
    end
    export_commit(repo, commit, tree)
    write(stamp_path, text)
    println("prepare ", label, " export")
end

function replace_tree(source, dest)
    rm(dest; force = true, recursive = true)
    parent = dirname(dest)
    mkpath(parent)
    cp(source, dest)
end

function prepare_mutant(label, base_tree, tree, script, repo, source_commit, stamp_path, archcheck)
    digest = file_digest(script)
    text = stamp_text(["commit=$source_commit", "script=$digest", "archcheck=$archcheck"])
    if same_stamp(stamp_path, text)
        println("prepare ", label, " export reused")
        return
    end
    replace_tree(base_tree, tree)
    run(`julia $script $tree $repo $source_commit`)
    write(stamp_path, text)
    println("prepare ", label, " export")
end

function ensure_project(env)
    mkpath(env)
    project = joinpath(env, "Project.toml")
    isfile(project) && return
    identity = uuid4()
    text = "name = \"CorpusEnv\"\nuuid = \"$identity\"\n"
    write(project, text)
end

function instantiate_env(env, prepare, arguments)
    reset_dir(env)
    ensure_project(env)
    withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
        run(`julia --project=$env $prepare $arguments`)
    end
end

# The stamp holds the prepare script's arguments, so changed arguments rebuild the environment.
function prepare_env(label, env, prepare, arguments, stamp_path)
    text = stamp_text(arguments)
    if same_stamp(stamp_path, text)
        println("prepare ", label, " instantiate reused")
        return
    end
    instantiate_env(env, prepare, arguments)
    write(stamp_path, text)
    println("prepare ", label, " instantiate")
end

function place_dir(cache, label, name)
    joinpath(cache, label, name)
end

function prepare_states(host, cache, label, archcheck, prepare)
    trees = Dict{String,String}()
    commits = Dict{String,String}()
    for state in host.states
        directory = place_dir(cache, label, state.name)
        mkpath(directory)
        tree = joinpath(directory, "tree")
        commit = resolve_commit(host.repo, state.commit)
        stamp = joinpath(directory, "export.stamp")
        prepare_export(state.name, host.repo, commit, tree, stamp, archcheck)
        env = joinpath(directory, "env")
        env_stamp = joinpath(directory, "env.stamp")
        arguments = [tree, archcheck]
        prepare_env(state.name, env, prepare, arguments, env_stamp)
        trees[state.name] = tree
        commits[state.name] = commit
        flush(stdout)
    end
    for mutant in host.mutants
        directory = place_dir(cache, label, mutant.name)
        mkpath(directory)
        tree = joinpath(directory, "tree")
        source = commits[mutant.source]
        stamp = joinpath(directory, "export.stamp")
        prepare_mutant(mutant.name, trees[mutant.base], tree, mutant.script, host.repo, source,
                       stamp, archcheck)
        env = joinpath(directory, "env")
        env_stamp = joinpath(directory, "env.stamp")
        arguments = [tree, archcheck]
        prepare_env(mutant.name, env, prepare, arguments, env_stamp)
        flush(stdout)
    end
end
