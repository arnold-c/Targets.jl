# Implementation Plan: A targets-style Pipeline Package for Julia

This document merges the original design notes (`design-doc.md`) with the
implementation plan. It is the single source of truth for the package design.

## Overview and scope

The package lets users declare an analysis as named targets, each produced by a Julia function from upstream targets. It caches every result as a JLD2 file and, on each run, rebuilds only targets whose code, upstream data or input files changed. The working name in this plan is **Targets.jl**; rename freely.

Decisions already made:

- **API:** a function-based core (`target(:name, f)`, dependencies inferred from `f`'s argument names, with an explicit `deps` escape hatch), with a macro layer added at the end as pure sugar.
- **Change detection:** recursive hashing of the *source* of user functions, user-defined types and user globals. Hashes must not depend on the Julia version wherever source is available.
- **In scope beyond the core:** file targets, DAG visualization (whole graph or a subgraph), dynamic branching, forced rebuilds.
- **Out of scope for v1:** parallel execution (the design should not preclude it, see Phase 5); archiving timestamped copies of previous runs; carrying a target's store over when it is renamed (a rename simply rebuilds, and `tar_prune()` removes the old name).
- **Minimum Julia version: 1.10 (current LTS).** Package extensions and `getglobal` need ≥ 1.9; 1.10 gives the LTS a CI target.
- **Tests:** `@testitem`s from TestItems.jl, written in `src/` next to the code they test, run with `juliati`.

Success criterion for v1: running `tar_make()` twice in a row with no changes builds nothing; editing one function rebuilds exactly that function's targets and their affected descendants; an unchanged rebuilt output stops propagation (early cutoff); upgrading Julia does not, by itself, rebuild anything whose source could be located.

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
| Propagating target name changes | Out of scope for v1: a rename rebuilds |
| `tar_visnetwork`, `tar_glimpse` on a single target | Phase 6 `tar_visnetwork(names = ...)` / `tar_dot(names = ...)` |
| `tar_make` in the global session or a separate process | Phase 5 `fresh = true` |
| `tar_invalidate` | Phase 6 |
| Timestamp and archive previous runs | Out of scope for v1 |

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
| `src/testing.jl` | `@testmodule` fixtures shared by scenario tests (throwaway projects) |
| `src/macros.jl` | `@pipeline` / `@target` sugar (last phase) |
| `ext/TargetsGraphMakieExt.jl` | `tar_visnetwork()` plotting, loaded only when GraphMakie is |

**Dependencies.** Hard: JLD2.jl, Graphs.jl, CodeTracking.jl, JuliaSyntax.jl, TestItems.jl (its `@testitem` macro expands to nothing outside the test runner), and the stdlibs SHA, TOML, Dates, Serialization. Weak, through package extensions: GraphMakie.jl (and a Makie backend chosen by the user). Recommend Revise.jl to users, since CodeTracking finds REPL-defined methods only when Revise is loaded. `tar_meta()` and `tar_manifest()` return a `Vector` of `NamedTuple`s, which is Tables.jl-compatible, so DataFrames is not a dependency.

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

**Decision: underscore-prefixed arguments are not dependencies.** Not needed for v1, but reserve the convention (an argument named `_x` is ignored) so injected values such as a branch index can be added later.

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
   - **Functions:** hash **all** methods, each by its source (4.1), sorted by hash so the result is independent of method-table order. Recurse into each method's body.
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

**Decision: guard against stale sessions.** CodeTracking and the JuliaSyntax locator read files from disk. If a user edits `src/MyAnalysis.jl` without Revise and without restarting, the hash reflects the new file while the session runs the old code. Record `time()` in `Targets.__init__`; if Revise is not loaded and any tracked source file's modification time is later, error with a message to load Revise, restart, or use `fresh = true`. With Revise loaded, call `Revise.revise()` before hashing.

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

**Decision: structure the loop as a ready-queue scheduler, even single-threaded.** Keep a set of targets whose dependencies are all finished and pop from it in declaration order. In v1 this behaves exactly like walking the topological order; adding parallelism later means handing ready targets to `Threads.@spawn` workers instead of rewriting the loop. *Status: M1 walks `p.order` directly, which is equivalent; the loop body is already factored into `process!`/`build!` so the queue can be introduced in M3 without touching them.*

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
| `tar_outdated()` | Outdated targets with the reason for each (Phase 4) |
| `tar_meta()` | All metadata records as a table |
| `tar_invalidate(:name)` | Delete the metadata record so the target rebuilds; keep the object |
| `tar_delete(:name)` | Delete object and metadata |
| `tar_prune()` | Delete objects and records for targets no longer in the pipeline (including renamed ones) |
| `tar_destroy()` | Delete the whole store, after a confirmation prompt |
| `tar_dot(; names = nothing)` | Graphviz DOT text of the DAG or a subgraph, colored by status |
| `tar_visnetwork(; names = nothing)` | Plot of the DAG or a subgraph (GraphMakie extension) |

**Decision: `@tar_load` is a macro, not a function that writes into `Main`.** A macro expands to `model = tar_read(:model)` in the caller's own scope, which works inside functions, modules and tests.

**Decision: `tar_invalidate` keeps the object.** Deleting only metadata forces a rebuild while leaving `tar_read` working in the meantime. `tar_delete` is the explicit way to remove data.

### Visualization

**Decision: subgraphs by name.** `tar_visnetwork(names = [:model])` and `tar_dot(names = [:model])` show the named targets and their ancestors (the same `ancestors` helper as subset builds), which is the original `tar_glimpse` idea. A `descendants = true` keyword adds everything downstream of the named targets, for answering "what does this feed into?". `names = nothing` shows the whole pipeline.

**Decision: compute the layout yourself, by layers.** Assign each target a layer equal to its longest-path depth from any root within the displayed subgraph, place layers left to right, and order targets within a layer by declaration order (later, by a barycenter pass to reduce crossings). This needs no extra dependency and is shared by `tar_dot()` (as `rank` hints) and `tar_visnetwork()` (as explicit node positions passed to GraphMakie).

**Encoding.** Color nodes by status: up to date, outdated, errored, and not yet built. Use a distinct shape for file targets and show branch counts in the label of branching targets (`fits [24]`). Reserve a `targets_only = true` keyword for later showing user functions as nodes.

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
- **Paths.** Store paths relative to the project root, so a project can be moved or cloned. Warn on absolute paths outside the project. Normalize separators so stores are portable between platforms.
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

**Decision: v1 supports `AbstractVector` patterns and one pattern per target.** Error clearly otherwise. Cross products are built upstream, as `grid` is above.

**Branching over branches.** When the pattern target is itself a branching target, map 1:1 over its branches: `target(:preds, fits -> predict(fits); pattern = :fits)` creates one `preds` branch per `fits` branch, so a change to one grid element rebuilds exactly one chain of branches.

**Storage and staleness.**

- Each branch is stored and checked like a small target: its own object under `objects/fits/`, and a record under `meta/fits/<branch id>.toml` holding its dependency hashes, including the hash of its element.
- All branches share the parent's `command_hash` and `code_hash`, so a code change rebuilds every branch.
- The parent's metadata lists the branch ids in pattern order, and its `value_hash` is the hash of the ordered list of branch value hashes.
- At the end of a successful run, delete objects and records for branches no longer in the pattern.

**Static branching (`tar_map`) needs no special support.** Generate targets with a comprehension; `tar_pipeline` flattens the vector (Phase 2), closure captures distinguish the generated targets (4.1), and explicit `deps` combines them (`tar_combine`, Phase 1).

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

Before registering, search the General registry and JuliaHub for existing packages with similar names or aims, both to avoid a name clash and to borrow ideas.
