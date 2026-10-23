# Implementation Plan: A targets-style Pipeline Package for Julia

## Overview and scope

The package lets users declare an analysis as named targets, each produced by a Julia function from upstream targets. It caches every result as a JLD2 file and, on each run, rebuilds only targets whose code, upstream data or input files changed. The working name in this plan is **Targets.jl**; rename freely.

Decisions already made:

- **API:** a function-based core (`target(:name, f)`, dependencies inferred from `f`'s argument names), with a macro layer added at the end as pure sugar.
- **Change detection:** recursive source hashing of user functions via CodeTracking.jl.
- **In scope beyond the core:** file targets, DAG visualization, dynamic branching.
- **Out of scope for v1:** parallel execution. The design should not preclude it (see Phase 5).

Success criterion for v1: running `tar_make()` twice in a row with no changes builds nothing; editing one function rebuilds exactly that function's targets and their affected descendants; an unchanged rebuilt output stops propagation (early cutoff).

## Package architecture

Keep the package as a handful of small, separately testable files, each owning one layer. The build loop should only orchestrate; it should never compute hashes or touch files directly.

| File | Responsibility |
| --- | --- |
| `src/Targets.jl` | Module, exports, includes |
| `src/target.jl` | `Target` struct, `target()` constructor, argument-name inference |
| `src/pipeline.jl` | `Pipeline` struct, validation, DAG construction, topological order |
| `src/store.jl` | `_targets/` layout, JLD2 read/write, atomic writes, metadata I/O |
| `src/hashing.jl` | Expression, value, file and function hashing |
| `src/codedeps.jl` | Recursive discovery of user functions called by a target |
| `src/outdated.jl` | Staleness rules, `tar_outdated()` |
| `src/make.jl` | `tar_make()` build loop, logging, error handling |
| `src/branching.jl` | Dynamic branching (`pattern = map(...)`) |
| `src/api.jl` | `tar_read`, `tar_load`, `tar_meta`, `tar_invalidate`, `tar_destroy` |
| `src/macros.jl` | `@target` / `@pipeline` sugar (last phase) |
| `ext/TargetsGraphMakieExt.jl` | `tar_visnetwork()` plotting, loaded only when GraphMakie is |

**Dependencies.** Hard dependencies: JLD2.jl, Graphs.jl, SHA (stdlib), CodeTracking.jl, TOML (stdlib), Dates (stdlib). Weak dependencies, loaded through package extensions: GraphMakie.jl and a Makie backend for visualization. Recommend Revise.jl to users, since CodeTracking finds REPL-defined methods only when Revise is loaded.

**Decision: package extensions for visualization.** Makie is heavy to load. Putting plotting in `ext/` keeps `using Targets` fast and means headless servers never pay for it. A Graphviz DOT export (`tar_dot()`) lives in the core, since it is plain string output.

## Phase 1: Target type and `target()` API

A target is a name plus a single-method function whose argument names are the names of its upstream targets.

```julia
struct Target
    name::Symbol
    f::Function
    deps::Vector{Symbol}      # from f's argument names
    format::Symbol            # :jld2 or :file
    pattern::Union{Nothing,Symbol}  # dynamic branching (Phase 8)
    cue::Symbol               # :thorough (default), :always, :never
end

target(name::Symbol, f::Function; format = :jld2, pattern = nothing, cue = :thorough) =
    Target(name, f, arg_names(f), format, pattern, cue)
```

**Decision: everything is a target, including constants.** A settings object becomes `target(:settings, () -> (alpha = 0.05, n_boot = 1000))`. A zero-argument function is a root target. This removes the need to detect and hash arbitrary globals, which is one of the fiddliest parts of the R package, and changing a setting invalidates exactly its consumers.

**Decision: one method, positional arguments only.** `arg_names(f)` reads `Base.method_argnames(only(methods(f)))[2:end]`. Raise a clear error when `f` has several methods, keyword arguments or varargs, and suggest wrapping it in an anonymous function. Isolate the `method_argnames` call in one helper and cover it in CI, since it is a Base internal.

**Decision: names are `Symbol`s and must be valid identifiers.** They become file names in the store, so reject anything that is not a valid Julia identifier. Uniqueness is checked at the pipeline level.

**Decision: underscore-prefixed arguments are not dependencies.** Not needed for v1, but reserve the convention (an argument named `_x` is ignored) rather than leaving the namespace open, so you can later add injected values such as a branch index.

Done when: `target()` returns correct `deps` for named functions, anonymous functions and zero-argument functions, and errors helpfully for multi-method functions.

## Phase 2: Pipeline construction and DAG

A `Pipeline` is a validated, ordered collection of targets plus the graph between them, built once and never mutated.

```julia
struct Pipeline
    targets::Vector{Target}           # declaration order
    index::Dict{Symbol,Int}           # name => vertex
    graph::SimpleDiGraph{Int}         # edge dep => dependent
    order::Vector{Symbol}             # build order
end

pipeline(ts::Target...) = Pipeline(collect(ts))
```

**Decision: where the pipeline is defined.** Mirror R's `_targets.R` with a `_targets.jl` file in the project root whose last expression returns a `Pipeline`. `tar_make()` with no arguments includes that file into a fresh anonymous module, then calls `tar_make(p::Pipeline)`. The fresh module avoids state leaking from the REPL between runs; the explicit `tar_make(p)` method stays available for tests and scripting.

**Validation, in this order, each with a specific error message:**

1. Target names are unique.
2. Every dependency names a defined target. Name the target and the missing dependency, and suggest close spellings.
3. The graph is acyclic. On a cycle, print the cycle itself (`a → b → c → a`), not just "cycle detected"; Graphs.jl's `simplecycles` or a DFS with a path stack gives you it.
4. Branching targets reference a pattern target that is also one of their dependencies (Phase 8).

**Decision: deterministic build order.** Implement Kahn's algorithm yourself, breaking ties by declaration order, rather than using `topological_sort_by_dfs`. Any valid order is correct, but a stable one makes logs readable and tests reproducible, and it matches what users expect when they read `_targets.jl` top to bottom.

**Subset builds.** `tar_make(names = [:model])` builds the requested targets plus all their ancestors and nothing else. Compute ancestors by BFS on the reversed graph, then filter the stored order.

Done when: valid pipelines produce a stable order; each validation failure produces its own readable error; subset selection returns exactly the ancestor closure.

## Phase 3: On-disk store and metadata

The store is a directory, `_targets/` by default, holding one JLD2 object and one metadata record per target, and every write to it is atomic.

```
_targets/
  store.toml            # store format version, Julia version
  objects/model.jld2
  objects/model_1a2b3c.jld2   # a branch (Phase 8)
  meta/model.toml
  log/progress.log
  .gitignore            # "*" by default
```

**Decision: one TOML metadata file per target.** A single metadata table has to be rewritten after every target. Per-target files are written once each, can be inspected by hand, and an interrupted run can never corrupt another target's record. `tar_meta()` assembles them into a table on demand.

Fields in each metadata record:

| Field | Purpose |
| --- | --- |
| `command_hash` | Hash of the target's own function source |
| `code_hash` | Combined hash of all user functions it calls (Phase 4) |
| `dep_hashes` | Upstream name → that upstream's `value_hash` at build time |
| `value_hash` | Hash of this target's output |
| `format` | `jld2` or `file` |
| `built_at`, `seconds` | Timing, for logs and `tar_meta()` |
| `error` | Last error message, empty on success |
| `julia_version` | For diagnostics only |

**Decision: atomic writes everywhere.** Write to a temporary file in the same directory, then `mv(tmp, final; force = true)`. A rename within one filesystem is atomic, so a crash leaves either the old version or the new one. Write the object first and the metadata second: metadata is the commit marker, and an object without matching metadata is treated as outdated.

**Decision: never overwrite a good object with a failure.** When a target errors, record the error in its metadata and leave the last successful object in place.

**Decision: user types live in a named module.** JLD2 records each value's type by module path. Types defined inside `_targets.jl`, which is loaded into a fresh anonymous module each run, will not resolve when loaded later. Document that users should keep functions and types in a project-local module or package (for example `src/MyAnalysis.jl` loaded with `using MyAnalysis`) and keep `_targets.jl` to target declarations. This also mirrors the R convention of keeping functions in `R/`.

**Store versioning.** Write a `store.toml` with a format version from day one, so later layout changes can be detected and migrated instead of silently misread.

Done when: values round-trip through JLD2; killing a write mid-way never leaves a corrupt or half-committed target; `tar_meta()` returns a table of all records.

## Phase 4: Hashing, staleness and function tracking

A target is rebuilt when its own code, any user function it reaches, any upstream value or its input file has changed; this phase computes each of those hashes and compares them with the stored record.

### 4.1 Hash primitives

Use SHA.jl for everything that is persisted: `bytes2hex(sha256(x))`. Never persist `Base.hash`, which is not guaranteed stable across Julia versions or sessions.

**Decision: hash normalized source, not raw text.** Get a method's source with `CodeTracking.definition(String, m)`, parse it with `Meta.parse`, strip line nodes with `Base.remove_linenums!`, and hash `string(expr)`. Comments, blank lines, reformatting and moving a function within a file then cause no rebuild; any change to what the code does does.

**Fallback when source is unavailable.** `definition` returns `nothing` for some methods (defined via `eval`, or in a REPL without Revise). Fall back to hashing `code_lowered` with line information stripped. If that also fails, warn once and treat the target as `cue = :always`, so the package is never silently wrong.

### 4.2 Recursive function discovery

For each target, find every user-defined function its code can reach and hash all of them.

1. Take the target function's method source as an `Expr`, and `macroexpand` it in the method's module so calls generated by macros (such as `@.` or `@chain`) are visible.
2. Walk the expression and collect every `Symbol`, `GlobalRef` and qualified name (`Mod.f`). Collect all references, not just call heads: `map(clean_row, rows)` passes a function as an argument.
3. Resolve each name in the method's module with `isdefined` and `getglobal`, keeping only values that are `Function`s (or callable types with methods you choose to track).
4. Keep only **user code** (see decision below), then recurse into each kept function's methods. Keep a visited set to handle recursion and mutual recursion.
5. For each discovered function, hash **all** of its methods, sorted by their normalized source. Under multiple dispatch, editing any method could change behavior, and sorting makes the result independent of method-table order.
6. Combine into `code_hash = sha256(join(sort(["$(name)=$(h)" for each function])))`.

**Decision: "user code" means the method's source file is inside the project directory.** Compare each method's `file` against the directory containing the active `Project.toml`. This is simple and robust: project-local modules and `_targets.jl` count, while Base, stdlibs and installed packages (under `~/.julia`) do not. Package changes are handled separately (4.5).

**Memoize within a run.** Many targets call the same helpers. Cache each function's hash in a `Dict{Function,String}` for the duration of one `tar_make()`.

**Known limits, to document rather than solve:** functions reached only through dynamic dispatch on runtime values (`getfield(mod, sym)`, functions stored inside data), `@generated` functions, and code loaded with `eval`. These are rare in analysis code; the fallback in 4.1 and `cue = :always` cover them.

**Decision: guard against stale sessions.** CodeTracking reads files from disk. If a user edits `src/MyAnalysis.jl` without Revise and without restarting, the hash reflects the new file while the session runs the old code. Detect this by comparing each user file's modification time against when its module was loaded, and error with a message to load Revise or restart. Phase 5 also offers a fresh-process build that avoids the problem entirely.

### 4.3 Value hashing and early cutoff

**Decision: hash the written JLD2 file's bytes by default, with a user hook.** Expose `Targets.value_hash(x)`, returning `nothing` by default; users can add methods for their own types to return a semantic hash. When it returns `nothing`, hash the object file.

The key insight that makes this safe: a non-deterministic value hash only costs efficiency, never correctness. If identical data hashes differently, downstream targets rebuild unnecessarily, but nothing stale is ever kept. Add CI tests that check byte-stability for common types (arrays, `NamedTuple`, `Dict`, a DataFrame); if JLD2 output turns out unstable for important types, switch the default to hashing the `Serialization.serialize` bytes.

Early cutoff then falls out naturally: a rebuilt target with an unchanged `value_hash` leaves its children's recorded `dep_hashes` matching, so they are not outdated.

### 4.4 Staleness rules

`is_outdated(t)` checks these in order and returns the **first reason** that applies, or `nothing`. Returning a reason rather than a `Bool` costs nothing and powers `tar_outdated()` explanations and the progress log.

1. `cue = :never` → never outdated if an object exists; `cue = :always` → always outdated.
2. No metadata record, or no object file → `:missing`.
3. The last build errored → `:errored`.
4. `command_hash` differs → `:command_changed`.
5. `code_hash` differs → `:code_changed`.
6. The set of dependency names differs from the recorded one → `:deps_changed`.
7. Any upstream's current `value_hash` differs from the one recorded in `dep_hashes` → `:upstream_changed`.
8. For file targets, the file's content hash differs (Phase 7) → `:file_changed`.

During `tar_make()` these checks run in build order, so each upstream's metadata is already final when its children are checked.

**Decision: `tar_outdated()` is conservative.** Without building, you cannot know whether a rebuilt upstream will produce the same value. Report every descendant of an outdated target as outdated (reason `:upstream_outdated`), as the R package does. The actual build may then skip some of them via early cutoff.

### 4.5 Package versions

**Decision: warn, don't invalidate, by default.** Store a hash of `Manifest.toml` in `store.toml`. When it changes, print which packages changed and suggest `tar_invalidate()`. Offer an opt-in `track_manifest = true` that invalidates everything instead. Invalidating every target on any package update is too aggressive as a default for long pipelines.

Done when: editing a helper two calls deep rebuilds the right targets; editing a comment rebuilds nothing; adding a method to a used function rebuilds its consumers; a rebuilt-but-identical target stops propagation.

## Phase 5: The `tar_make()` build loop

`tar_make()` walks the pipeline in build order, rebuilds each outdated target from its upstream values, commits the result, and returns a summary of what it did.

```julia
function tar_make(p::Pipeline; names = nothing, store = "_targets", keep_going = false)
    s = open_store(store)
    ctx = BuildContext(p, s)                  # value cache, refcounts, hash memo
    for name in selected_order(p, names)
        t = p.targets[p.index[name]]
        reason = is_outdated(ctx, t)
        reason === nothing && (log_skip(ctx, t); continue)
        build!(ctx, t, reason; keep_going)
    end
    return summary(ctx)                       # (built, skipped, errored)
end
```

**Decision: structure the loop as a ready-queue scheduler, even single-threaded.** Keep a set of targets whose dependencies are all finished and pop from it in declaration order. In v1 this behaves exactly like walking the topological order. When you add parallelism later, the change is replacing "pop one and build it" with "hand ready targets to `Threads.@spawn` workers", instead of rewriting the loop.

**Decision: an in-memory value cache with reference counting.** When a target is built or loaded, keep its value in a `Dict{Symbol,Any}` with a count of how many downstream targets in this run still need it. Decrement after each consumer runs and drop the value at zero. Load from JLD2 only on a cache miss. Large pipelines then hold only the values currently in use.

**Calling user code.** Call `Base.invokelatest(t.f, args...)`, because `_targets.jl` and user modules may have been (re)defined after `tar_make` was compiled. Time the call with `@elapsed`, then write the object, then the metadata.

**Decision: errors stop the run by default.** On an exception, record the message and backtrace summary in the target's metadata, keep its previous object, and rethrow after flushing the log. With `keep_going = true`, mark the failed target's descendants as `:skipped_upstream_error` and continue building everything independent of it. Catch `InterruptException` separately: commit nothing for the interrupted target and rethrow immediately.

**Logging.** One line per target, to the terminal and to `log/progress.log`, including the reason from Phase 4: `▶ model (code_changed)`, `✔ model 12.4s`, `✖ model: DimensionMismatch…`, `· clean_data up to date`. Finish with a one-line summary. Showing the reason is the single most useful debugging aid when something rebuilds unexpectedly.

**Decision: offer a fresh-process build.** `tar_make(; fresh = true)` runs `julia --project=<active project> -e 'using Targets; tar_make()'` in a subprocess, like the R package's `callr` default. It eliminates stale-session problems entirely. Keep in-process the default, because Julia's startup and compilation latency makes a subprocess noticeably slower for quick iterations; recommend `fresh = true` for final and CI runs.

Done when: a second run with no changes builds nothing and reads no object files; memory stays bounded on a long chain of large targets; `keep_going` builds independent branches after a failure.

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
| `tar_prune()` | Delete objects for targets no longer in the pipeline |
| `tar_destroy()` | Delete the whole store, after a confirmation prompt |
| `tar_dot()` | Graphviz DOT text of the DAG, colored by status |
| `tar_visnetwork()` | Plot of the DAG (GraphMakie extension) |

**Decision: `@tar_load` is a macro, not a function that writes into `Main`.** A function that assigns globals in `Main` breaks when used inside another module or a test. A macro expands to `model = tar_read(:model)` in the caller's own scope, which works everywhere. This is the one macro worth having before Phase 9.

**Decision: `tar_invalidate` keeps the object.** Deleting only metadata forces a rebuild while leaving `tar_read` working in the meantime. `tar_delete` is the explicit way to remove data.

### Visualization

**Decision: compute the layout yourself, by layers.** Assign each target a layer equal to its longest-path depth from any root, place layers left to right, and order targets within a layer by declaration order (later, by a barycenter pass to reduce crossings). This gives the left-to-right flow users expect from the R package's graph, needs no extra dependency, and is shared by `tar_dot()` (as `rank` hints) and `tar_visnetwork()` (as explicit node positions passed to GraphMakie).

**Encoding.** Color nodes by status: up to date, outdated, errored, and not yet built. Use a distinct shape for file targets and show branch counts in the label of branching targets (`fits [24]`). Reserve a `targets_only = true` keyword for when you later show user functions as nodes, as the R package does.

**Status is computed, not stored.** Both `tar_dot()` and `tar_visnetwork()` call `tar_outdated()`, so the graph always reflects the current code and store.

Done when: each helper has a test; the plot and DOT output show correct colors after an edit; `@tar_load` works inside a function and a module.

## Phase 7: File targets

A file target returns one or more paths, and its value hash is the hash of those files' contents, so editing an input file or deleting an output file triggers a rebuild.

```julia
target(:raw_file, () -> "data/raw.csv"; format = :file)
target(:raw_data, raw_file -> CSV.read(raw_file, DataFrame))
target(:figure, (model) -> (save("output/fit.png", plot_fit(model)); "output/fit.png"); format = :file)
```

The same mechanism covers both directions: **input files** (a zero-argument function returning a path the user maintains) and **output files** (a function that writes a file and returns its path).

**Decision: no JLD2 object for file targets.** The value is just the path or vector of paths, stored in the metadata record together with the content hash. Downstream targets receive the path, not the contents. Adjust staleness rule 2 so that, for file targets, "object missing" means "any returned file missing".

**Decision: re-check files on every run, cheaply.** External files can change without any code changing, so file targets are always checked. Store each file's size and modification time with its hash; if both match the stored values, reuse the stored hash, otherwise re-hash the contents. This is the same trick the R package uses, and it keeps runs fast with large data files.

**Decision: content hash, not modification time, decides.** A file that was touched but not changed (for example re-downloaded with identical bytes) gets a new modification time but the same hash, so nothing downstream rebuilds.

**Details to settle in implementation:**

- **Directories.** Hash every file underneath in sorted path order, combining relative path and content, so renames count as changes.
- **Paths.** Store paths relative to the project root, so a project can be moved or cloned. Warn on absolute paths outside the project.
- **Validation.** After a file target's function returns, check that every path exists and error if not; a function that "forgets" to write its file is a common bug.

Done when: editing an input CSV rebuilds its consumers; touching it without changing bytes rebuilds nothing; deleting an output file rebuilds the target that wrote it.

## Phase 8: Dynamic branching

A branching target runs its function once per element of a pattern target, stores each result as its own branch, and on later runs rebuilds only the branches whose inputs changed.

```julia
target(:grid, () -> [(alpha = a, depth = d) for a in (0.1, 0.5), d in 2:4] |> vec)
target(:fits, (clean_data, grid) -> fit_model(clean_data, grid); pattern = :grid)
target(:summary, fits -> summarize(fits))   # receives a Vector of all branch values
```

The pattern argument (`grid`) is passed one element at a time; every other argument (`clean_data`) is passed whole to each branch. A non-branching consumer of `fits` receives a `Vector` of branch values in pattern order.

**Decision: branch identity comes from the element's hash, not its position.** Name each branch `fits_<first 8 hex chars of the element's hash>`. Inserting, removing or reordering elements of `grid` then leaves the other branches' names and objects untouched, so they are not rebuilt. Index-based names would invalidate every branch after an insertion. Disambiguate duplicate elements by appending an occurrence count to the hash input.

**Decision: v1 supports `AbstractVector` patterns and one pattern per target.** Require the pattern value to be an `AbstractVector` and error clearly otherwise. Cross products are built upstream (as `grid` is above) instead of adding a `cross()` mode now. This covers most real uses and keeps the branch bookkeeping simple.

**Branching over branches.** When the pattern target is itself a branching target, map 1:1 over its branches: `target(:preds, fits -> predict(fits); pattern = :fits)` creates one `preds` branch per `fits` branch. This is what lets a change to one grid element rebuild exactly one chain of branches.

**Storage and staleness.**

- Each branch is stored and checked like a small target: its own object, and a metadata record under `meta/fits/<branch id>.toml` holding its dependency hashes, including the hash of its element.
- All branches share the parent's `command_hash` and `code_hash`, so a code change still rebuilds every branch.
- The parent's metadata lists the branch ids in pattern order, and its `value_hash` is the hash of the ordered list of branch value hashes. Downstream aggregate targets therefore see a change when any branch changes or the order changes.
- At the end of a successful run, delete objects and records for branches no longer in the pattern.

**Static branching is free.** Because the API is plain functions, generating several targets in a loop needs no special support:

```julia
[target(Symbol(:fit_, m), clean_data -> fit(m, clean_data)) for m in (:ols, :lasso, :ridge)]
```

**Decision: hash closure captures as part of `command_hash`.** All three closures above share one source text, so source hashing alone cannot tell them apart, and changing `:ridge` to `:elasticnet` would go unnoticed. A closure is an object whose fields are its captured variables: include `sha256` of each captured field's serialized value in the command hash. This matters beyond static branching, since any closure capturing a setting has the same issue.

Done when: adding one element to the pattern builds exactly one new branch; editing one element rebuilds one branch chain; aggregate targets update when any branch changes.

## Phase 9: Macro sugar

The macro layer is a pure front end: it rewrites expressions into the Phase 1 `target()` calls and adds no new behavior.

```julia
p = @pipeline begin
    @target raw_file = "data/raw.csv"  format = :file
    @target clean_data = clean(CSV.read(raw_file, DataFrame))
    @target grid = make_grid()
    @target fits = fit_model(clean_data, grid)  pattern = grid
    @target summary = summarize(fits)
end
```

expands to `pipeline(target(:raw_file, () -> "data/raw.csv"; format = :file), target(:clean_data, (raw_file,) -> clean(...)), ...)`.

**Decision: `@target` is only valid inside `@pipeline`.** Dependency detection needs to know which symbols are target names. A lone `@target` sees only its own expression and would have to guess. `@pipeline` sees every target name in the block, so for each expression it collects the symbols that match those names and uses exactly those as the generated function's arguments. A bare `@target` outside the block errors with a message pointing to `@pipeline` or `target()`.

**Decision: macro targets hash their original expression.** Add an optional `source::Union{Nothing,Expr}` field to `Target`. The macro fills it with the right-hand side, linenums stripped, and `command_hash` uses it in place of the CodeTracking lookup. Locating the source of a macro-generated anonymous function through CodeTracking is unreliable, while the macro already holds the exact expression. Recursive function discovery (Phase 4.2) starts from this expression too.

**Hygiene and errors.** `esc` the whole generated expression so user functions resolve in the caller's module. Attach the call site's `__source__` line node to each generated function, so stack traces from a failing target point at the right line of `_targets.jl`.

**Edge case to document:** a symbol inside the expression that shadows a target name locally (a comprehension or `let` variable named `grid`) would be treated as a dependency. This is harmless (one extra edge) and rare; skipping symbols bound by local scopes is a possible later refinement.

Done when: a macro pipeline and the equivalent `target()` pipeline produce the same graph and order; errors point to the right lines; editing one `@target` line rebuilds only that target and its descendants.

## Testing strategy

The package's whole promise is "rebuild exactly what changed", so most tests should be scenario tests: build, edit something, rebuild, and assert the exact set of targets that ran.

**Decision: make the project root and store path parameters.** Default the project root to the directory of the active `Project.toml`, but accept it as a keyword. Tests can then create a throwaway project with `mktempdir()`, write `_targets.jl` and source files into it, and run real builds without touching the package's own directory. This also makes the "user code is under the project root" rule (Phase 4.2) testable.

**Assert on `tar_make()`'s summary.** Have the summary return the names built, skipped and errored. Assertions like `@test built == [:clean_data, :model]` are then direct, with no need for counters inside user functions.

Core scenarios, each a test:

| Change | Expected rebuild |
| --- | --- |
| Nothing | Nothing |
| Edit a comment or whitespace in a used function | Nothing |
| Edit a helper two calls deep | Every target reaching it, plus affected descendants |
| Add a method to a used function | Its consumers |
| Edit a function no target reaches | Nothing |
| Change a target's closure capture | That target and descendants |
| Edit code so the output is unchanged | That target only (early cutoff) |
| Edit an input file | Its file target and consumers |
| Touch an input file without changing bytes | Nothing |
| Delete an output file or an object | That target only, unless its value changed |
| Add one element to a branching pattern | One new branch and the aggregates |
| A target errors | Nothing downstream; previous object kept |

**Oracle test: equivalence with a clean build.** Generate random small DAGs with random integer-valued functions, apply random edits, and run incremental builds. After every step assert two invariants: `tar_outdated()` is empty, and every stored value equals what a from-scratch build into a fresh store produces. This catches staleness bugs that no hand-written scenario anticipates.

**Stability tests.** Compute source and value hashes in two separate Julia subprocesses and assert they match, so non-deterministic hashing is caught in CI rather than by users seeing spurious rebuilds.

**CI matrix.** Run on the current Julia LTS and the latest stable release, on Linux, macOS and Windows. The `method_argnames` dependency on Base internals and the path handling in file targets are the two places most likely to break across versions and platforms.

## Milestones and risks

Build in five milestones, each ending in something usable and a test that gates the next; the first gets a correct, if coarse, pipeline running before the hard hashing work begins.

&#91;embedded content: build milestones · 5 stages, each with a gate\]

M1 deliberately hashes only each target’s own source, so a working pipeline exists before the recursive tracking in M2 is attempted.

### Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| CodeTracking cannot find a method's source (REPL without Revise, `eval`) | Changes go undetected | Fall back to `code_lowered`; otherwise warn and treat as `cue = :always` (4.1) |
| Session runs old code while files on disk are new | Hashes and behavior disagree | Modification-time check, Revise recommendation, `fresh = true` builds (4.2, Phase 5) |
| JLD2 output not byte-stable for some types | Spurious downstream rebuilds, never wrong results | `value_hash` hook; switch default to `Serialization` bytes if needed (4.3) |
| User types defined in `_targets.jl` | Stored objects fail to load | Named user module convention, clear error on load failure (Phase 3) |
| `Base.method_argnames` changes in a Julia release | Dependency inference breaks | One isolated helper, CI on LTS and stable (Phase 1) |
| Recursive hashing is slow on large codebases | Slow no-op runs | Per-run memoization; later, a per-file hash cache keyed by modification time |
| Closure captures not hashed | Silent staleness in loop-generated targets | Hash captured fields into `command_hash` (Phase 8) |

Before registering, search the General registry and JuliaHub for existing packages with similar names or aims, both to avoid a name clash and to borrow ideas.
