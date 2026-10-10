# Names a module imports: those that come in through a bare `using`, and those an import list binds that go unread.

# Test is the outside package; `println` comes through it from Base, so a clause's module and a name's owner are two.
# TestLogger, which Test exports, appears only bound locally, as a symbol, behind a module path, or as a declaration.
const LISTED_IMPORTS = load_package("ListedImports", """
using Test
using Test: @testset, @test_throws, println
using Test: detect_ambiguities as ambiguities
import Test: finish
using Test: detect_unbound_args
export @test_throws
eval(Expr(:public, :detect_unbound_args))
module Inner
export inner_name
inner_name() = 1
end
using .Inner
checked() = (@test(true), inner_name())
typed(error::TestSetException) = error
function shadows()
    TestLogger = 0
    TestLogger
end
quoted() = (:TestLogger, :println)
qualified() = Test.TestLogger
struct Holder
    TestLogger::Int
end
finish(holder::Holder) = holder
struct Tagged{TestLogger}
end
macro wrap(TestLogger)
    TestLogger
end
""", Pair{String,String}[], "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")

@testset "a module reads a name only a bare using brings in, or lists a name it leaves unread" begin
    ctx = case_context(LISTED_IMPORTS)
    found = ArchCheck.run(ImportedNames(), ctx)
    rows = [(f.kind, f.symbol, ev(f, :from), ev(f, :owner), f.line) for f in found]
    @test sort!(rows) == [
        (:implicit_import, "@test", "Test", "Test", 2),
        (:implicit_import, "Test", "Test", "Test", 2),
        (:implicit_import, "TestSetException", "Test", "Test", 2),
        (:stale_import, "@testset", "Test", "Test", 3),
        (:stale_import, "ambiguities", "Test", "Test", 4),
        (:stale_import, "println", "Test", "Base", 3),
    ]
end
