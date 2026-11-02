# Code in a listed module, or in a module nested in it, reaches only its own tree and the modules its list names,
# with what those enclose

const IMPORT_LISTS = load_package("ImportLists", """
include("numbers/Numbers.jl")
include("terms/Terms.jl")
include("plane/Plane.jl")
include("kernel/Kernel.jl")
""", [
    "numbers/Numbers.jl" => """
    module Numbers
    public f, Deep
    f() = 1
    module Deep
    public d
    d() = 4
    end
    end
    """,
    "terms/Terms.jl" => "module Terms\nexport g\ng() = 2\nend\n",
    "plane/Plane.jl" => "module Plane\npublic h\nh() = 3\nend\n",
    "kernel/Kernel.jl" => """
    module Kernel
    using ..Numbers
    using ..Terms: g
    import ..Plane
    reach() = Plane.h()
    deep() = Numbers.Deep.d()
    module Inner
    using ...Plane: h
    using ..Kernel
    end
    end
    """,
])

@testset "a listed module reaches only its own tree and the modules its list names" begin
    ctx = case_context(IMPORT_LISTS)
    package = IMPORT_LISTS.pkg
    allowlist = ImportAllowlist(package.Kernel => (package.Numbers, package.Terms))
    found = ArchCheck.run(allowlist, ctx)
    rows = evidence_rows(found, :via, :module)
    @test rows == [(:unlisted_import, "Plane", "import", "Kernel"),
                   (:unlisted_import, "Plane", "qualified", "Kernel"),
                   (:unlisted_import, "Plane", "using", "Kernel")]
    nested = only(finding for finding in found if ev(finding, :via) == "using")
    @test nested.mod === Symbol("Kernel.Inner")
    @test (nested.file, nested.line) == ("src/kernel/Kernel.jl", 8)
    every = (package.Numbers, package.Terms, package.Plane)
    widened = ImportAllowlist(package.Kernel => every, package.Terms => ())
    @test isempty(ArchCheck.run(widened, ctx))
    @test (:unlisted_import => :advisory) in ArchCheck.kinds(allowlist)
    @test_throws ArgumentError ImportAllowlist()
    @test_throws ArgumentError ArchCheck.run(ImportAllowlist(Base => ()), ctx)
end
