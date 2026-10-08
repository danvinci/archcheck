using ArchCheck

include("drive.jl")

spec_path = ARGS[1]
spec = read_host_spec(spec_path)
statement = "using " * spec["module"]
parsed = Meta.parse(statement)
eval(parsed)
name = Symbol(spec["module"])
pkg = getfield(Main, name)
drive_loaded(spec, pkg)
