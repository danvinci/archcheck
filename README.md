# ArchCheck

ArchCheck checks a Julia package's architecture in its test suite: how files and modules depend on each other, which names cross module boundaries, and where values are made and read.

## Quickstart

```julia
using Pkg; Pkg.add(url = "https://github.com/danvinci/archcheck")
```

Then, in `test/runtests.jl`:

```julia
using ArchCheck, MyPackage
ArchCheck.gate(MyPackage)
```

`gate` parses `src/` once and runs the default checks. It prints the findings new since the last run, writes every finding as a JSON line to `test/out/architecture.jsonl`, and throws on a finding of an error kind; `error_kinds = (:dead_code,)` makes more kinds blocking. ArchCheck needs Julia 1.13.

## What it checks

By default (`ArchCheck.CHECKS`), the gate holds that:

- Every file parses, every include resolves, and the package spine ranks every file and module (`Corpus`).
- Modules and files depend only on what loads before them, with no cycles (`ModuleBackEdges`, `ModuleCycles`, `FileBackEdges`). A definition that needs only lower layers is reported as one to move down (`Sinkable`, `FileSinkable`).
- Code reaches another module through its exported or `public` names, declared in its `using` and `import` lines, and reads no field of a struct another module owns (`ReachesInternal`, `DeclaredNames`, `DeclaredModules`, `PrivateImports`, `ForeignFields`).
- A method extends only functions its owner marks public and documents, and never pirates (`DeclaredExtensions`, `ModulePiracy`).
- Each exported name has one owner and a definition, nothing is exported wholesale, and every definition is used (`OwnerUniqueness`, `StaleExports`, `BlanketExports`, `DeadCode`).
- Struct fields have concrete types, closures do not box captured locals, and dispatch picks a method's path rather than a runtime type test (`AbstractFields`, `BoxedCaptures`, `TypeBranches`).
- No function returns a bare tuple of three or more values, no expression is copied across methods, and no function takes the same values in two array storages (`TupleReturns`, `ExpressionClones`, `StorageOverloads`).

Rules a package configures join through `checks = (ArchCheck.CHECKS..., ...)`:

| Check | A finding |
|---|---|
| `CallerWhitelist` | a call to a listed function from outside its allowed callers |
| `Independent` | a reference between modules declared independent |
| `ReaderSet` | a concrete subtype missing a method its supertype requires |
| `OptAnalysis` | a listed call whose inferred code dispatches at runtime or boxes a local |
| `OverlappingCalls` | two calls on one path that ask one question |
| `KeptBuilders` | a builder's result dropped where another method keeps it with `get!` |
| `SentinelReturns` | a public function returning `nothing`, `Inf`, `NaN` or `missing` |
| `StringPayloads` | a string-keyed dictionary whose values have no single layout |
| `ToleranceSearch` | a search predicate comparing against a named tolerance |
| `ScanSeeds` | fixed integer counts in one method forming a uniform grid |
| `UnreadWaits` | a discarded `fetch`, a bare `wait`, or an `@sync` block whose results nobody reads |

## Declared values

A package names its expensive or meaning-bearing values with `Derived(producer; key, cache, readers, converters)` and passes them as `gate(MyPackage; derived = (...))`. The gate then holds that one function produces each value (`OneProducer`), its key names one evaluation (`CacheKeys`), its callers write the cache (`CachedCalls`), and it reaches only its readers (`DerivedReaders`).

## Checks that watch a run

Given a `workload` and `Probes` naming the functions to record, the gate runs the code and checks what it did:

```julia
ArchCheck.gate(MyPackage;
    checks = (ArchCheck.CHECKS..., Rebuilds(), TwoNames(), Waits(), UnreachedMethods()),
    workload = () -> MyPackage.main(),
    probes = Probes(functions = (MyPackage.solve, MyPackage.load)))
```

`Rebuilds` reports a function evaluated again on equal arguments, `TwoNames` two functions returning one value, `Waits` a waited result nobody reads, and `UnreachedMethods` the methods the run never compiled.

## Writing a check

A check is a `Check` subtype with `ArchCheck.kinds` and `ArchCheck.run` methods, passed through `checks`. `run` reads a `Context`: the one parse of the package (`ctx.index`), its loaded modules, and what the workload did. `ArchCheck.run(check, Context(MyPackage))` runs one check alone.
