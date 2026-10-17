# ArchCheck

ArchCheck is an architecture gate for Julia packages that runs in the test suite. It checks how files and modules depend on each other, which names cross module boundaries, and where values are made and read.

Each finding states a fact the package's source, Julia's own load record or the compiler's inference proves. No finding rests on a score, a threshold or a confidence level, so a finding is either fixed or reported to ArchCheck as a bug.

## Quickstart

```julia
using Pkg; Pkg.add(url = "https://github.com/danvinci/archcheck")
```

Then, in `test/runtests.jl`:

```julia
using ArchCheck, MyPackage
ArchCheck.gate(MyPackage)
```

`gate` parses `src/` once and runs the default checks. It prints the findings new since the last run and writes every finding as a JSON line to `test/out/architecture.jsonl`. A finding of an error kind makes it throw; `error_kinds = (:dead_code,)` makes more kinds blocking. ArchCheck needs Julia 1.13.1 or later.

The gate parses files and runs its static checks in parallel when Julia has more than one thread, and its findings are byte-identical at any thread count. `Pkg.test` passes the parent's thread count on, so run `julia --threads=auto --project -e 'using Pkg; Pkg.test()'`.

## What it checks

By default (`ArchCheck.CHECKS`), the gate holds that:

- **Every source file is loaded code** (`Corpus`). Every file parses, and an include call in the loaded code names every `src/` file. The files a load includes, and the module each goes into, come from the record Julia keeps in the package's cache file. Without a cache file the gate follows the literal includes in the branches this Julia runs, and an include of a missing file or a computed path is a hole. A loaded module whose source the repository holds but no include reaches is a hole too.
- **Dependencies follow load order** (`ModuleBackEdges`, `ModuleCycles`, `FileBackEdges`). Modules and files depend only on what loads before them, with no cycles. A module may use the modules that enclose it; `strict = true` holds those to the order too. A definition that needs only lower layers is reported as one to move down (`Sinkable`, `FileSinkable`).
- **Modules meet through their published names** (`ReachesInternal`, `DeclaredModules`, `ForeignFields`). Code reaches any other module, Base and Core included, only through its exported or `public` names, in source, entry scripts and unloaded extensions alike. It declares each package module it reaches with a `using` or `import` line, and reads no field of a struct another module owns. A field read through an abstract annotation is reported only when every package struct declaring that field belongs to another module. `ReachesInternal(allowed = (Base.Compiler,))` names the outside modules a package reads on purpose.
- **Imports are explicit and used** (`ImportedNames`). A name read from outside comes through an import list rather than a bare `using`, and every name an import list binds is read, a method defined through it included.
- **Methods extend only what the package owns** (`ModulePiracy`). A method on an outside function takes a type the package owns; `strict = true` judges each module alone.
- **Exports are owned, defined and used** (`OwnerUniqueness`, `StaleExports`, `BlanketExports`, `DeadCode`). Each exported name has one owner and a definition, and nothing is exported wholesale. A module and the modules it encloses count as one owner, and a name only declared `public` is no export. Every function the package's loaded methods add to is used, with exported and `public` names counting as used unless `public_is_entry = false`.
- **Types and dispatch stay concrete** (`AbstractFields`, `BoxedCaptures`, `TypeBranches`). Struct fields have concrete types, judged by a container's own element types (`Vector{Vector{Any}}` is closed). Closures box no captured local, and dispatch picks a method's path rather than a runtime type test.
- **Every binding is read** (`UnusedBindings`: `unused_argument`, `unused_local`, `ignored_parameter`). Each argument and local a method names is read, and no position of a function is ignored by every method under one declared type. A name starting with `_` is exempt. A macro call counts a name as read when its expansion holds it, or when the expansion fails.
- **Shapes stay simple** (`TupleReturns`, `TupleIterations`, `ExpressionClones`, `StorageOverloads`). No function returns a bare tuple of three or more values, no flatten iterates a Tuple or NamedTuple, no expression is copied across methods, and no function takes the same values in two array storages.

Rules a package configures join through `checks = (ArchCheck.CHECKS..., ...)`:

| Check | A finding |
|---|---|
| `CallerWhitelist` | a reference to a listed function from a definition outside its allowed list, or from load-time code, cited at its first reference |
| `Independent` | a reference between modules declared independent |
| `DeclaredExtensions` | a method on another module's function that its owner leaves unmarked public, or undocumented in every module |
| `ReaderSet` | a concrete subtype no method of a required reader matches |
| `OptAnalysis` | a listed call whose inferred code dispatches at runtime or boxes a local |
| `InferredCalls` | a call no method matches at any argument type inference allows (`failing_call`), or a discarded call that writes nothing, cannot throw and returns a value at every argument its method accepts (`dropped_value`) |
| `UnreadWaits` | a discarded `fetch`, a `wait` the method graph's inference resolves to the wait on a task (needs `entries`), a `fetch` or `wait` passed to `foreach` or to a call whose value goes unread, or an `@sync` block |

## Declared values

A package names its expensive or meaning-bearing values with `Derived(producer; key, cache, readers, converters)` and passes them as `gate(MyPackage; derived = (...))`. The gate then holds that one function produces each value (`OneProducer`), its key names one evaluation (`CacheKeys`), its callers write the cache (`CachedCalls`), and it reaches only its readers (`DerivedReaders`).

## Methods a run never compiled

`UnreachedMethods` reports each method of the package that a run left uncompiled. The run is a `workload`, a function the gate calls before it reads Julia's method table:

```julia
ArchCheck.gate(MyPackage;
    checks = (ArchCheck.CHECKS..., UnreachedMethods()),
    workload = () -> MyPackage.main())
```

The package's own test suite serves as the workload when the gate runs at the end of `test/runtests.jl`, after the tests:

```julia
ArchCheck.gate(MyPackage;
    checks = (ArchCheck.CHECKS..., UnreachedMethods()),
    workload = PriorRun())
```

`PriorRun()` runs nothing, so `UnreachedMethods` reports the methods the tests never compiled; a test that errors inside a testset still counts every method it ran. An extension whose trigger only the tests load is judged too, since the gate reads the modules loaded when it runs. With `entries`, a method that a call in the method graph can land on counts as reached.

## Writing a check

A check is a `Check` subtype with `ArchCheck.kinds` and `ArchCheck.run` methods, passed through `checks`. `run` reads a `Context`: the one parse of the package (`ctx.index`), its loaded modules, and what the workload did. `ArchCheck.run(check, Context(MyPackage))` runs one check alone. A `Context`'s fields are ArchCheck's internal records and change between versions.
