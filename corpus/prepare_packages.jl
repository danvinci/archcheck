# Develop ArchCheck and add each package at its pinned release, in the active environment.
# usage: julia --project=<env> prepare_packages.jl <archcheck tree> <Name@version>...
using Pkg

# A VersionNumber names one release; a short version string such as "1.2" would admit a range.
function pinned_spec(text)
    parts = split(text, "@")
    name = String(parts[1])
    version = VersionNumber(parts[2])
    PackageSpec(name = name, version = version)
end

function prepare(args)
    archcheck = args[1]
    gate_pkg = PackageSpec(path = archcheck)
    Pkg.develop(gate_pkg)
    pinned = PackageSpec[]
    for text in args[2:end]
        push!(pinned, pinned_spec(text))
    end
    Pkg.add(pinned)
end

prepare(ARGS)
