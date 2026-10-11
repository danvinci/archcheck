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

`gate` parses `src/` once and runs the default checks. It prints the findings new since the last run, writes every finding as a JSON line to `test/out/architecture.jsonl`, and throws on a finding of an error kind; `error_kinds = (:dead_code,)` makes more kinds blocking. ArchCheck needs Julia 1.13.1 or later.

With more than one thread, the gate parses and scans files and runs the static checks in parallel, and its findings are the same at any thread count. `Pkg.test` starts the test process with the parent's thread count, or `JULIA_NUM_THREADS` when set, so run `julia --threads=auto --project -e 'using Pkg; Pkg.test()'`.

## What it checks

By default (`ArchCheck.CHECKS`), the gate holds that:

- Every file parses, and an include call in the loaded code names every `src/` file. The files a load includes, and the module each goes into, come from the record Julia keeps in the package's cache file; a load with no cache file follows the literal includes in the branches this Julia runs, where an include of a missing file or of a computed path is a hole. A loaded module the index leaves unranked though the repository holds its source is a hole too. A module another package's macro fills with its own code holds no package source (`Corpus`).
- Modules and files depend only on what loads before them, with no cycles; a module may use the modules that enclose it (`ModuleBackEdges`, `ModuleCycles`, `FileBackEdges`, and `strict = true` to hold enclosing modules to the order too). A definition that needs only lower layers is reported as one to move down (`Sinkable`, `FileSinkable`).
- Code reaches any other module, the package's own or another package's, Base and Core included, only through its exported or `public` names, in source, entry scripts and extensions Julia has not loaded alike; it declares the package's modules it reaches with a `using` or `import` line in any of its files, and reads no field of a struct another module owns. An abstract annotation is judged by the concrete structs in the package that declare the field, and the read is reported when each of those structs belongs to another module (`ReachesInternal`, `DeclaredModules`, `ForeignFields`). `ReachesInternal(allowed = (Base.Compiler,))` names the outside modules whose internals the package reads on purpose.
- Each name a module reads from outside comes through an import list rather than a bare `using`, and each name an import list binds is read, a method defined through it included, bare or spliced into an `@eval` (`ImportedNames`).
- A method on a function from outside the package takes a type the package owns (`ModulePiracy`, and `strict = true` to judge each module alone).
- Each exported name has one owner and a definition, a module's own name is not an export it declares, a name only declared `public` is not an export, nothing is exported wholesale, and every function the package's loaded methods add to is used; a module and the modules it encloses count as one owner, and exported or `public` names count as used (`OwnerUniqueness`, `StaleExports`, `BlanketExports`, `DeadCode`, and `strict = true` or `public_is_entry = false` to tighten each).
- Struct fields have concrete types, a container by its own element types, so a concrete element closes it (`Vector{Vector{Any}}`), closures do not box captured locals, and dispatch picks a method's path rather than a runtime type test (`AbstractFields`, `BoxedCaptures`, `TypeBranches`).
- Each argument and local a method names is read, and no position of a function is ignored by every method under one declared type; a name starting with `_` is exempt, a keyword of a call binds no local, a macro Base or Core binds counts every name its call writes as read, and any other macro counts a name as read when its expansion holds that name or the expansion fails (`UnusedBindings`: `unused_argument`, `unused_local`, `ignored_parameter`).
- No function returns a bare tuple of three or more values, no expression is copied across methods, and no function takes the same values in two array storages (`TupleReturns`, `ExpressionClones`, `StorageOverloads`).

Rules a package configures join through `checks = (ArchCheck.CHECKS..., ...)`:

| Check | A finding |
|---|---|
| `CallerWhitelist` | a reference to a listed function from a definition outside its allowed list, or from load-time code |
| `Independent` | a reference between modules declared independent |
| `DeclaredExtensions` | a method on another module's function that its owner leaves unmarked public or undocumented |
| `ReaderSet` | a concrete subtype missing a method its supertype requires |
| `OptAnalysis` | a listed call whose inferred code dispatches at runtime or boxes a local |
| `InferredCalls` | a call no method matches at any argument type inference allows (`failing_call`), or a discarded call that writes nothing, cannot throw and returns a value at every argument its method accepts (`dropped_value`) |
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

`Rebuilds` reports a function evaluated again on equal arguments, and `TwoNames` two functions producing one value (a function returning its own argument produces none), each within one call of a probed caller; calls the workload makes itself are its own choice and stay unjudged. A `rebuild` carries `consistent` when the compiler proved the repeated code returns an equal result for equal arguments. `Waits` reports a waited result nobody reads, and `UnreachedMethods` the methods the run never compiled.

The package's own test suite serves as the workload when the gate runs at the end of `test/runtests.jl`, after the tests:

```julia
ArchCheck.gate(MyPackage;
    checks = (ArchCheck.CHECKS..., UnreachedMethods()),
    workload = PriorRun())
```

`PriorRun()` runs nothing, so `UnreachedMethods` reports the methods the tests never compiled; a test that errors inside a testset still counts every method it ran. An extension whose trigger only the tests load is judged too, since the gate reads the modules loaded when it runs. Probes record only calls made while they are armed, so the gate refuses them beside `PriorRun()`.

## Writing a check

A check is a `Check` subtype with `ArchCheck.kinds` and `ArchCheck.run` methods, passed through `checks`. `run` reads a `Context`: the one parse of the package (`ctx.index`), its loaded modules, and what the workload did. `ArchCheck.run(check, Context(MyPackage))` runs one check alone. A `Context`'s fields are ArchCheck's internal records and change between versions.
