using ArchCheck

include("drive.jl")

spec_path = ARGS[1]
spec = TOML.parsefile(spec_path)
statement = "using " * spec["module"]
parsed = Meta.parse(statement)
eval(parsed)
name = Symbol(spec["module"])
pkg = getfield(Main, name)
record_drive(spec, pkg)
