# An uncalled definition is dead. A script entry keeps a name alive. A test entry does not.

function dead_symbols(case; entry_dirs = String[], public_is_entry = false)
    check = DeadCode(; public_is_entry)
    ctx = case_context(case; entry_dirs)
    found = ArchCheck.run(check, ctx)
    Set(finding.symbol for finding in found)
end

const DEAD_ENTRY_DIR = mktempdir()
write(joinpath(DEAD_ENTRY_DIR, "run.jl"), "entry()\n")
const DEAD_AND_CALLED = load_package("DeadAndCalled", """
include("body.jl")
""", ["body.jl" => "keep() = 1\ngone() = 2\nentry() = keep()\n"])

const DEFAULT_HELPER = load_package("DefaultHelper", """
owner(x = helper()) = x
helper() = 1
""")

const SCRIPT_ENTRY_DIR = mktempdir()
write(joinpath(SCRIPT_ENTRY_DIR, "run.jl"), "shipped()\n")
const SCRIPT_ENTRY = load_package("ScriptEntry", """
include("body.jl")
""", ["body.jl" => "shipped() = 1\n"])

const TEST_DIRECTORY = load_package("TestDirectory", """
include("body.jl")
""", ["body.jl" => "tested() = 1\n"])
const TEST_DIRECTORY_DIR = joinpath(TEST_DIRECTORY.root, "test")
mkpath(TEST_DIRECTORY_DIR)
write(joinpath(TEST_DIRECTORY_DIR, "runtests.jl"), "tested()\n")

const EXPORTED_NAME = load_package("ExportedName", """
export uncalled
include("impl.jl")
""", ["impl.jl" => "uncalled() = 1\n"])

const QUALIFIED_CALL = load_package("QualifiedCall", """
include("aa/Aa.jl")
using .Aa
include("cc/Cc.jl")
using .Cc
""", [
    "aa/Aa.jl" => "module Aa\ninclude(\"defs.jl\")\nend\n",
    "aa/defs.jl" => "helper() = 1\n",
    "cc/Cc.jl" => "module Cc\ninclude(\"caller.jl\")\nend\n",
    "cc/caller.jl" => "user() = Aa.helper()\n",
])

const LOCAL_BINDING_BODY = """
struct PosMark end
struct PosCallLaw end
struct PosWhereLaw{T} end
struct PosIndexLaw end
struct PosMarker end
struct PosOwner
    value::Int
    PosOwner(x = pos_ctor_helper()) = new(x)
end

labeled_owner() = (neg_label = pos_labeled_helper(),)
neg_label() = 1
pos_labeled_helper() = 1
nested_label_owner() = [(neg_nested_label = pos_nested_helper(),) for _ in (1,)]
neg_nested_label() = 1
pos_nested_helper() = 1
called_label_owner() = (pos_field = pos_items(),)
pos_items() = 1

keyed_owner(; knots = pos_keyed_helper()) = knots
pos_keyed_helper() = 1
same_owner(pos_same_helper = pos_same_helper()) = pos_same_helper
pos_same_helper() = 1
later_owner(x = pos_later_helper(), pos_later_helper = 1) = x
pos_later_helper() = 1
earlier_owner(neg_earlier_helper = () -> 2, x = neg_earlier_helper()) = x
neg_earlier_helper() = 1
keyed_same_owner(; pos_keyed_same_helper = pos_keyed_same_helper()) = pos_keyed_same_helper
pos_keyed_same_helper() = 1
function hid_owner(x = pos_hid_helper())
    pos_hid_helper = 1
    x
end
pos_hid_helper() = 1
anon_owner(::PosMark, x = pos_anon_helper()) = x
pos_anon_helper() = PosMark()
pos_ctor_helper() = 1
destruct_owner((neg_destruct_helper, value), x = neg_destruct_helper()) = x
neg_destruct_helper() = 1
where_owner(x::neg_tee) where neg_tee = x
neg_tee() = 1

pos_law_helper() = pos_leaf()
pos_leaf() = 1
(law::PosCallLaw)(x) = pos_law_helper()
function (law::PosWhereLaw{T})(x = pos_where_helper()) where {T}
    law
end
pos_where_helper() = 1
function Base.getindex(row::PosIndexLaw, index)
    pos_foreign_helper()
end
pos_foreign_helper() = 1

function global_owner()
    global pos_global_helper
    pos_global_helper()
end
pos_global_helper() = 1
function callback_owner()
    pos_callback_helper = 1
    callback = () -> begin
        global pos_callback_helper
        pos_callback_helper()
    end
    callback()
end
pos_callback_helper() = 1
function branch_owner()
    if true
        neg_branch_helper = 1
    end
    neg_branch_helper
end
neg_branch_helper() = 1
function try_owner()
    try
        neg_try_helper = 1
        neg_try_helper
    catch
        0
    end
end
neg_try_helper() = 1
lambda_owner() = map(x -> pos_lambda_helper(x), (1,))
pos_lambda_helper(x) = x
function let_owner()
    let neg_let_shadow = 1
        neg_let_shadow
    end
    pos_let_helper()
end
neg_let_shadow() = 1
pos_let_helper() = 1
function nested_global_owner()
    neg_nested_helper = 1
    callback = () -> begin
        global neg_nested_helper
        1
    end
    neg_nested_helper
    callback()
end
neg_nested_helper() = 1
gen_owner() = [pos_gen_helper(x) for x in (1,)]
pos_gen_helper(x) = x
ordered_owner(values) = [pos_leaf_j(neg_loop_j) for neg_loop_i in values for neg_loop_j in pos_produce(neg_loop_i)]
pos_leaf_j(j) = j
pos_produce(i) = (i,)
neg_loop_i() = 1
neg_loop_j() = 1
function nest_owner()
    inner(x = pos_inner_helper()) = x
    inner()
end
pos_inner_helper() = 1
function indexed_owner(values, index)
    pos_store[index] = values
end
pos_store() = 1
function typed_owner()
    neg_typed_local::PosMarker = pos_make()
    neg_typed_local
end
neg_typed_local() = 1
pos_make() = PosMarker()
"""

const LOCAL_BINDINGS = load_package("LocalBindings", """
include("types.jl")
include("body.jl")
include("ext.jl")
""", [
    "types.jl" => "struct PosExtLaw end\n",
    "body.jl" => LOCAL_BINDING_BODY,
    "ext.jl" => "(law::PosExtLaw)(x) = pos_ext_helper()\npos_ext_helper() = 1\n",
])

const LOCAL_BINDING_DEAD = (
    "neg_label", "neg_nested_label", "neg_earlier_helper", "neg_destruct_helper", "neg_tee",
    "neg_branch_helper", "neg_try_helper", "neg_let_shadow", "neg_nested_helper",
    "neg_loop_i", "neg_loop_j", "neg_typed_local",
)
const LOCAL_BINDING_LIVE = (
    "pos_labeled_helper", "pos_nested_helper", "pos_items", "pos_keyed_helper", "pos_same_helper",
    "pos_later_helper", "pos_keyed_same_helper", "pos_hid_helper", "pos_anon_helper", "pos_ctor_helper",
    "pos_law_helper", "pos_leaf", "pos_ext_helper", "pos_where_helper", "pos_foreign_helper",
    "pos_lambda_helper", "pos_let_helper", "pos_gen_helper", "pos_leaf_j", "pos_produce",
    "pos_inner_helper", "pos_store", "pos_make", "pos_global_helper", "pos_callback_helper",
)

@testset "an uncalled definition is dead and a called one stays" begin
    dead = dead_symbols(DEAD_AND_CALLED; entry_dirs = [DEAD_ENTRY_DIR])
    @test "gone" in dead
    @test !("keep" in dead)
    @test !("entry" in dead)
end

@testset "a default argument keeps its helper and the uncalled owner stays dead" begin
    dead = dead_symbols(DEFAULT_HELPER)
    @test "owner" in dead
    @test !("helper" in dead)
end

@testset "a script entry keeps a definition and a directory named test does not" begin
    lonely = dead_symbols(SCRIPT_ENTRY)
    @test "shipped" in lonely
    shipped = dead_symbols(SCRIPT_ENTRY; entry_dirs = [SCRIPT_ENTRY_DIR])
    @test !("shipped" in shipped)
    tested = dead_symbols(TEST_DIRECTORY; entry_dirs = [TEST_DIRECTORY_DIR])
    @test "tested" in tested
end

@testset "an export keeps a definition only when public names count as entries" begin
    dead = dead_symbols(EXPORTED_NAME)
    @test "uncalled" in dead
    published = dead_symbols(EXPORTED_NAME; public_is_entry = true)
    @test !("uncalled" in published)
end

@testset "a qualified call from another module keeps the definition" begin
    dead = dead_symbols(QUALIFIED_CALL)
    @test !("helper" in dead)
    @test "user" in dead
end

@testset "a local binding is not a call and a real call of another name still counts" begin
    dead = dead_symbols(LOCAL_BINDINGS)
    for name in LOCAL_BINDING_DEAD
        @test name in dead
    end
    for name in LOCAL_BINDING_LIVE
        @test !(name in dead)
    end
    @test !("PosCallLaw" in dead)
end
