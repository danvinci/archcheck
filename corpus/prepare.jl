# Drop checkout-only pins so the cache tree resolves in a fresh environment.

function without_checkout_pins(project)
    kept = Dict{String,Any}()
    for (key, value) in project
        key == "workspace" && continue
        key == "sources" && continue
        kept[key] = value
    end
    kept
end

function retarget(tree)
    project_path = joinpath(tree, "Project.toml")
    parsed = TOML.parsefile(project_path)
    kept = without_checkout_pins(parsed)
    open(project_path, "w") do io
        TOML.print(io, kept)
    end
    manifest = joinpath(tree, "Manifest.toml")
    rm(manifest; force = true)
end

program = abspath(PROGRAM_FILE)
this_file = @__FILE__
if program == this_file
    using Pkg
    using TOML
    tree = ARGS[1]
    archcheck = ARGS[2]
    retarget(tree)
    host = PackageSpec(path = tree)
    gate_pkg = PackageSpec(path = archcheck)
    specs = [host, gate_pkg]
    Pkg.develop(specs)
end
