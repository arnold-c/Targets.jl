# Implementation Plan: A targets-style Pipeline Package for Julia

This document merges the original design notes (`design-doc.md`) with the
implementation plan. It is the single source of truth for the package design.

## Overview and scope

The package lets users declare an analysis as named targets, each produced by a Julia function from upstream targets. It caches every result as a JLD2 file and, on each run, rebuilds only targets whose code, upstream data or input files changed. The working name in this plan is **Targets.jl**; rename freely.

Decisions already made:

- **API:** a function-based core (`target(:name, f)`, dependencies inferred from `f`'s argument names, with an explicit `deps` escape hatch), with a macro layer added at the end as pure sugar.
- **Change detection:** recursive hashing of the *source* of user functions, user-defined types and user globals. Hashes must not depend on the Julia version wherever source is available.
- **In scope beyond the core:** file targets, DAG visualization (whole graph or a subgraph), dynamic branching, forced rebuilds.
- **Out of scope for v0.1.0:** parallel execution (the design should not preclude it, see Phase 5, and the v0.2.0 roadmap, Phases 11–12); archiving timestamped copies of previous runs; carrying a target's store over when it is renamed (a rename simply rebuilds, and `tar_prune()` removes the old name).
- **Minimum Julia version: 1.10 (current LTS).** Package extensions and `getglobal` need ≥ 1.9; 1.10 gives the LTS a CI target.
- **Tests:** `@testitem`s from TestItems.jl, written in `src/` next to the code they test, run with `juliati`.

Success criterion for v0.1.0: running `tar_make()` twice in a row with no changes builds nothing; editing one function rebuilds exactly that function's targets and their affected descendants; an unchanged rebuilt output stops propagation (early cutoff); upgrading Julia does not, by itself, rebuild anything whose source could be located.

### Feature map from the original design notes

| Original idea | Where it lives now |
| --- | --- |
| Targets as vertices, dependencies as edges | Phase 2 (`Pipeline`, Graphs.jl `SimpleDiGraph`) |
| `tar_make` of one target builds the induced subgraph of everything it needs | Phase 2 subset builds (ancestor closure) |
| "Start at the furthest node, check outdated, move towards the target" | Phase 5: walking a deterministic topological order is equivalent |
| Handling several connected components separately | Not needed: the ancestor closure plus one topological order covers any number of components |
| Outdated if function hash or argument hash changed | Phase 4 staleness rules (`command_hash`, `code_hash`, `dep_hashes`) |
| Data files (watch) | Phase 7 file targets |
| `tar_load` creates objects named after targets | Phase 6 `@tar_load` macro |
| `tar_outdated` | Phase 4.4 / Phase 6 |
| `tar_map` | Static branching with a comprehension (Phase 8) |
| `tar_combine` | Explicit `deps` (Phase 1) for static branches; aggregate consumers for dynamic branches (Phase 8) |
| Propagating target name changes | Out of scope for v0.1.0: a rename rebuilds |
| `tar_visnetwork`, `tar_glimpse` on a single target | Phase 6 `tar_visnetwork(names = ...)` / `tar_dot(names = ...)` |
| `tar_make` in the global session or a separate process | Phase 5 `fresh = true` |
| `tar_invalidate` | Phase 6 |
| Timestamp and archive previous runs | Out of scope for v0.1.0 |

### Superseded ideas from the prototype

The prototype in `src/` is replaced, not extended (Phase 0). Its main lessons:

- **Hashing `code_typed(f, argtypes)` is the wrong primitive.** It needs the upstream *types* (so a no-op run must load every upstream object), includes line information (moving code triggers rebuilds), depends on what the optimizer happens to inline, and changes with the Julia version.
- **Eager `tar_target` calls cannot form a pipeline.** Declaring a target must not run it; `tar_make` owns execution.
- **One shared hash table rewritten after every target is fragile.** Per-target metadata files with atomic writes replace it.

## Package architecture

Keep the package as a handful of small, separately testable files, each owning one layer. The build loop should only orchestrate; it should never compute hashes or touch files directly.

| File | Responsibility |
| --- | --- |
| `src/Targets.jl` | Module, exports, includes; Aqua and JET test items |
| `src/target.jl` | `Target` struct, `target()` constructor, argument-name inference |
| `src/pipeline.jl` | `Pipeline` struct, validation, DAG construction, topological order, ancestor closure |
| `src/store.jl` | `_targets/` layout, JLD2 read/write, atomic writes, metadata I/O |
| `src/canonical.jl` | Julia-version-independent canonical encoding of `Expr`s and plain data |
| `src/source.jl` | Locating a method's source (CodeTracking, JuliaSyntax lambda locator, lowered fallback) |
| `src/hashing.jl` | Command, value, file and closure-capture hashing |
| `src/codedeps.jl` | Recursive discovery of user functions, types and globals reached by a target |
| `src/outdated.jl` | Staleness rules, `tar_outdated()` |
| `src/make.jl` | `tar_make()` build loop, logging, error handling, forced rebuilds |
| `src/branching.jl` | Dynamic branching (`pattern = ...`) |
| `src/api.jl` | `tar_read`, `@tar_load`, `tar_meta`, `tar_invalidate`, `tar_delete`, `tar_prune`, `tar_destroy`, `tar_manifest` |
| `src/graph.jl` | Layered layout and `tar_dot()` |
| `src/list.jl` | `tar_list()`: target names by section and connected component |
| `src/status.jl` | `tar_status()`: `tar_list()` with each target's status, coloured |
| `src/testing.jl` | `@testmodule` fixtures shared by scenario tests (throwaway projects) |
| `src/declarations.jl` | Declarations and fragments, assembled into targets by `tar_pipeline` |
| `src/macros.jl` | `@pipeline` / `@targets` / `@target` / `@map` / `@rep` sugar (last phase) |
| `ext/TargetsMakieExt.jl` | `tar_visnetwork()` drawing with plain Makie primitives, loaded when any Makie backend is |

**Dependencies.** Hard: JLD2.jl, Graphs.jl, CodeTracking.jl, JuliaSyntax.jl, ExpressionExplorer.jl (free names of `@target` expressions, added with the macro extension of Phase 9), TestItems.jl (its `@testitem` macro expands to nothing outside the test runner), and the stdlibs SHA, TOML, Dates, Serialization. Weak, through one package extension: Makie.jl (any backend the user loads, e.g. CairoMakie). GraphMakie was tried as well (first as a requirement, then as a second `engine`) and dropped: the layout, colours, labels and edges are computed here as `NetworkData`, so plain Makie scatter, arrows and text draw the same picture, and a second engine only cost a dependency, an extension and slow tests. Arrow ends are shortened by a fixed number of *pixels* (converted through the axis limits and figure size), not data units. Recommend Revise.jl to users, since CodeTracking finds REPL-defined methods only when Revise is loaded. `tar_meta()` and `tar_manifest()` return a `Vector` of `NamedTuple`s, which is Tables.jl-compatible, so DataFrames is not a dependency.

**Decision: package extensions for visualization.** Makie is heavy to load. Putting plotting in `ext/` keeps `using Targets` fast and means headless servers never pay for it. A Graphviz DOT export (`tar_dot()`) lives in the core, since it is plain string output.

## Phase 0: Clean slate

Remove the prototype so the new layers start from a clean, passing skeleton.

- Delete `src/tar_*.jl`, `src/hash_methods.jl`, `src/hash_df_funcs.jl`, `src/types.jl`, the `@static if false include("../test/hash.jl")` workaround, the checked-in `_meta/` directory, and the DrWatson scratch scripts `test/hash.jl` and `test/serialize.jl`.
- `Project.toml`: remove DataFrames, GLMakie, GraphMakie, MetaGraphsNext, JuliaFormatter and UnPack from `[deps]`; add the dependencies listed above; move GraphMakie to `[weakdeps]` with an `[extensions]` entry; set `julia = "1.10"` and add `[compat]` entries for every dependency (Aqua checks this).
- Replace `project_base()` with `project_root() = dirname(Base.active_project())`, erroring if there is no active project. The prototype's regex breaks on Windows.
- `test/runtests.jl`: run the test items with TestItemRunner; move the Aqua and JET checks into `@testitem`s in `src/Targets.jl`.

Done when: `juliati` runs the Aqua and JET items green on the empty skeleton.

## Phase 1: Target type and `target()` API

A target is a name plus a function whose argument names are, by default, the names of its upstream targets.

```julia
struct Target
    name::Symbol
    f::Any                            # a Function or callable object
    deps::Vector{Symbol}              # from f's argument names, or explicit
    format::Symbol                    # :jld2 or :file
    pattern::Union{Nothing,Symbol}    # dynamic branching (Phase 8)
    cue::Symbol                       # :thorough (default), :always, :never
    source::Union{Nothing,Expr}       # set by the macro layer (Phase 9)
end

target(name::Symbol, f; deps = nothing, format = :jld2, pattern = nothing, cue = :thorough) =
    Target(name, f, something(deps, arg_names(f)), format, pattern, cue, nothing)
```

**Decision: everything is a target, including constants.** A settings object becomes `target(:settings, () -> (alpha = 0.05, n_boot = 1000))`. A zero-argument function is a root target. Changing a setting invalidates exactly its consumers.

**Decision: one method, positional arguments only, when inferring.** `arg_names(f)` reads `Base.method_argnames(only(methods(f)))[2:end]`. Raise a clear error when `f` has several methods, keyword arguments or varargs, and suggest wrapping it in an anonymous function or passing `deps`. Isolate the `method_argnames` call in one helper and cover it with a test item, since it is a Base internal.

**Decision: explicit `deps` as the escape hatch.** With `deps = [...]`, upstream values are passed positionally in that order and `f` may be varargs. This is what makes combining static branches possible, since their names are generated and cannot be written as argument names:

```julia
models = (:ols, :lasso, :ridge)
fits = [target(Symbol(:fit_, m), clean_data -> fit(m, clean_data)) for m in models]
combined = target(:all_fits, (xs...) -> reduce(vcat, xs); deps = [Symbol(:fit_, m) for m in models])
```

When both are possible, validate that `length(deps)` is compatible with `f`'s arity.

**Decision: names are `Symbol`s and must be valid identifiers.** They become file names in the store, so reject anything that is not a valid Julia identifier. Uniqueness is checked at the pipeline level.

**Decision: underscore-prefixed arguments are not dependencies.** Not needed for v0.1.0, but reserve the convention (an argument named `_x` is ignored) so injected values such as a branch index can be added later.

Done when: `target()` returns correct `deps` for named functions, anonymous functions, zero-argument functions and explicit `deps`, and errors helpfully for multi-method functions.

## Phase 2: Pipeline construction and DAG

A `Pipeline` is a validated, ordered collection of targets plus the graph between them and the options that apply to the whole project, built once and never mutated.

```julia
struct Pipeline
    targets::Vector{Target}           # declaration order
    index::Dict{Symbol,Int}           # name => vertex
    graph::SimpleDiGraph{Int}         # edge dep => dependent
    order::Vector{Symbol}             # build order
    track::Vector{Any}                # extra Modules or paths treated as user code (Phase 4.2)
end

tar_pipeline(ts...; track = []) = Pipeline(flatten_targets(ts), track)
```

**Decision: the constructor is `tar_pipeline`, not `pipeline`.** `Base.pipeline` already exists (and is exported), so exporting a function of the same name makes `pipeline` ambiguous after `using Targets`. The macro `@pipeline` does not clash and keeps its name.

**Decision: `tar_pipeline` flattens.** Arguments may be `Target`s or (nested) vectors of `Target`s, so comprehensions for static branching can be passed directly. Anything else is an error naming the offending argument.

**Decision: where the pipeline is defined.** Mirror R's `_targets.R` with a `_targets.jl` file in the project root whose last expression returns a `Pipeline`. `tar_make()` with no arguments includes that file into a fresh anonymous module, then calls `tar_make(p::Pipeline)`. The fresh module avoids state leaking from the REPL between runs; the explicit `tar_make(p)` method stays available for tests and scripting.

**Validation, in this order, each with a specific error message:**

1. Target names are unique.
2. Every dependency names a defined target. Name the target and the missing dependency, and suggest close spellings.
3. The graph is acyclic. On a cycle, print the cycle itself (`a → b → c → a`), not just "cycle detected".
4. Branching targets reference a pattern target that is also one of their dependencies (Phase 8).

**Decision: deterministic build order.** Implement Kahn's algorithm, breaking ties by declaration order, rather than `topological_sort_by_dfs`. A stable order makes logs readable and tests reproducible, and matches reading `_targets.jl` top to bottom.

**Subset builds.** `tar_make(names = [:model])` builds the requested targets plus all their ancestors and nothing else. Compute ancestors by BFS on the reversed graph, then filter the stored order. This replaces the original design's per-component procedure: disconnected components need no special handling. The same `ancestors(p, names)` helper drives `tar_visnetwork(names = ...)` and forced rebuilds.

Done when: valid pipelines produce a stable order; each validation failure produces its own readable error; subset selection returns exactly the ancestor closure; nested vectors of targets are accepted.

## Phase 3: On-disk store and metadata

The store is a directory, `_targets/` by default, holding one JLD2 object and one metadata record per target, and every write to it is atomic.

```
_targets/
  store.toml            # store format version, Julia version, Manifest hash
  objects/model.jld2
  objects/fits/1a2b3c4d.jld2   # a branch (Phase 8)
  meta/model.toml
  meta/fits/1a2b3c4d.toml
  log/progress.log
  .gitignore            # "*" by default
```

**Decision: one TOML metadata file per target.** Per-target files are written once each, can be inspected by hand, and an interrupted run can never corrupt another target's record. `tar_meta()` assembles them into a table on demand.

Fields in each metadata record:

| Field | Purpose |
| --- | --- |
| `command_hash` | Hash of the target's own function source plus closure captures |
| `code_hash` | Combined hash of all user functions, types and globals it reaches (Phase 4) |
| `hash_source` | `source` or `lowered`: how the command was hashed (4.1) |
| `dep_hashes` | Upstream name → that upstream's `value_hash` at build time |
| `value_hash` | Hash of this target's output |
| `format` | `jld2` or `file` |
| `built_at`, `seconds` | Timing, for logs and `tar_meta()` |
| `error` | Last error message, empty on success |
| `julia_version` | Needed for `lowered` hashes (4.1); diagnostic otherwise |

**Decision: atomic writes everywhere.** Write to a temporary file in the same directory, then `mv(tmp, final; force = true)`. Write the object first and the metadata second: metadata is the commit marker, and an object without matching metadata is treated as outdated.

**Decision: never overwrite a good object with a failure.** When a target errors, record the error in its metadata and leave the last successful object in place.

**Decision: user types live in a named module.** JLD2 records each value's type by module path. Types defined inside `_targets.jl`, which is loaded into a fresh anonymous module each run, will not resolve when loaded later. Users keep functions and types in a project-local module or package (for example `src/MyAnalysis.jl` loaded with `using MyAnalysis`) and keep `_targets.jl` to target declarations. On a JLD2 load failure, say this in the error.

**Store versioning.** Write `store.toml` with a format version from day one, so later layout changes can be detected and migrated instead of silently misread.

Done when: values round-trip through JLD2; killing a write mid-way never leaves a corrupt or half-committed target; `tar_meta()` returns a table of all records.

## Phase 4: Hashing, staleness and function tracking

A target is rebuilt when its own code, any user function, type or global it reaches, any upstream value or its input file has changed; this phase computes each of those hashes and compares them with the stored record.

### 4.1 Hash primitives and locating source

Use SHA for everything that is persisted. Never persist `Base.hash`, which is not stable across Julia versions or sessions.

**Decision: hash a canonical encoding, not `string(expr)` or `Serialization` bytes.** Both `Expr` printing and the `Serialization` format may change between Julia versions. `canonical.jl` defines one recursive writer that emits a tagged byte stream for `Expr` (head and arguments), `Symbol`, `QuoteNode`, strings, numbers, `Bool`, `Char`, `nothing`, tuples, `NamedTuple`s, `Pair`s, arrays, `Dict`s (sorted by key encoding) and plain immutable structs (type name plus fields). `canonical_hash(x) = bytes2hex(sha256(canonical_bytes(x)))`. Values it cannot encode fall back to `Serialization` bytes and are reported as version-dependent. This one primitive is used for source, closure captures, globals and branch elements.

**Decision: hash the actual method definition, so a Julia upgrade does not rebuild.** For every method, locate its source text, parse it, strip `LineNumberNode`s and hash the canonical encoding of the **un-expanded** expression. Macro expansion is used only for discovering callees (4.2), never for the hash, because Base macros such as `@.` may expand differently across Julia versions. Comments, whitespace and moving code cause no rebuild.

Source is located in this order:

1. **Macro targets** carry their right-hand side in `Target.source` (Phase 9); use it directly.
2. **Named functions, constructors and anonymous functions:** `CodeTracking.definition(Expr, m)` returns `nothing` unless Revise is loaded and tracking the file (and, for lambdas, over-captures from the start of the line, which fails inside a `tar_pipeline(...)` call or a comprehension), so it is not used. Instead, ask `CodeTracking.whereis(m)` for the method's current file and line (which stays correct under Revise even after edits above it), parse the file with JuliaSyntax (cached, keyed by path and modification time), and collect the definition nodes at that line: `function` and short-form `f(x) = ...` definitions whose name matches `m.name` (keyword-argument body methods named `#f#N` map back to `f`), and `->`, anonymous `function` and `do` nodes. Julia records the line of a multi-line lambda or `do` body's first statement rather than of its arrow, so a lambda matches when either its first line or its body's first line equals the method's line.
   *Closures with plain names* (`function cached(...)` inside a function or `let` block) are the exception: Revise cannot map them, so they keep the line recorded when the code creating them ran, and after an edit above that code the line no longer holds their definition, while a fresh session finds it there. When nothing matches at the recorded line, such a closure is looked up by name and positional argument names in the whole file; a unique match is hashed, so a Revise session and a fresh one agree. This is only done while the closure still runs what its code now makes: Revise re-evaluates an edited function but not a `const` holding a closure it made, so the closure's lowered code, with generated functions fingerprinted the same way and Julia's counters stripped, is compared with that of the newest closure of its kind. If they differ, the old closure is hashed by its lowered code, which differs from the fresh session's hash and rebuilds what it computed.
3. **Disambiguation:** keep anonymous candidates whose argument names match `method_argnames(m)`. If exactly one remains, hash it. If several remain (two identical-signature lambdas on one line), hash all of them in source order: editing one rebuilds its line-mates, which is conservative and never stale.
4. **Fallback: lowered code.** If no source can be located (methods created by `eval`, or a REPL without Revise), hash `code_lowered` with line information stripped and record `hash_source = "lowered"` in the metadata. Lowered code changes between Julia versions, so when `store.toml`'s Julia version differs from the running one, these targets (and only these) are outdated with reason `:julia_version_changed`. `tar_make` warns once per run, naming the targets that rely on the fallback.
5. If even lowering fails, warn and treat the target as `cue = :always`, so the package is never silently wrong.

**Decision: closure captures are part of `command_hash`.** Loop-generated closures share one source text, so source hashing alone cannot tell `fit(:ridge, ...)` from `fit(:lasso, ...)`. A closure is an object whose fields are its captured variables: add `canonical_hash` of each captured field to the command hash. Captured values that are themselves user functions are followed by 4.2 instead of being serialized.

### 4.2 Recursive discovery of user code

For each target, find every user-defined function, type and global its code can reach and hash all of them.

1. Take the target function's source `Expr` (4.1), and `macroexpand` it in the method's module so calls generated by macros (such as `@chain`) are visible. For fallback (lowered) methods, read the `GlobalRef`s from the lowered code instead.
2. Walk the expression and collect every `Symbol`, `GlobalRef` and qualified name (`Mod.f`). Collect all references, not just call heads: `map(clean_row, rows)` passes a function as an argument.
3. Resolve each name in the method's module with `isdefined` and `getglobal`. Ignore names that resolve to modules or are not defined (local variables).
4. Keep only bindings owned by **user code** (see below), then hash by kind:
   - **Functions:** hash **all** methods, each by its source (4.1), sorted by hash so the result is independent of method-table order. Recurse into each method's body. A function value that is a closure (or a callable struct such as `Base.Fix1`) also runs what it captured, which no source names: `const cached = make_cache(build)` calls `build` through a captured variable. Captured functions are followed and captured types considered; other captured values (a cache the closure fills) are state, not code, and are not hashed.
   - **Types** (`DataType`, or a `UnionAll` unwrapped to one): hash the type's name, supertype, type parameters, field names and field types, plus all its constructor methods by source. Recurse into field types and constructor bodies. A `struct` edit generally needs a restart (or Revise on Julia ≥ 1.12), which the stale-session guard reports.
   - **Other globals** (`const ALPHA = 0.05`, a lookup table): hash the current value with `canonical_hash`. Memoize per run, since large globals can be costly to encode.
5. Keep a visited set to handle recursion and mutual recursion.
6. Combine into `code_hash = sha256(join(sort(["$(qualified_name)=$(h)" for each binding])))`.

**Decision: "user code" means files under the project root or under a tracked location.** A binding is user code when its defining file (a method's `file`, or for types and globals the file of the owning module's definition via `pathof`/`pkgdir`) lies under the directory of the active `Project.toml`, or under one of the pipeline's `track` entries. `track` accepts `Module`s (resolved with `pkgdir`) and directory paths, so a package `Pkg.develop`'d from elsewhere can be tracked:

```julia
tar_pipeline(targets...; track = [MyLabUtils, "../shared-code"])
```

Base, stdlibs and installed packages are not tracked; their changes are handled by 4.5.

**Memoize within a run.** Cache each binding's hash in a `Dict` for the duration of one `tar_make()`.

**Known limits, to document rather than solve:** functions reached only through dynamic dispatch on runtime values (`getfield(mod, sym)`, functions stored inside data) and `@generated` functions. The `cue = :always` option and `force = true` (Phase 5) cover them.

**Decision: guard against stale sessions.** CodeTracking and the JuliaSyntax locator read files from disk. If a user edits `src/MyAnalysis.jl` without Revise and without restarting, the hash reflects the new file while the session runs the old code. A start-up timestamp cannot say when a file was *loaded* (a script included after `using Targets` and edited before loading would be a false alarm), so `Targets.__init__` instead registers a `Base.include_callbacks` hook that records a content hash of every file as it is included. If Revise is not loaded and a user file reached by a target now has different contents from when it was included, `tar_make` errors with a message to load Revise, restart, or use `fresh = true` (`check_stale = false` opts out). Files whose load was not observed (for example precompiled package files) are not checked: Julia itself validates those when loading, and `fresh = true` covers the rest. With Revise loaded, call `Revise.revise()` before hashing.

**Decision: implementation notes for 4.2 (M2).** The project directory is a parameter (`tar_make(...; root = ...)`, default the active project) so tests can use throwaway projects. Reaching a binding is resolved in the latest world (`invokelatest`), because a script included by `tar_make` defines bindings after the running code was compiled. A *user module* is one whose root is `Main` (scripts, fixtures, the REPL) or whose package source lies under the project or a `track` location; globals owned by such modules are hashed by value, and types by name, supertype, fields, parameters and constructors. Entries are keyed by module and name, never by method signature, so code hashes do not depend on how Julia prints signatures.

### 4.3 Value hashing and early cutoff

**Decision: hash the written JLD2 file's bytes by default, with a user hook.** Expose `Targets.value_hash(x)`, returning `nothing` by default; users can add methods for their own types to return a semantic hash. When it returns `nothing`, hash the object file.

A non-deterministic value hash only costs efficiency, never correctness: identical data hashing differently rebuilds downstream targets unnecessarily, but nothing stale is ever kept. Add test items that check byte-stability for common types (arrays, `NamedTuple`, `Dict`, a DataFrame); if JLD2 output turns out unstable for important types, switch the default to `canonical_hash` of the value.

Early cutoff falls out naturally: a rebuilt target with an unchanged `value_hash` leaves its children's recorded `dep_hashes` matching, so they are not outdated.

### 4.4 Staleness rules

`is_outdated(t)` checks these in order and returns the **first reason** that applies, or `nothing`. Returning a reason powers `tar_outdated()` explanations and the progress log.

1. `force` covers this target (Phase 5) → `:forced`.
2. `cue = :never` → never outdated if an object exists; `cue = :always` → `:always`.
3. No metadata record, or no object file → `:missing`.
4. The last build errored → `:errored`.
5. `hash_source = "lowered"` and the Julia version changed → `:julia_version_changed`.
6. `command_hash` differs → `:command_changed`.
7. `code_hash` differs → `:code_changed`.
8. The list of dependency names differs from the recorded one → `:deps_changed`.
9. Any upstream's current `value_hash` differs from the one recorded in `dep_hashes` → `:upstream_changed`.
10. For file targets, the file's content hash differs (Phase 7) → `:file_changed`.

During `tar_make()` these checks run in build order, so each upstream's metadata is already final when its children are checked.

**Decision: `tar_outdated()` is conservative.** Without building, you cannot know whether a rebuilt upstream will produce the same value. Report every descendant of an outdated target as outdated (reason `:upstream_outdated`), as the R package does. The actual build may then skip some of them via early cutoff.

### 4.5 Package versions

**Decision: warn, don't invalidate, by default.** Store a hash of `Manifest.toml` in `store.toml`. When it changes, print which packages changed and suggest `tar_make(force = true)` or `tar_invalidate()`. Offer an opt-in `track_manifest = true` that invalidates everything instead.

Done when: editing a helper two calls deep rebuilds the right targets; editing a comment rebuilds nothing; adding a method to a used function rebuilds its consumers; editing a used `const` or struct rebuilds its consumers; editing a tracked external package rebuilds its consumers; a rebuilt-but-identical target stops propagation; hashes computed on Julia 1.10 and the latest release are identical for source-hashed targets.

## Phase 5: The `tar_make()` build loop

`tar_make()` walks the pipeline in build order, rebuilds each outdated target from its upstream values, commits the result, and returns a summary of what it did.

```julia
function tar_make(p::Pipeline; names = nothing, force = false, store = "_targets",
                  keep_going = false, fresh = false)
    s = open_store(store)
    selected = selected_order(p, names)       # names plus all ancestors
    ctx = BuildContext(p, s; forced = force ? Set(selected) : Set{Symbol}())
    for name in selected
        t = p.targets[p.index[name]]
        reason = is_outdated(ctx, t)
        reason === nothing && (log_skip(ctx, t); continue)
        build!(ctx, t, reason; keep_going)
    end
    return summary(ctx)                       # (built, skipped, errored)
end
```

**Decision: `force` rebuilds the selection and all its dependencies.** `tar_make(names = [:model], force = true)` rebuilds `:model` and every ancestor of it, regardless of status; without `names` it rebuilds the whole pipeline. Descendants outside the selection are not built, but their recorded `dep_hashes` will be compared on the next run, so early cutoff still applies. This is the manual override for the known limits of 4.2 and for package updates (4.5).

**Decision: structure the loop as a ready-queue scheduler, even single-threaded.** Keep a set of targets whose dependencies are all finished and pop from it in declaration order. In v0.1.0 this behaves exactly like walking the topological order; adding parallelism later means spawning one task per ready target instead of rewriting the loop (see Phase 11). *Status: M1 walks `p.order` directly, which is equivalent; the loop body is already factored into `process!`/`build!` so the queue can be introduced in M3 without touching them.*

**Decision: an in-memory value cache with reference counting.** When a target is built or loaded, keep its value in a `Dict{Symbol,Any}` with a count of how many downstream targets in this run still need it. Decrement after each consumer runs and drop the value at zero. Load from JLD2 only on a cache miss.

**Calling user code.** Call `Base.invokelatest(t.f, args...)`, with `args` in `t.deps` order, because `_targets.jl` and user modules may have been (re)defined after `tar_make` was compiled. Time the call with `@elapsed`, then write the object, then the metadata.

**Decision: errors stop the run by default.** On an exception, record the message and backtrace summary in the target's metadata, keep its previous object, and rethrow after flushing the log. With `keep_going = true`, mark the failed target's descendants as `:skipped_upstream_error` and continue building everything independent of it. Catch `InterruptException` separately: commit nothing for the interrupted target and rethrow immediately.

**Logging.** One line per target, to the terminal and to `log/progress.log`, including the reason from Phase 4: `▶ model (code_changed)`, `✔ model 12.4s`, `✖ model: DimensionMismatch…`, `· clean_data up to date`. Finish with a one-line summary.

**Decision: offer a fresh-process build.** `tar_make(; fresh = true)` runs `julia --project=<active project> -e 'using Targets; tar_make(...)'` in a subprocess, forwarding `names` and `force`, like the R package's `callr` default. It eliminates stale-session problems. In-process stays the default because of Julia's startup latency; recommend `fresh = true` for final and CI runs.

Done when: a second run with no changes builds nothing and reads no object files; `force = true` with `names` rebuilds exactly the ancestor closure; memory stays bounded on a long chain of large targets; `keep_going` builds independent branches after a failure.

## Phase 6: User helpers and DAG visualization

Once the core works, the helpers are thin wrappers over the store and the staleness rules; most are under 20 lines each.

| Function | Behavior |
| --- | --- |
| `tar_read(:name)` | Return a target's stored value (programmatic use) |
| `@tar_load model clean_data` | Assign stored values to same-named variables in the caller's scope (interactive use) |
| `tar_manifest()` | Table of targets, dependencies and formats, without touching the store |
| `tar_list()` | Target names without dependencies: constants, input files, computations and output files, per connected component, in build order (alphabetical within a layer) |
| `tar_status()` | `tar_list()` with each target's status (as in `tar_dot`, plus the reason for outdated ones), coloured in the terminal: up to date green, outdated yellow, errored red, not built blue |
| `tar_outdated()` | Outdated targets with the reason for each (Phase 4) |
| `tar_meta()` | All metadata records as a table |
| `tar_invalidate(:name)` | Delete the metadata record so the target rebuilds; keep the object |
| `tar_delete(:name)` | Delete object and metadata |
| `tar_prune()` | Delete objects and records for targets no longer in the pipeline (including renamed ones) |
| `tar_destroy()` | Delete the whole store, after a confirmation prompt |
| `tar_dot(; names = nothing)` | Graphviz DOT text of the DAG or a subgraph, colored by status |
| `tar_visnetwork(; names = nothing)` | Plot of the DAG or a subgraph (Makie extension) |

**Decision: `@tar_load` is a macro, not a function that writes into `Main`.** A macro expands to `model = tar_read(:model)` in the caller's own scope, which works inside functions, modules and tests.

**Decision: `tar_invalidate` keeps the object.** Deleting only metadata forces a rebuild while leaving `tar_read` working in the meantime. `tar_delete` is the explicit way to remove data.

**Decision: reads say when a value is stale.** `tar_read` and `@tar_load` take `on_outdated = :warn | :error | :ignore`, defaulting to the `on_outdated` preference of Targets (Preferences.jl, `LocalPreferences.toml`), else `:warn`. When reading the project's own store (or given `script`), the check is `tar_outdated` on the pipeline for the requested targets, so code edits count; otherwise, and for targets no longer in the pipeline, only a missing record (invalidated) counts. `@tar_load` checks its names together, so it gives at most one warning. `:ignore` also skips the check, which loads the pipeline and hashes code.

### Visualization

**Decision: subgraphs by name.** `tar_visnetwork(names = [:model])` and `tar_dot(names = [:model])` show the named targets and their ancestors (the same `ancestors` helper as subset builds), which is the original `tar_glimpse` idea. A `descendants = true` keyword adds everything downstream of the named targets, for answering "what does this feed into?". `names = nothing` shows the whole pipeline.

**Decision: compute the layout yourself, by layers.** Assign each target a layer equal to its longest-path depth from any root within the displayed subgraph, place layers left to right, and order targets within a layer by declaration order (later, by a barycenter pass to reduce crossings). This needs no extra dependency and is shared by `tar_dot()` (as `rank` hints) and `tar_visnetwork()` (as explicit node positions for Makie).

**Encoding.** Color nodes by status: up to date, outdated, errored, and not yet built. Use a distinct shape for file targets and show branch counts in the label of branching targets (`fits [24]`). Reserve a `targets_only = true` keyword for later showing user functions as nodes.

**Decision: an interactive view, still without GraphMakie.** `tar_visnetwork` is interactive by default when GLMakie (a window) or WGLMakie (a browser tab) is the active backend (`interactive = nothing`, decided after the pipeline script is loaded, since loading a backend activates it); `interactive = false` forces a static figure, and `interactive = true` errors with advice under any other backend. WGLMakie is displayed with `resize_to = :body`, so the figure fills the browser tab and follows its size. A click selects a target, shift-click toggles one, and shift-drag selects an area; dragging a selected target moves the selection. A side panel hides targets by `tar_list` section and by status (checkboxes, which double as the colour legend), the selection ("Hide selected"), or everything but the selection ("Show only selected", which does nothing when nothing is selected). Two switches ("Also show") bring back the dependencies or descendants of the targets still shown (recursively, overriding any hiding), e.g. to restore what the rest needs after hiding a selection. They start from the targets not hidden by hand or by kind, ignoring what the other switch shows, so they combine independently; what they show is fixed when switched on, so selecting or hiding other targets afterwards does not change it. "Show all" undoes all of it. Hidden targets keep their place (no re-layout), and their markers, labels and edges become transparent or zero-length, since Makie Observables cannot change length mid-update. Everything is drawn from a `NetworkState` of Observables, and the interactions are tested by feeding keyboard and mouse events to a figure. Node positions live in an `Observable`; edges (re-shortened in pixels on zoom, pan and resize) and labels follow them. A custom axis interaction replaces rectangle zoom: left-dragging a node moves it, left-dragging the background pans; Makie's scroll zoom, right-drag pan and ctrl-click reset stay. Hit-testing is done in pixels from the axis limits rather than with `pick`, so it is backend-independent and tested by feeding mouse events to a figure.

**Status is computed, not stored.** Both call `tar_outdated()`, so the graph always reflects the current code and store.

Done when: each helper has a test item; the plot and DOT output show correct colors after an edit; `names` restricts both to the expected subgraph; `@tar_load` works inside a function and a module.

## Phase 7: File targets

A file target returns one or more paths, and its value hash is the hash of those files' contents, so editing an input file or deleting an output file triggers a rebuild.

```julia
target(:raw_file, () -> "data/raw.csv"; format = :file)
target(:raw_data, raw_file -> CSV.read(raw_file, DataFrame))
target(:figure, model -> (save("output/fit.png", plot_fit(model)); "output/fit.png"); format = :file)
```

The same mechanism covers **input files** (a zero-argument function returning a path the user maintains) and **output files** (a function that writes a file and returns its path).

**Decision: no JLD2 object for file targets.** The value is the path or vector of paths, stored in the metadata record with the content hash. Downstream targets receive the path, not the contents. For file targets, staleness rule 3's "object missing" means "any returned file missing".

**Decision: re-check files on every run, cheaply.** Store each file's size and modification time with its hash; if both match, reuse the stored hash, otherwise re-hash the contents.

**Decision: content hash, not modification time, decides.** A file that was touched but not changed gets the same hash, so nothing downstream rebuilds.

**Details to settle in implementation:**

- **Directories.** Hash every file underneath in sorted path order, combining relative path and content, so renames count as changes.
- **Paths.** Store paths relative to the project root, so a project can be moved or cloned. Warn on absolute paths outside the project. Normalize separators so stores are portable between platforms. Because relative paths mean "relative to the project root", `tar_make` runs the build loop with the working directory set to the root (restored afterwards), so a target can write `output/fit.png` and consumers can read the path they receive. Store paths (`Store` roots) are made absolute up front so this change of directory cannot break them.
- **Staleness.** A file target is `:missing` if any recorded file is gone, and `:file_changed` if the combined hash (paths plus contents) differs. Its consumers see that hash as their upstream hash, so they rebuild when it changes, and early cutoff then applies to *their* outputs. Edits that keep both size and modification time are invisible to the stat shortcut (as in the R package).
- **Validation.** After a file target's function returns, check that every path exists and error if not.

Done when: editing an input CSV rebuilds its consumers; touching it without changing bytes rebuilds nothing; deleting an output file rebuilds the target that wrote it.

## Phase 8: Dynamic and static branching

A branching target runs its function once per element of a pattern target, stores each result as its own branch, and on later runs rebuilds only the branches whose inputs changed.

```julia
target(:grid, () -> vec([(alpha = a, depth = d) for a in (0.1, 0.5), d in 2:4]))
target(:fits, (clean_data, grid) -> fit_model(clean_data, grid); pattern = :grid)
target(:summary, fits -> summarize(fits))   # receives a Vector of all branch values
```

The pattern argument (`grid`) is passed one element at a time; every other argument is passed whole to each branch. A non-branching consumer of `fits` receives a `Vector` of branch values in pattern order.

**Decision: branch identity comes from the element's hash, not its position.** Name each branch by the first 8 hex characters of the element's `canonical_hash`. Inserting, removing or reordering elements then leaves the other branches untouched. Disambiguate duplicate elements by appending an occurrence count to the hash input.

**Decision: v0.1.0 supports `AbstractVector` patterns and one pattern per target.** Error clearly otherwise. Cross products are built upstream, as `grid` is above.

**Branching over branches.** When the pattern target is itself a branching target, map 1:1 over its branches: `target(:preds, fits -> predict(fits); pattern = :fits)` creates one `preds` branch per `fits` branch, so a change to one grid element rebuilds exactly one chain of branches.

**Storage and staleness.**

- Each branch is stored and checked like a small target: its own object under `objects/fits/`, and a record under `meta/fits/<branch id>.toml` holding its dependency hashes, including the hash of its element.
- All branches share the parent's `command_hash` and `code_hash`, so a code change rebuilds every branch.
- The parent's metadata lists the branch ids in pattern order, and its `value_hash` is the hash of the ordered list of branch value hashes.
- At the end of a successful run, delete objects and records for branches no longer in the pattern.

**Implementation notes (M4).**

- Identity hashes of a pattern target's elements are stored in *its* record (`element_hashes`) when it is built, so an up-to-date run computes every branch id and staleness without loading the pattern value; it is loaded only when a branch has to be built. A pattern target built before it became one recomputes and keeps them. A *file* target can be a pattern (one branch per path, identity = path plus content hash), so editing one file rebuilds one branch.
- Branching over a branching target keeps the upstream branch's *id*, and uses the upstream branch's value hash as the dependency hash, so a change rebuilds exactly one chain and ids stay stable.
- Short ids extend (to 16 hex characters) only for elements whose 8-character ids collide.
- Reordering changes the pattern target's value and the aggregate's hash, but rebuilds no branch.
- Each branch is its own record, so one failing branch is retried on the next run while the others stay up to date; with `keep_going` the other branches are still built, and the target is reported as errored. `BuildSummary.branches` lists the branch ids built per target, and `tar_read(:fits)` returns all branch values in order. A target cannot be both a branching and a file target.

**Static branching (`tar_map`) needs no special support.** Generate targets with a comprehension; `tar_pipeline` flattens the vector (Phase 2), closure captures distinguish the generated targets (4.1), and explicit `deps` combines them (`tar_combine`, Phase 1).

**Decision: a small `tar_map` helper on top.** Comprehensions make the user build names and write `deps` between targets of one branch by hand, which is awkward when values have no natural name. `tar_map(template, values; names)` calls `template(value)`, suffixes each returned target's name, and renames `deps` and `pattern` that refer to targets of the same call (others are untouched). Default suffixes: keys of a `NamedTuple`/`AbstractDict`; else the value if it is a `Symbol`, string, integer or tuple of those (joined by `_`); else the position. `names` overrides with a collection or a function of the value; duplicate or invalid suffixes are errors that suggest `names`. It returns a `NamedTuple` of template name => generated targets, which `tar_pipeline` flattens. `tar_combine(name, f, targets...)` is `target` with `deps` taken from the given targets. No macro rewriting: closures carry the value, as with comprehensions.

**Decision: template names select whole groups.** Each generated `Target` records its template name (`group`); the `Pipeline` maps groups to their targets and rejects a group named like a target. Every pipeline `names` keyword resolves group names to their targets. `tar_invalidate` and `tar_delete` see only the store, so `tar_make` saves the groups in `store.toml` and they expand names from there (groups as of the last build). A generated name affects only its own arm: arms are independent targets, so the next build reruns just that arm and its descendants.

Done when: adding one element to the pattern builds exactly one new branch; editing one element rebuilds one branch chain; aggregate targets update when any branch changes; changing one value in a static-branching loop rebuilds only that target.

## Phase 9: Macro sugar

The macro layer is a pure front end: it rewrites expressions into Phase 1 `target()` calls and adds no new behavior.

```julia
p = @pipeline begin
    @target raw_file = "data/raw.csv"  format = :file
    @target clean_data = clean(CSV.read(raw_file, DataFrame))
    @target grid = make_grid()
    @target fits = fit_model(clean_data, grid)  pattern = grid
    @target summary = summarize(fits)
end
```

expands to `tar_pipeline(target(:raw_file, () -> "data/raw.csv"; format = :file), target(:clean_data, (raw_file,) -> clean(...)), ...)`.

**Decision: `@target` is only valid inside `@pipeline`.** `@pipeline` sees every target name in the block, so for each expression it collects the symbols that match those names and uses exactly those as the generated function's arguments. A bare `@target` errors with a message pointing to `@pipeline` or `target()`.

**Decision: macro targets hash their original expression.** The macro fills `Target.source` with the right-hand side, line numbers stripped, and `command_hash` uses it in place of source lookup (4.1). Recursive discovery (4.2) starts from this expression too.

**Hygiene and errors.** `esc` the generated expression so user functions resolve in the caller's module. Attach the call site's `__source__` line node to each generated function, so stack traces point at the right line of `_targets.jl`.

**Edge case to document:** a local variable that shadows a target name (a comprehension variable named `grid`) is treated as a dependency. This is harmless (one extra edge) and rare.

Done when: a macro pipeline and the equivalent `target()` pipeline produce the same graph and order; errors point to the right lines; editing one `@target` line rebuilds only that target and its descendants.

*Status (extended after v0.1.0): everything the function form expresses has a macro form, and three decisions above are superseded.*

- *`@target` is valid inside `@targets` blocks, which build a `Fragment` of declarations (`src/declarations.jl`); `@pipeline` is `tar_pipeline` of one. Names are resolved when `tar_pipeline` assembles the fragments, not by the macro, so fragments in different files (or returned by functions) refer to each other's targets.*
- *Free names come from ExpressionExplorer.jl (Pluto's scope analysis), run on the expression after expanding its macros in the caller's module and removing the `GlobalRef`s they generate. Locally bound names are never dependencies, which retires the shadowing edge case; every other free name is a target or else the value it has where the block was written (`@isdefined` in a closure, so function locals work too), and a name that is neither is an error naming the line. The generated function is a `MacroCommand` whose body takes all those names as arguments; its command hash covers what the body and scope closures capture, and code discovery follows the values taken from the scope.*
- *Static branching is `@map(values; names, prefix) do v ... end` (Julia requires the parentheses for `do`), nestable, with `tar_map`'s suffixes, order and groups; `prefix = true` puts the suffix first, so nested maps reproduce names such as `real_chain_1_seir`. Names resolve to the innermost declaration, and a template's name outside its map is a group, passed as a `NamedTuple` keyed by suffix. `@rep` covers `tar_rep` and, inside `@map`, `tar_map_rep`.*
- *A target's own name in its expression is not a dependency (`@target summary = summary(fit)`), and calling a function that shares a target's name is an error, since the name means the target.*

## Testing strategy

The package's promise is "rebuild exactly what changed", so most tests are scenario tests: build, edit something, rebuild, and assert the exact set of targets that ran.

**Decision: test items live next to the code.** Every unit test is a `@testitem` in the same `src/` file as the function it tests, run with `juliati` (`juliati --filter` for one item or file). Shared fixtures (creating a throwaway project, writing `_targets.jl` and source files, running a build) live in a `@testmodule` in `src/testing.jl`. Scenario tests sit next to `tar_make` in `src/make.jl`, branching scenarios in `src/branching.jl`, file-target scenarios next to file hashing. Aqua and JET items sit in `src/Targets.jl`. Test-only dependencies (Aqua, JET, Test) stay in `test/Project.toml`.

**Decision: make the project root and store path parameters.** Default the project root to the directory of the active `Project.toml`, but accept it as a keyword. Tests create a throwaway project with `mktempdir()` and run real builds without touching the package's own directory. This also makes the "user code" rule (4.2) testable.

**Assert on `tar_make()`'s summary.** It returns the names built, skipped and errored, so assertions like `@test built == [:clean_data, :model]` need no counters inside user functions.

Core scenarios, each a test item:

| Change | Expected rebuild |
| --- | --- |
| Nothing | Nothing |
| Edit a comment or whitespace in a used function | Nothing |
| Edit a helper two calls deep | Every target reaching it, plus affected descendants |
| Add a method to a used function | Its consumers |
| Edit a used `const` global or struct definition | Its consumers |
| Edit a function in a `track`ed external package | Its consumers |
| Edit a function no target reaches | Nothing |
| Edit one of two lambdas declared on separate lines of `tar_pipeline(...)` | That target only |
| Change a target's closure capture | That target and descendants |
| Edit code so the output is unchanged | That target only (early cutoff) |
| `force = true` with `names` | The named targets and all their ancestors |
| Edit an input file | Its file target and consumers |
| Touch an input file without changing bytes | Nothing |
| Delete an output file or an object | That target only, unless its value changed |
| Add one element to a branching pattern | One new branch and the aggregates |
| A target errors | Nothing downstream; previous object kept |

**Oracle test: equivalence with a clean build.** Generate random small DAGs with random integer-valued functions, apply random edits, and run incremental builds. After every step assert that `tar_outdated()` is empty and every stored value equals what a from-scratch build into a fresh store produces.

**Stability tests.** Compute source, canonical and value hashes in two separate Julia subprocesses and assert they match. In CI, store hashes from the LTS job as an artifact and compare them in the latest-release job, so a Julia upgrade that would cause spurious rebuilds is caught early.

**CI matrix.** Julia 1.10 (LTS) and the latest stable release, on Linux, macOS and Windows. `method_argnames`, the JuliaSyntax lambda locator and file-target path handling are the places most likely to break across versions and platforms.

## Milestones

Each milestone ends in something usable and a gate that must pass before the next starts. M1 hashes only each target's own source, so a working pipeline exists before recursive tracking is attempted.

| Milestone | Contents | Gate |
| --- | --- | --- |
| **M0: Clean slate** | Phase 0 | Aqua and JET test items pass on the skeleton |
| **M1: Working pipeline** | Phases 1–3; Phase 4.1 (canonical encoding, source location including the lambda locator and lowered fallback, closure captures); a minimal Phase 5 loop (`names`, `force`, logging, error handling) | Second run builds nothing; editing a target's own function rebuilds it and its descendants; `force` rebuilds the ancestor closure |
| **M2: Precise change detection** | Phase 4.2–4.5: recursive discovery of functions, types and globals, `track`, value hashing and early cutoff, stale-session guard, Manifest warning | Scenario table rows on code edits and early cutoff; oracle test; cross-process and cross-version hash stability |
| **M3: Usability** | Rest of Phase 5 (value cache, `keep_going`, `fresh`); Phase 6 helpers, `tar_dot` and `tar_visnetwork` with `names` | Each helper has a test item; bounded memory on a long chain; subgraph rendering |
| **M4: Files and branching** | Phases 7 and 8 | File and branching scenario rows |
| **M5: Sugar and release** | Phase 9; documentation; registry and name check | Macro and function pipelines produce identical graphs; docs build |

### Status

M0–M5 are implemented, each as its own revision with its tests green (`juliati`: 92 test items, including Aqua and JET). Deliberately left for later: the ready-queue/parallel scheduler (the loop is factored into `process!`/`build!`/`process_branching!` for it; see the v0.2.0 roadmap below), a Documenter site (the README and docstrings are the documentation for now), and renaming the package (see the registry check below).

## v0.2.0 roadmap

v0.1.0 covers change detection, the store, files, branching and the helpers. Compared with R's `targets` and `tarchetypes`, the remaining gaps are listed below in priority order, one phase each. Reports as targets are limited to rendering single Quarto documents (`tar_quarto`, Phase 18). As in v0.1.0, each phase starts with the structural change it needs (with the existing tests still green) before the behavioral one, and ends with scenario test items.

### Phase 10: Reproducible per-target RNG seeds

Each target, and each branch, runs with an RNG seeded from its own name, so its result does not depend on build order, subset builds or (later) scheduling across threads. This must land before parallelism: without it, the state of the task RNG a target inherits depends on which tasks were spawned before it, which is decided by the scheduler.

- **Seed derivation.** `target_seed(pipeline_seed, key) = first 8 bytes of canonical_hash((:seed, pipeline_seed, key))` as a `UInt64`, where `key` is `t.name` or `"name/id"` for a branch. Branch ids are hashes of the element, so a branch's seed is stable when the pattern is reordered or extended (Phase 8 identity carries over for free).
- **API.** `tar_pipeline(...; seed = 0)` sets the pipeline seed. `target(...; seed = :auto)` per target: `:auto` derives as above, an `Integer` pins it, `nothing` leaves the RNG alone (for targets that seed themselves). Add the stdlib `Random` as a dependency.
- **Applying it.** Run every user call inside its own task (`@task` plus `schedule`/`fetch` now, the job's task in Phase 11), and call `Random.seed!(seed)` first inside that task. The RNG is per *task*, not per thread, so this is correct however tasks move between threads, and seeding a child task leaves the caller's session RNG untouched (a test should check this). Tasks a target spawns itself get RNG states derived from its seeded task RNG, so a target that parallelises internally with `Threads.@spawn` is reproducible as long as it spawns its tasks in a deterministic structure (on Julia 1.10, the minimum version, spawning no longer advances the parent's RNG; add a test item that relies on this). Store the seed in the record (`seed` field) and expose `tar_seed()` so users can create their own stream, e.g. `StableRNG(tar_seed())`. Hold the current seed in a `ScopedValue` (ScopedValues.jl, which re-exports `Base.ScopedValues` on Julia 1.11 and later), not in `task_local_storage` or anything indexed by `threadid()`: scoped values are inherited by tasks the target spawns, task-local storage is not.
- **Staleness.** A different seed for a target is a new reason `:seed_changed`, checked after `:command_changed`. Changing the pipeline seed therefore rebuilds every `:auto` target.
- **Julia versions.** Julia does not guarantee the default RNG stream across releases. Do *not* rebuild on a Julia upgrade (consistent with 4.1); document this and recommend StableRNGs.jl with `tar_seed()` where bit-for-bit reproducibility across Julia versions matters.
- **Tests.** A random target returns the same value in a full build, a `names` subset build, a pipeline with targets reordered, and (after Phase 11) with `jobs > 1`; branches keep their values when the pattern is reordered; `rand()` in the session after `tar_make` is unaffected; changing `seed` rebuilds with `:seed_changed`.

*Status: implemented in `src/seeds.jl`. Decision: instead of a child task per call, `call_target` seeds the calling task's RNG and restores its saved state afterwards. That keeps the session RNG untouched, keeps the user's backtrace, and lets `deployment = :main` targets run in the caller's own task (Phase 11.3); each concurrent job already runs in its own task. `@pipeline seed = ...` and `@target ... seed = ...` are accepted too. Records written before this phase have no seed, so every seeded target rebuilds once (`:seed_changed`) after upgrading.*

### Phase 11: Ready-queue scheduler and concurrent builds

`tar_make(; jobs = n)` runs up to `n` independent targets and branches at once, as Julia tasks. Default `jobs = 1` keeps today's behavior. A target can claim several of the `n` slots, or all of them (`slots = :all`) so that nothing else runs while it does.

**Decision: tasks in one process first; worker processes are a second executor (Phase 12), not a replacement.** Both run completely independent targets at the same time; they differ in what they share.

| | Tasks in the `tar_make` process (Phase 11) | Worker processes (Phase 12) |
| --- | --- | --- |
| Start-up | None | Each worker starts Julia, loads packages and `_targets.jl`, and compiles the target code again |
| Passing values | Cached values are passed directly, in memory | Through the store on disk (a shared filesystem) |
| Memory | One copy of each upstream value | Each worker loads its own copy |
| Garbage collection | Shared: allocation-heavy targets pause each other, so they scale worse than compute-bound ones | Independent per process |
| Code that is unsafe to run concurrently, global state (`cd`, `ENV`, BLAS threads) | Shared; needs `deployment = :main` or care | Isolated per process |
| A crash (segfault, out of memory) | Ends the whole build | Loses one worker |
| Scale | One machine | Several machines (cluster managers) |

Tasks are the right default on a laptop or a single node, and cheapest for many small branches. Workers are worth their start-up cost for long targets that allocate heavily, use libraries that are unsafe to run concurrently, risk crashing, or need more than one machine. Both executors use the same `Job`/`JobResult` protocol and the same slot accounting (11.3), so a pipeline needs no changes to switch between them, and a worker process can itself use threads inside its targets.

**Decision: the package parallelises across targets and branches; parallelism within a target belongs to the target's own code.** Only `tar_make` owns the loop over targets and over the branches of a branching target (`process_branching!`), so only the package can run independent targets or branches concurrently. For simulation sweeps written as dynamic branches, that is where most of the speed-up is. A single large computation (one model fit) should parallelise itself with `Threads.@spawn`, OhMyThreads.jl or threaded BLAS. Both levels compose, because they share Julia's task scheduler: a target spawning tasks while `tar_make` runs other targets neither deadlocks nor serialises. The same job/result split is also what Phase 12 needs for distributed workers, which target code cannot easily set up itself.

**Decision: reason about tasks, never about threads** (per the Julia blog post ["PSA: Thread-local state is no longer recommended"](https://julialang.org/blog/2023/07/PSA-dont-use-threadid/)). Tasks can migrate between threads and yield at any call (logging, I/O, compilation), and the number of threads can change at run time (interactive threadpool, adopted threads), so:

- No code in the package uses `threadid()`, `nthreads()` or `maxthreadid()` for correctness, and no state is indexed by thread. `nthreads` may only inform a heuristic (`jobs = :auto` uses `Threads.nthreads(:default)`).
- No `@threads`, in particular never `@threads :static`, which is neither composable nor nestable. Each job is a task created with `Threads.@spawn`.
- Each job's task creates and returns its own result. Spawned tasks never write to shared state; the scheduler task alone owns `BuildContext`.
- Per-job context (seed, warning logger, current key) travels with the task: `ScopedValue`s and `Logging.with_logger`, both inherited by tasks the target spawns itself.
- Concurrency bugs do not need several threads: a task that yields mid-update races with one thread too. Run the concurrency tests with one thread as well as several.

**Decision: no BorrowChecker.jl, for now.** BorrowChecker.jl's `@safe` checks aliasing and escapes *within* an annotated function from its typed IR, at run time. It needs Julia 1.12 or later (this package supports 1.10), is experimental with expected false positives, and does not see races between tasks as such. The design above prevents races structurally instead: shared mutable state lives only in the scheduler task, and tasks exchange immutable `Job`s and `JobResult`s through one `Channel`. The remaining hazard, user targets mutating shared inputs, is in user code that Targets cannot annotate, and `check_mutation` covers it directly. Reconsider as an optional, non-gating test item on Julia 1.12 or later (wrapping `execute` and the commit functions in `@safe` with `scope = :module`) once BorrowChecker.jl stabilises.

**11.1 Structural: the ready queue, one job at a time.** Replace the `for name in selected` loop in `tar_make` with the scheduler described in Phase 5: count unfinished selected dependencies per target, keep a ready set ordered by declaration index, and on completion decrement dependents. With `jobs = 1` the order must equal `p.order` exactly; assert that in a test item and rerun the oracle test. No behavior change.

*Status: implemented as `ReadyQueue` in `src/scheduler.jl`; `tar_make` drains it.*

**11.2 Structural: split each build into plan, execute and commit.** Today `process!`/`build!`/`process_branching!` mix decisions, user calls and mutation of `BuildContext` (`values`, `value_hashes`, `remaining`, `summary`, `commands`, `codes`, the `Discovery` memo, `log!`). None of these may be touched from several tasks at once. Split them so that:

- **Plan (scheduler task only):** blocked check, `command_for!`, `code_for!`, `outdated_reason`, and branch enumeration. Code discovery and hashing stay single-threaded and memoized, and need no locks.
- **Execute (a function of its job only):** `execute(job::Job)::JobResult` receives an immutable `Job` (target, key, resolved arguments or store keys to load, seed, element) and *returns* a `JobResult` (value, value hash, extra record fields, seconds, or the exception and backtrace). It catches every exception except `InterruptException` and returns it inside the result, so a job's task never dies silently. It loads missing argument values read-only from the store, calls `invokelatest(t.f, args...)` with the seed and logger scoped to the call, and writes the object (`atomic_write` already uses unique temporary names, and keys never collide). It touches no `BuildContext`.
- **Commit (scheduler task only):** `write_meta` (still the commit marker), cache the value if `remaining > 0`, update `value_hashes`, the summary and the log, then `release!` and push newly ready targets.

With `jobs = 1`, execute runs inline in the scheduler task; the logs and summaries must be byte-identical to today's.

*Status: implemented. `plan!`/`plan_branching!` (make.jl, branching.jl) return `Job`s, `execute` and `persist_value` live in `src/jobs.jl`, and `commit!`/`commit_branch!`/`finish_branching!` record outcomes; a branching target's progress is a `BranchProgress` in `BuildContext.branching`. Decision: arguments are resolved from the value cache (loading on a miss) during planning, not inside `execute`, so the cache is still filled and released by the scheduler task alone; a load failure is carried in the job (`load_error`) and reported as that target's error.*

**11.3 Behavioral: concurrent jobs.** No fixed pool of worker tasks. The scheduler loop is:

```julia
results = Channel{JobResult}(Inf)
used = 0                                             # slots taken by running jobs
while !isempty(ready) || used > 0
    while (job = peek_job(ready)) !== nothing && used + job.slots <= jobs
        pop_job!(ready)
        used += job.slots
        Threads.@spawn put!(results, execute(job))   # the task returns its own result
    end
    result = take!(results)
    used -= result.slots
    commit!(ctx, result)                             # scheduler task only
end
```

The `Channel` is the only object shared between tasks, and it is thread-safe; `used`, `ready` and the whole `BuildContext` are local to the scheduler task. `execute` returning a `JobResult` for every outcome is what keeps `take!` from waiting forever. `jobs` counts tasks, not threads: `jobs = 4` with one thread still overlaps I/O-bound targets, and `jobs` larger than the number of threads is allowed.

- **Slots and exclusive targets.** `target(...; slots = 1)` is the share of the `jobs` capacity a target occupies while it runs: an `Integer` (clamped to `jobs`), or `:all`, which equals `jobs`. A job starts only when its slots are free, so a `slots = :all` target waits for the running jobs to finish and nothing else starts until it is done: use it for a target that parallelises internally and should have the machine to itself. When nothing is running, any job fits, so the loop cannot deadlock.
  - **No overtaking.** Ready jobs are taken strictly in priority order: when the next job does not fit, the scheduler waits for running jobs to finish instead of starting smaller jobs behind it. Otherwise a stream of small branches could delay an exclusive target indefinitely. This leaves slots idle while draining, which is the price of the guarantee.
  - **`tar_slots()`** returns the slots granted to the running target (a `ScopedValue`, like `tar_seed()`), so target code can size its own parallelism, e.g. `OhMyThreads.tmap(f, xs; ntasks = tar_slots())`.
  - **Admission, not enforcement.** Julia cannot confine a task to a number of threads: a `slots = 1` target that spawns many tasks still uses every thread. Slots only control what `tar_make` starts alongside it; document this.
  - **Branches.** Slots apply to each branch job, so `slots = :all` on a branching target runs its branches one at a time, each with the machine to itself.
  - Slots are independent of `deployment = :main`, and recorded in `tar_manifest()`.
- **Branches are jobs.** Most of the available parallelism is in branching targets, so each outdated branch is its own job; the parent's aggregate record is committed when its last branch job finishes (the bookkeeping now in `process_branching!` moves into a per-target pending-branch counter).
- **`deployment = :main` per target** runs that target inline in the scheduler task (the task that called `tar_make`), so it never runs at the same time as another `:main` target. Default `:spawn`. This is for code that is not safe to run concurrently with itself. It is *not* a promise of a particular thread: libraries that need thread 1 (PythonCall, some GUI backends) are satisfied only when `tar_make` itself is called from thread 1; document this rather than pinning by `threadid()`. Code that is unsafe alongside *any* concurrent use of a library needs every target using that library marked `:main`.
- **Errors.** Without `keep_going`, stop dispatching new jobs after the first failure, wait for running jobs and commit their results (finished work is never thrown away), then rethrow. With `keep_going`, block descendants as today. On `InterruptException`, stop dispatching and commit nothing further; running tasks cannot be killed, so wait for them (with a second Ctrl-C abandoning them uncommitted). Document this.
- **Ordering.** Logs follow completion order; sort the `BuildSummary` vectors into build order before returning so tests and output stay deterministic.
- **Priorities.** Among ready jobs, prefer those on the longest remaining path, weighted by each target's last recorded `seconds` (the critical path). With no timings, fall back to declaration order.
- **Process-global state.** The working directory (`cd(rootdir)`) and `ENV` are shared by all tasks: document that target code must not `cd` or change `ENV`. Call `Revise.revise()` once before planning, never during the run.
- **Shared input values.** Concurrent consumers of one upstream receive the *same* cached object. A target that mutates its input in place races with the others, and corrupts the cache for later consumers even with `jobs = 1` (the value no longer matches its recorded hash). Document that target functions must not mutate their arguments. Add an opt-in `tar_make(; check_mutation = true)` that records `canonical_hash` of each in-memory argument before the call and errors, naming the target and argument, if it differs afterwards. It is costly, so off by default and recommended in tests and CI.
- **Oversubscription.** Julia threads compose, but BLAS threads are a separate pool: with `jobs > 1` and BLAS-heavy targets, recommend `BLAS.set_num_threads(1)` in the docs. Do not change it automatically (it is global state).
- **Memory.** Concurrent builds hold more values at once; `jobs` is the knob. Values still leave the cache when their last consumer commits.
- **Tests.**
  - Concurrency without timing flakiness: two independent targets that each wait on a shared `Base.Event` for the other (with a timeout) can only both finish when run concurrently. This works with one thread, since waiting yields.
  - The oracle test with `jobs = 4`, run both with `JULIA_NUM_THREADS=1` and `=4` in CI.
  - Phase 10 seed tests with `jobs > 1`, including a target that spawns its own tasks.
  - `deployment = :main` runs in the caller's `current_task()`, and two `:main` targets never overlap (each records entry and exit in a log owned by the test).
  - A failure lets running jobs commit; an exception inside `execute` cannot hang the scheduler.
  - `check_mutation = true` catches a target that `push!`es onto its input.
  - Slots: with `jobs = 4`, a `slots = :all` target never overlaps another job (entry and exit logs), starts only after the jobs running before it finish, and is not overtaken by smaller ready branches; `tar_slots()` returns 4 inside it and 1 in a default target; a `slots = 2` target overlaps at most two single-slot targets.
  - A guard test item that `src/` contains no `threadid(` or `@threads`.

*Status: implemented in `src/dispatch.jl` (`run_jobs!`, `tar_slots`), with priorities from `critical_path` in `src/scheduler.jl`; `slots`/`deployment` are `target` options. Notes from implementation: a ready target is planned only when no planned job is waiting for slots, so with `jobs = 1` planning, execution and logs interleave exactly as before; priorities are used only when `jobs > 1` (with `jobs = 1` the order stays `p.order`); a branching target's own record has no `seconds`, so it gets no critical-path weight; `fresh = true` forwards `jobs` and starts the subprocess with the session's default thread count. `check_mutation` is implemented as a `ScopedValue` read by `execute`, so spawned jobs see it too. The default `jobs` is the `jobs` preference of Targets (`LocalPreferences.toml`, a positive integer or `"auto"`), else `1`.*

### Phase 12: Distributed and HPC workers

Once Phase 11 has a job/result protocol, add a second executor that sends jobs to `Distributed` worker processes, including ones started by ClusterManagers.jl or SlurmClusterManager.jl.

- **Executor interface.** `tar_make(; executor = TaskExecutor(n))` with `submit!(exec, job)` and `take_result!(exec)`, generalising the `Threads.@spawn`/`Channel` loop of 11.3; `jobs = n` stays as shorthand for `TaskExecutor(n)`. `DistributedExecutor(pids)` lives in a package extension on `Distributed`.
- **Do not ship functions.** Closures and anonymous functions do not serialize reliably between processes. Each worker loads `_targets.jl` once with `load_pipeline` and looks targets up by name; a job carries only the key, element index, seed and argument store keys. On start-up, each worker reports the command and code hashes of its pipeline, and the run aborts if they differ from the main process's (a worker running other code would record wrong hashes).
- **Data through the store.** Workers read dependencies from the store and write their own objects; only value hashes and record fields go back to the main process, which alone writes metadata. This requires the project root and store on a shared filesystem; check it at start-up by having each worker read a token file the main process wrote.
- **Slots across workers.** A `DistributedExecutor` has one slot per worker process by default (`slots_per_worker` to change it), and the 11.3 accounting is unchanged: `slots = :all` drains every worker and runs the target alone on one of them, where it can use that worker's threads.
- **Pools.** For clusters where draining everything is wasteful, `pool = :bigmem` per target sends it to a named executor (`executor = Dict(:default => ..., :bigmem => ...)`), and slots are counted per pool, so a heavy target can have a dedicated pool while other targets keep running on the default one. One cluster job per target is out of scope.
- **Fresh builds.** `fresh = true` makes the subprocess the main process; workers attach to it.

*Status: the executor interface is implemented in `src/executors.jl` (`Executor`, `TaskExecutor`, `capacity`/`submit!`/`take_result!`/`start!`/`stop!`); `run_jobs!` takes an executor.*

*Status (`DistributedExecutor`): implemented, with the type in the core and its behaviour in `ext/TargetsDistributedExt.jl`. Workers load the script once (`worker_pipeline`), and start-up checks the shared filesystem (a token file) and that every target's command and code hashes match the main process's. Workers write objects to the store and send back only a `RemoteResult`; consumers then load the value from the store (`Unloaded`). Deviations: (1) arguments go to the worker with the job (Distributed serialization) instead of being read from the store, which avoids describing every argument as a store reference but costs a copy per job; (2) a failure on a worker reaches the main process as a `RemoteTargetError` message, so its traceback and workspace backtrace are not kept; (3) not done: `pool`/named executors and workers attaching to a `fresh = true` subprocess. Slots: a job goes to the worker with the most free slots and is granted at most `slots_per_worker`, so a `slots = :all` target drains every worker and runs alone on one. Tested with two local `addprocs` workers.*
- **Tests.** `addprocs(2)` locally: same results and records as a task-based build; a worker whose pipeline differs is rejected; Phase 10 seeds agree across executors.

### Phase 13: Pluggable storage formats

Let a target choose how its value is stored: Arrow or Parquet for large tables (fast, memory-mappable, readable from other languages), Serialization for speed, and user-defined formats.

**13.1 Structural: a format interface.** `t.format == :file` checks are spread over `make.jl`, `outdated.jl`, `store.jl` and `api.jl`, and `write_object`/`read_object` hard-code JLD2. Introduce a dispatch layer, with `:jld2` as its first and only implementation and no behavior change:

```julia
abstract type StorageFormat end
storage_format(::Val{:jld2}) = JLD2Format()
extension(::JLD2Format) = "jld2"
write_value(::JLD2Format, path, value) = JLD2.jldsave(path; value)
read_value(::JLD2Format, path) = JLD2.load(path, "value")
```

`:file` stays a separate target *kind* (it stores paths, not objects), not a `StorageFormat`; `value_kind` already makes that distinction. `object_path` takes the extension from the format, and reading uses the format **recorded** in the target's metadata, so `tar_read` works after the declaration changed. The `FORMATS` check becomes "`storage_format(Val(f))` has a method", with an error listing the formats currently available and naming the package to load ("`format = :arrow` needs `using Arrow`").

*Status: implemented in `src/formats.jl`. Objects are located by key whatever their extension (`object_files`/`find_object`), so `has_object`, `delete_object`, pruning and `tar_prune` need no format; writing an object removes the key's objects in other formats. Without a record (after `tar_invalidate`) the reader is chosen by file extension.*

**13.2 Behavioral: formats.**

- `:jls` (Serialization, core): the fastest for arbitrary Julia values, but tied to the Julia version. On a failed load during `tar_make`, treat the target as `:missing` and rebuild instead of erroring; `tar_read` errors with that explanation.
- `:arrow` (extension on Arrow.jl): any Tables.jl table. Reading returns a memory-mapped `Arrow.Table`; document `DataFrame(tar_read(:x))` / `copy`.
- `:parquet` (extension on Parquet2.jl), `:csv` (extension on CSV.jl, reading returns `CSV.File`; mainly for interchange, recommend Arrow for speed).
- **Options** (compression and so on): `format` also accepts a `StorageFormat` value, e.g. `format = ArrowFormat(compress = :zstd)`. The canonical encoding of the format goes into the record, and a change is a new reason `:format_changed`.
- **User formats** are public API: define a `StorageFormat` subtype and the four methods.
- **Branches** are stored in their target's format.
- **Value hashing.** The default hashes the written file (4.3). Add byte-stability test items per format; if a writer embeds timestamps or random ids (Parquet metadata is a candidate), give that format a `format_value_hash(fmt, path, value)` method that hashes the table contents instead.
- **Store version.** Object paths gain per-format extensions; bump the `store.toml` format version. Existing `.jld2` paths are unchanged, so the migration only rewrites the version.

*Status (13.2, part 1): `:jls`, `StorageFormat` values as `format`, and `:format_changed` are implemented. Decisions: the format left the command hash (it now only distinguishes file targets from object targets, hashed as before so existing stores do not rebuild), and `:format_changed` is checked right after `:seed_changed`; records without a `format_hash` compare by format name. For `:jls`, instead of attempting a load, an object written by another Julia version counts as `:missing` (checked from the record's `julia_version`), which avoids loading every object on a no-op run. The store version was not bumped: objects are located by key whatever their extension, so old stores read unchanged.*

*Status (13.2, part 2): `:arrow` (`ArrowFormat(; compress)`), `:parquet` (`ParquetFormat()`) and `:csv` (`CSVFormat(; delim)`) are implemented as extensions on Arrow, Parquet2 and CSV. The format types live in the core so they can be constructed before the package is loaded; using one without its package errors with "needs `using X`". All three wrote identical bytes for identical tables in the stability test, so no `format_value_hash` was needed. CSV reads detect the delimiter, since the record keeps only the format name and a hash of its options.*

**13.3 Behavioral: URL targets.** `format = :url`: the function returns one or more URLs, and the value hash comes from an HTTP `HEAD` request (ETag, else Last-Modified plus Content-Length) using the stdlib Downloads. Like file targets, they are re-checked on every run and consumers receive the URL. When offline, keep the recorded hash and warn instead of failing the run.

*Status (13.3): implemented in `src/urls.jl`. URL targets reuse the file-target record fields (`files` holds the URLs, `file_hashes` the per-URL `HEAD` hashes), and the staleness reason for a changed resource is `:url_changed`. Consumers rebuild when a resource changes, since the URL target's value hash is built from those hashes. A URL that cannot be reached during the build that creates it fails the target; afterwards it keeps its recorded hash, with a warning. Tests use a local HTTP.jl (v2) server.*

- **Tests.** Round-trip and byte-stability per format; changing the format rebuilds with `:format_changed` and `tar_read` reads the new format; a missing extension gives the "load X" error; `tar_read` reads the recorded format after `_targets.jl` changed; `:url` against a local `HTTP.jl` server (test-only dependency).

### Phase 14: Richer branching patterns

`pattern` accepts one symbol, and branching over a branching target is strictly 1:1. Add R's pattern combinators, grouped iteration and batched replication.

**14.1 Pattern combinators.** Patterns become a small nestable type: `pattern = :grid` stays, plus `Map(:a, :b)` (elementwise, equal lengths required), `Cross(:a, :b)` (all combinations), `Head(:a, n)`, `Slice(:a, idx)` and `Sample(:a, n)`, nestable as in `Cross(:a, Map(:b, :c))`. Inside `@target`, accept R's syntax `pattern = map(a, b)` / `cross(a, b)` and rewrite it to these types.

- **Identity.** A branch's identity is the combined hash of its components' identity hashes in pattern argument order, so branches stay stable when any input is extended or reordered. `Head`/`Slice` select from the component's identity list; `Sample` draws with the Phase 10 seed, so the same branches are selected on every run.
- **Arguments.** Each pattern dependency receives its own element; other dependencies are passed whole, as today.
- **Over branching targets.** `Map` over branching targets pairs branches by position; `Cross` takes all combinations of branches. Extend `pattern_elements`/`branch_dep_hashes` so the dependency hash of each component is its upstream branch's value hash, as for 1:1 today.
- **Validation** (in `tar_pipeline`): every name in a pattern is a dependency of the target; `Map` lengths are checked at build time with a clear error.
- **Tests.** Adding one element to one side of a `Cross` builds exactly the new combinations; `Head(:grid, 2)` builds two branches; `Sample` picks the same branches across runs; macro and function forms produce identical pipelines.

*Status (14.1): implemented in `src/patterns.jl` (`Map`, `Cross`, `Head`, `Slice`, `Sample`, `select_combinations`, `Branch`/`Pick`), with R-style `map(...)`/`cross(...)`/`head(...)` accepted by `@target`. A branch drawn from a single element keeps that element's id and hash, so existing single-symbol stores and 1:1 chains are unchanged. A Map length mismatch is raised while the branching target is planned, so it stops the build even with `keep_going`. A dependency that appears more than once in a pattern (`Cross(:a, :a)`) receives a tuple of its elements.*

**14.2 Grouped iteration.** Branch over groups of a table without the user building a vector first. Add a hook `Targets.branch_elements(x)` (default: `x` itself for an `AbstractVector`, error otherwise), and a DataFrames extension mapping a `GroupedDataFrame` to its groups. Identity of a group: its group key plus a content hash of the group's columns, rather than the Serialization fallback of `canonical_hash`. Settle in implementation whether branches receive a `SubDataFrame` or a copy (a copy is safer for storage).

*Status: implemented. Hooks: `Targets.branch_elements(x)` and `Targets.element_hashes(x)`; the `TargetsDataFramesExt` extension gives each branch a `DataFrame` copy of its group, identified by the group key plus a canonical hash of its columns.*

**14.3 Batched replication (`tar_rep`, `tar_map_rep`).** Thousands of tiny branches cost a TOML record, an object file and hashing each. `tar_rep(name, f; batches, reps)` creates a branching target over `1:batches` whose branch runs `f()` `reps` times, seeding each rep from the Phase 10 seed plus the rep index, and returns the vector of reps; consumers receive all reps concatenated. `tar_map_rep` combines this with `tar_map`. Before building it, benchmark the per-branch overhead of a 10 000-branch target; if metadata writes dominate, batching the branch records of one target into a single file is the alternative fix.

*Status: implemented in `src/replicate.jl`. Benchmark (2000 branches, one thread): a full build took about 2.5 ms per branch (JLD2 object writes about 0.5 ms, TOML records about 0.15 ms, the rest scheduling, logging and hashing), and an up-to-date run about 0.5 ms per branch. Record writes do not dominate, so batching reps is the fix. `tar_rep(name, f; batches, reps)` returns three targets: `name_batch` (`1:batches`), `name_batches` (branching, one vector of reps per batch) and `name`, which concatenates them for consumers. That costs one extra copy of the results; a target-level "concatenate branches" option could remove it later. Each rep is seeded from the branch seed plus its index. `tar_map_rep(name, f, values; ...)` passes each value as `f`'s first argument, and the value is captured in the command hash.*

### Phase 15: Error modes, retries and debugging failed targets

**15.1 Per-target error modes.** `target(...; error = :stop)`, one of:

- `:stop` (default): today's behavior, governed by `keep_going`.
- `:continue`: this target's failure never stops the run; its descendants are blocked. `keep_going = true` is equivalent to `:continue` for every target.
- `:null`: consumers receive `nothing` and still run. The target stays `:errored`, so it is retried next run, and the summary reports it.
- `:trim` (branching targets): failed branches are left out of the aggregate value, and the parent is committed with the surviving branches; their ids are listed in the summary and the record (`trimmed`). The parent stays outdated until no branch fails.

*Status (15.1): implemented (`error` option on `target`; `stops_build`/`null_value!` in make.jl; trimming in `finish_branching!`). A `:null` target's consumers see a fixed placeholder value hash, so they rebuild once it succeeds. A trimmed target's record lists `trimmed` ids and carries an error message, which keeps it `:errored` (and thus retried) until no branch fails; `BuildSummary.trimmed` lists the ids, and the target itself counts as built.*

**15.2 Retries.** `retries = 0` and `retry_delay = 0` per target, for flaky I/O and cluster nodes. Each attempt is logged, only the last error is recorded, `InterruptException` is never retried, and each attempt uses the same seed (so retrying a deterministic failure is pointless; document this).

*Status (15.2): implemented. `execute` retries inside the job, so a retry holds its slots and never re-enters the scheduler; failed attempts travel in `JobResult.retried` and are logged at commit (`↻ key attempt n failed, retrying: ...`). An argument-loading error is never retried.*

**15.3 Workspaces.** When a target or branch fails, save what is needed to reproduce the call to `_targets/workspaces/<key>.jld2`: the argument values that were in memory or are not otherwise stored (the branch element, and upstream values from targets whose objects may be rebuilt later; copies by default, `workspace = :refs` records store keys and value hashes only), plus the seed, error and backtrace. Delete the workspace when the target next builds successfully.

- `tar_workspace(:name)` returns the arguments as a `NamedTuple`; `@tar_workspace name` assigns them to same-named variables in the caller's scope, like `@tar_load`.
- `tar_rerun(:name)` calls the target's current function on the saved arguments with its seed, in the session, so the error can be inspected with Infiltrator.jl or Debugger.jl.
- Values the workspace cannot save are listed in it rather than failing the save.

*Status (15.3): implemented in `src/errors.jl`: `tar_workspace`, `@tar_workspace` and `tar_rerun`. A workspace is saved when a failure is committed and deleted when that key next builds. Not done: `workspace = :refs`; arguments are always copied, and those JLD2 cannot save are listed under `unsaved` and passed as `nothing`. `@tar_workspace` assigns globals in the calling module, since the names are only known at run time.*

**15.4 Tracebacks and warnings.** `record_failure!` keeps only the first 2000 characters of the message. Also store a `traceback` field: the stack frames up to the `invokelatest` call, so Targets' own frames are left out. Add `tar_errored()` (name, error, built_at) and `tar_traceback(:name)`. Capture `@warn` log records emitted during a target with a wrapping logger (`Logging.with_logger` is scoped to the task and inherited by tasks it spawns, so it works per job) and store them in a `warnings` record field; the summary line counts targets with warnings.

*Status (15.4): implemented in `src/errors.jl`. The `traceback` is the frames inside `call_target` (the user's function and everything it called, Base frames included), and `warnings` holds `@warn`/`@error` messages, captured by a `WarningCollector` logger that also passes every record on. `tar_errored()` and `tar_traceback(key)` read them, and the summary line adds ", N with warnings" only when there are some, so earlier logs are unchanged.*

- **Tests.** Each error mode against a three-target chain and a branching target; a target failing twice then succeeding with `retries = 2`; `tar_rerun` reproduces the exception; the workspace is deleted after a successful rebuild; the traceback contains the user function's frame and no `Targets.build!` frame.

### Phase 16: More cues

`cue` is `:thorough | :always | :never`. Allow a cue *value* as well:

- `cue = cue_age(Day(7))`: outdated with reason `:expired` when the record's `built_at` is older than the given period (for scraped or remote data). Checked after `:errored`. The clock is a parameter of `outdated_reason` so tests can inject time.
- `cue = cue_force(condition)`: `condition` is a `Bool` evaluated when the pipeline is loaded; `true` gives reason `:condition`.
- `Cue(; command = true, code = true, depend = true, file = true)` turns individual staleness rules off, for example `code = false` so an expensive simulation is not rebuilt after a refactor. Disabled rules are shown in `tar_manifest()` so their effect is visible.

`tar_outdated` uses the same rules. Tests cover each reason and the injected clock.

*Status: implemented in `src/cues.jl` (`cue_age`, `cue_force`, `Cue`), with the checks in `outdated_reason` (`now` keyword for the clock). `:condition` comes right after `:always`. `Cue(command = false)` also ignores seed changes, since a seed belongs to the command. Format changes are always checked. `tar_manifest` shows the cue value as it is, disabled rules included.*

### Phase 17: Progress monitoring

With parallel and distributed builds, `progress.log` alone is not enough to see what is running.

- **Events.** Each run appends machine-readable events (`run_id`, timestamp, key, `queued | started | built | skipped | errored | blocked`, seconds, worker) to `_targets/log/events.tsv`. The human-readable `progress.log` stays. The events file is written by the main process only, so no locking is needed.
- **Queries.** `tar_progress()` reads the latest run as a table of key, status and seconds; `tar_poll(; interval = 2)` refreshes a summary in the terminal from another Julia session while a build runs (it works across processes because it only reads files); an ETA from previous `seconds` records.
- **Graph.** `tar_dot`/`tar_visnetwork` gain a `running` status colour, taken from the latest run's events.
- **Tests.** The events of a run with one failure and `keep_going`; `tar_progress` during a run (from the `observe` hook already passed to `tar_make`).

*Status: implemented in `src/progress.jl`. Besides the per-key statuses, a run writes `run_started` and `run_finished` events with an empty key; `run_finished` is also written when the run fails, so `tar_poll` knows when to stop. Branch keys (`name/id`) get their own events. The `worker` column is `local` until Phase 12.*

**Decision: a live footer in the terminal.** `tar_make` reports through a `BuildDisplay` (`src/display.jl`), which the scheduler tells when jobs are queued, start and finish. With `progress = :live` (picked by the default `:auto` when `io` is a terminal) a `LiveDisplay` keeps a footer under the log: a spinner line per running job with its reason and time so far, and a count of targets done, running and queued. A ticker task on the interactive threadpool redraws it every 0.1 s; log lines are printed above it in the same write, under one lock. A finished job then appears once, as `✔ name 1.2s (reason)` (green, via StyledStrings) or `✖ name: error` (red), without its `▶` line, which `progress = :lines` (and `progress.log`) keep. Messages to a `ConsoleLogger` are formatted as it would and printed above the footer; direct writes to `stdout` from targets are not intercepted, since redirecting `stdout` affects the whole process.

### Phase 18: Quarto reports

`tar_quarto(:report, "reports/report.qmd")` renders one Quarto document with the `quarto` CLI as a file target, rebuilt when the document, a file it includes, an output file, or a target it reads changes. Quarto projects (a directory with `_quarto.yml`), other notebook formats (`.ipynb`, percent scripts) and rendering one document several times with different parameters (R's `tar_quarto_rep`) are out of scope.

**Decision: a report is one file target that tracks its sources by content.** The render function returns the output files followed by the source files (the `.qmd`, the documents it includes with `{{< include >}}`, the Julia files its code includes, and `extra_files`), so the existing file-target rules apply: editing prose or a chunk is `:file_changed`, touching a file changes nothing, and a deleted or edited output rebuilds the report. Modification times are not compared with the last build: they change on checkout and on saving without edits. The sources are hashed before rendering and again after it; if they differ the render fails, so an edit made while Quarto runs is not recorded against older output.

**Decision: dependencies are found statically, in Julia.** When the pipeline is built, the document and its includes are read, and the executable Julia cells (```` ```{julia} ```` blocks and inline `` `{julia} ...` `` code, except cells with `#| eval: false`) are parsed with JuliaSyntax. Julia files that this code loads with `include("file.jl")`, `Base.include(mod, "file.jl")`, `includet("file.jl")` or `include(joinpath(@__DIR__, "file.jl"))` are followed recursively (relative to the including file), parsed whole and tracked as sources; an include whose path is not a literal gives a warning that points to `extra_files`. Calls `tar_read(:name, ...)` and `@tar_load a b` (qualified or not, options skipped) name the dependencies; a name that is not a literal gives a warning that points to `deps`, which adds dependencies by hand. No Quarto call is needed to build the pipeline, so `tar_outdated` and `tar_visnetwork` work without Quarto installed. Paths given to `tar_quarto` are relative to the directory of the script being loaded (`_targets.jl`), or the project root outside a script.

**Decision: report targets do not receive upstream values.** The notebook reads the store itself, so the build loop skips loading values for a target whose function says so (`passes_values(f) = false`); such targets also do not hold upstream values in the in-memory cache.

**Decision: the notebook finds the store in this order.** Inside a Quarto notebook, `tar_read` and `@tar_load` without `store` use, in order: (1) the store of the `tar_make` that is rendering the document, passed as Quarto metadata (`-M targets-store:<absolute path>`); (2) a `targets-store:` key in the document's front matter, relative to the document's directory; (3) the `store` preference of Targets (`LocalPreferences.toml`, relative to the project root), which is also the default store everywhere else; (4) `_targets` in the project root. The metadata is read through the Julia engine's `QuartoNotebookWorker.notebook_options()`. During a render started by `tar_make` the `on_outdated` check is skipped, since the build has just made the values it reads current. Only Quarto's `julia` engine (QuartoNotebookRunner) is supported for (1) and (2); with the Jupyter engine, pass `store` or use the preference.

**Rendering.** `run` the `quarto` CLI (`quarto = "quarto"` keyword, checked with `Sys.which`) from the project root with `Cmd(...; dir)`, never `cd` (concurrent jobs share the working directory), passing `--execute-daemon-restart` (Quarto keeps a notebook's Julia worker alive between renders, so edited user code would otherwise stay loaded; `restart = false` opts out), `--cache-refresh` (the engine's cache ignores data changes) and `quarto_args`. Output files are `output` when given, else the document's stem with the extension of each format listed in its front matter (`html` by default), plus the `<stem>_files` directory when it exists. A failed render's error includes the end of Quarto's output. The command hash uses a fixed `source` expression plus the report's options, so upgrading Targets does not rebuild reports.

**Parameters.** `params = (alpha = 0.1, draft = true)` adds `-P alpha:0.1 -P draft:true` (numbers, booleans, strings and symbols only); a change rebuilds the report. Two report targets may not render the same document, because they would share output files and Quarto's per-document worker.

**Macro.** `@quarto report = "reports/report.qmd" [options]` inside `@pipeline`, or `@quarto "reports/report.qmd"` to take the name from the file's stem. Inferring reports from a `.qmd` string in `@target` was rejected: that line already means a constant string target, and the inference would only work for literal paths.

**Known limits.** Code the report loads from packages is not tracked (only the text of its chunks and included files is); rendering by hand rewrites the outputs, so the next build renders again.

- **Tests.** With a fake renderer (a `render` keyword): editing prose rebuilds only the report; touching it rebuilds nothing; changing a target the report reads rebuilds it, and one it does not read leaves it alone; adding a `tar_read` changes its dependencies; editing an included file or deleting the output rebuilds it; `eval: false` cells are ignored; upstream values are not loaded; the store passed to the renderer is the build's. Unit tests for cell extraction, dependency detection, store resolution and `@quarto`. One real render, skipped when Quarto is not installed.

*Status: implemented in `src/quarto.jl` (`tar_quarto`, `QuartoReport`, the notebook store lookup), `src/macros.jl` (`@quarto`) and `src/store.jl` (the `store` preference); `passes_values` lives in `src/make.jl`, and jobs expose their store and root to target functions as `RUNNING_PLACE`. Not yet checked against a real Quarto install: that `-M targets-store:...` reaches `QuartoNotebookWorker.notebook_options()` in the notebook, and that `--execute-daemon-restart` and `--cache-refresh` are accepted by `quarto render`.*

### Picking targets at the REPL

`tar_picker()` lists the pipeline's targets (in `tar_list` order) in a fuzzy finder, takes a multiple selection, then offers `tar_make`, `tar_invalidate`, `tar_status` and `tar_visnetwork` on the selection through the same finder, printing the equivalent call before running it. A function, not a macro: it only needs names, and returns the action's result.

**Decision: a small finder of our own, not fzf or TerminalMenus.** Shelling out to `fzf` would add an external program; `REPL.TerminalMenus` cannot filter by typing (its `q` key cancels, and it has no query). `src/fuzzy.jl` matches each space-separated term as a case-insensitive subsequence, ranking word starts and runs higher and gaps lower, and redraws in place. Key decoding, state and drawing take any `IO`, so tests drive them with `IOBuffer`s; only a real terminal is switched to raw mode, with the call REPL itself uses, so REPL is not a dependency.

### Lower priority, not yet planned

- Cloud or shared stores (S3, GCS): would need an object-storage backend behind `object_path`/`atomic_write`, which Phase 13's interface makes easier.
- Archiving previous runs and keeping a target's store across renames (out of scope since v0.1.0).
- A Documenter site.
- Renaming the package (see the registry check below); needed before registering, independent of the phases above.

### v0.2.0 milestones

| Milestone | Contents | Gate |
| --- | --- | --- |
| **M6: Seeds and scheduler** | Phase 10; Phase 11.1–11.2 (structural) | Seed tests; with one worker, order, logs and summaries are identical to v0.1.0; oracle test |
| **M7: Concurrent jobs** | Phase 11.3 | Concurrency, failure, mutation and slot tests; oracle and seed tests with `jobs = 4` on one and on four threads; no `threadid` guard test |
| **M8: Formats** | Phase 13 | Round-trip and stability per format; `:format_changed`; JET and Aqua with the new extensions |
| **M9: Patterns** | Phase 14 | Combinator, grouping and `tar_rep` scenarios; branch overhead benchmark recorded |
| **M10: Errors and debugging** | Phase 15 | Error-mode, retry and workspace scenarios |
| **M11: Cues and progress** | Phases 16 and 17 | Cue reasons; events and `tar_progress` tests |
| **M12: Distributed** | Phase 12 | Local `addprocs` builds match task-based builds |
| **M13: Reports** | Phase 18 | Report scenarios with a fake renderer; one real render where Quarto is installed |

## Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Source cannot be located (REPL without Revise, `eval`) | Lowered fallback is Julia-version dependent | Record `hash_source`; rebuild only those targets on a Julia change, with a warning (4.1) |
| Several identical-signature lambdas on one line | Editing one rebuilds its line-mates | Conservative by design; recommend one target per line (4.1) |
| Session runs old code while files on disk are new | Hashes and behavior disagree | Modification-time guard, Revise integration, `fresh = true` (4.2, Phase 5) |
| Code reached only dynamically, `@generated` functions | Changes go undetected | Document; `cue = :always` and `force = true` |
| JLD2 output not byte-stable for some types | Spurious downstream rebuilds, never wrong results | `value_hash` hook; switch default to `canonical_hash` if needed (4.3) |
| Values `canonical_hash` cannot encode | Serialization fallback is Julia-version dependent | Report as version-dependent; extend the encoder for common types |
| User types defined in `_targets.jl` | Stored objects fail to load | Named user module convention, clear error on load failure (Phase 3) |
| `Base.method_argnames` changes in a Julia release | Dependency inference breaks | One isolated helper, CI on LTS and latest (Phase 1) |
| Recursive hashing or large globals slow on large codebases | Slow no-op runs | Per-run memoization; later, a per-file hash cache keyed by modification time |
| User code unsafe to run concurrently under `jobs > 1` (v0.2.0) | Crashes or wrong results | `deployment = :main`; `jobs = 1` default; document (Phase 11) |
| Targets mutating shared upstream values in place (v0.2.0) | Races between consumers; cached value no longer matches its hash | Document; opt-in `check_mutation` (Phase 11) |
| Default RNG stream changes between Julia releases (v0.2.0) | Seeded targets differ after an upgrade without rebuilding | Document; `tar_seed()` with StableRNGs.jl (Phase 10) |
| Format writers that are not byte-stable (v0.2.0) | Spurious downstream rebuilds | Per-format stability tests and content hashing (Phase 13) |

**Registry check (done during M5): the name `Targets` is taken.** A package called `Targets.jl` (codedthinking/Targets.jl, a small `@target`/`@get` memoisation package with a different design) is already registered, so this package must be renamed before it can be registered. The name appears in `Project.toml`, `src/Targets.jl`, the extension `TargetsMakieExt`, the tests and the README; a rename is a mechanical find-and-replace plus a new UUID.

The existing package's design is lighter: it re-evaluates a target when its dependencies or a redefined function change, and keeps values in the session. It is a useful contrast for the README, but there is nothing in it to borrow for the on-disk store, hashing or branching.
