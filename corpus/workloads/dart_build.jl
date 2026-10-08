if isdefined(Main, :Dart)
    root = pkgdir(Dart)
    script = joinpath(root, "scripts", "build.jl")
    Base.include(Main, script)
end

function corpus_build()
    build("corpus")
end
