# Targets

[![Build Status](https://github.com/arnold-c/Targets.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/arnold-c/Targets.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A pipeline toolkit for Julia in the spirit of R's
[`targets`](https://docs.ropensci.org/targets/). Declare an analysis as named
**targets**, each produced by a function of upstream targets. Every result is cached
(as a JLD2 file) and each run rebuilds only what changed: the code, the data
flowing in, or the input files. Independent targets and branches can run in
parallel, as Julia tasks or on `Distributed` worker processes.

The full documentation is at <https://targets.callumarnold.com>.

> **Name.** "Targets" is a working name. A different package called `Targets.jl`
> is already in the General registry, so rename this one before registering.

## A first pipeline

Keep functions (and types) in a project module or package, and keep the pipeline
description in `_targets.jl` at the project root. Its last expression returns the
pipeline:

```julia
# _targets.jl
using Targets
using MyAnalysis            # defines clean, fit_model, summarize, ...

@pipeline begin
    @target raw_file   = "data/raw.csv"            format = :file
    @target clean_data = clean(CSV.read(raw_file, DataFrame))
    @target grid       = [(alpha = a, depth = d) for a in (0.1, 0.5), d in 2:4] |> vec
    @target fits       = fit_model(clean_data, grid)    pattern = grid
    @target summary    = summarize(fits)
end
```

Run it from the project root:

```julia
using Targets
tar_make()                    # builds everything
tar_make()                    # builds nothing: everything is up to date
tar_read(:summary)            # the stored value
@tar_load clean_data fits     # clean_data = tar_read(:clean_data), ...
tar_outdated()                # what would rebuild, and why
tar_list()                    # target names by section, in build order
tar_status()                  # the same, with each target's status, in colour
tar_dot()                     # Graphviz text of the pipeline, coloured by status
```

Each `@target`'s dependencies are the targets its expression refers to. Names the
expression binds itself (comprehension variables, lambda arguments, `let` and `do`
bindings) are not dependencies, and a name that is neither a target nor defined where the
pipeline is written is an error that names its line. A target's own name means what it
means outside the pipeline, so `@target summary = summary(fits)` calls `summary`.

Each target name can be declared only once in a pipeline. Declaring a name twice, in the
same block, in two fragments, or through names that `@map`, `tar_map` or `@rep` generate,
is an error that gives the line of each declaration.

### Fragments, static branching and replication

`@targets` declares part of a pipeline, so each analysis can live in its own file: names
are resolved when `tar_pipeline` (or `@pipeline`) puts the fragments together. Inside a
block, `@map` declares targets once per value, as `tar_map` does, and `@rep` replicates an
expression, as `tar_rep` does:

```julia
# One MCMC fit of `data`, as a fragment a function returns
mcmc_fit(; chains) = @targets begin
    @target tuning = tune(data, priors)
    @map(1:chains) do k
        @target chain = run_chain(data, priors, tuning, k)   # chain_1, chain_2, ...
    end
    @target fit = combine(collect(chain))                     # this fit's chains, in order
end

models = @targets begin
    @target priors = default_priors()
    @map((seir = SEIR(), staged = Staged())) do model
        @map((real = :real, synthetic = :synthetic); prefix = true) do source
            @target data = load_data(model, source)          # real_data_seir, ...
            mcmc_fit(; chains = 4)                           # real_fit_seir, ...
        end
    end
    @target comparison = compare(fit)          # fit.seir.real, fit.staged.synthetic, ...
    @rep null = simulate_null(priors)  batches = 10  reps = 100
end

tar_pipeline(models; seed = 2026)
```

Within a branch a name means that branch's target: `data` in the fragment is
`real_data_seir` in the `real`, `seir` branch. Outside a `@map`, a template's name means
all of its targets, as a `NamedTuple` keyed by suffix (nested for nested maps), and the
name a branch gives it refers to that branch's: inside the `seir` branch `real_fit` is
`real_fit_seir`, and outside the maps it is both models' real-data fits. A block may
also assign variables its targets share (`directory = "output"`) and splice in fragments
or `target()`s. Names, suffixes, groups and order follow `tar_map` (below), so
`tar_make(names = [:real_fit])` builds both models' real-data fits.

Without macros, the same pipeline is built from plain functions. A target's
dependencies are the argument names of its function:

```julia
tar_pipeline(
    target(:raw_file, () -> "data/raw.csv"; format = :file),
    target(:clean_data, raw_file -> clean(CSV.read(raw_file, DataFrame))),
    target(:fits, (clean_data, grid) -> fit_model(clean_data, grid); pattern = :grid),
)
```

For static branching (R's `tar_map`), `tar_map` calls a template once per value and
suffixes the names of the targets it returns. Dependencies between targets of the same
template get the same suffix, so they can still be written as argument names:

```julia
m = tar_map((ols = OLS(), lasso = Lasso(0.1))) do model
    (
        target(:fit, clean_data -> fit(model, clean_data)),   # fit_ols, fit_lasso
        target(:summary, fit -> summarize(fit)),              # summary_ols, summary_lasso
    )
end
tar_pipeline(clean_data_target, m, tar_combine(:all_fits, (xs...) -> reduce(vcat, xs), m.summary))
```

Suffixes are the keys of a `NamedTuple` or `Dict`; otherwise the values themselves when
they are symbols, strings, integers or tuples of those (`Iterators.product` crossings give
`fit_ols_1`); otherwise positions. Override with `names = [...]` or `names = v -> ...`.
The result maps template names to their targets (`m.fit`), and `tar_pipeline` flattens it.
A template name also works in every `names` keyword: `tar_make(names = [:fit])`,
`tar_invalidate(names = :fit)` and `tar_delete(names = :fit)` act on all of its targets,
while a generated name such as `:fit_ols` acts on that one alone (the next `tar_make`
rebuilds only it and its descendants).

`tar_map` is a convenience: a comprehension works too, with explicit `deps` for
generated names:

```julia
fits = [target(Symbol(:fit_, m), data -> fit(m, data)) for m in (:ols, :lasso)]
tar_pipeline(fits, tar_combine(:all_fits, (xs...) -> reduce(vcat, xs), fits))
```

## What triggers a rebuild

A target is rebuilt when, in order:

1. you force it (`tar_make(force = true)`, `cue = :always`),
2. it has never been built, or its object or files are missing,
3. its last build failed,
4. the **source of its function** changed (comments, whitespace and moving code do not count),
5. the source of any **user function, type or global it reaches** changed (recursively, all methods),
6. its dependencies changed, or
7. an upstream value changed, or (for file and URL targets) a file's contents or a URL
   changed.

A target's `cue` changes which of these rules apply: `:always`, `:never`,
`Cue(code = false)` (ignore changes to the code it calls), `cue_age(Day(7))` or
`cue_force(condition)`.

A rebuilt target whose output is identical stops the change there: its consumers
see an unchanged value hash and are not rebuilt (*early cutoff*).

Hashes come from parsed source, not lowered code, so upgrading Julia does not by
itself rebuild anything. Methods that a macro or `struct` generates (`@kwdef`
constructors, default constructors, `@eval`) are hashed from the macro call or
`struct` that generates them, and user-defined macros are followed like
functions. Only code whose source cannot be found (defined with `eval`, or at
the REPL without Revise) falls back to lowered code and is flagged.

Hashes do not depend on the numbers Julia gives the functions it generates
(keyword bodies such as `#f#12`, anonymous functions and closures), which
change whenever code earlier in the module does: generated functions, including
lambdas stored in globals or captured by a target, are identified by what they
do.

"User code" is anything under the project directory, plus locations listed in
`tar_pipeline(...; track = [MyLabUtils, "../shared"])`. Installed packages are
covered by a Manifest check: when `Manifest.toml` changes, `tar_make` names the
packages that moved, and `track_manifest = true` rebuilds everything.

## Target kinds

- **Values** (default): the result is stored with JLD2. Even constants are targets,
  so changing a setting rebuilds exactly its consumers. `format` picks another
  storage format: `:jls` (Julia's `Serialization`), or for tables `:arrow`
  (`using Arrow`), `:parquet` (`using Parquet2`) or `:csv` (`using CSV`).
- **File targets** (`format = :file`): the function returns a path, a vector of
  paths, or a directory. Contents decide: editing an input file rebuilds its
  consumers, touching it does not, and deleting an output rebuilds the target
  that wrote it. Consumers receive the path. Paths are relative to the project root,
  which is the working directory during a build.
- **URL targets** (`format = :url`): the function returns one or more URLs, which are
  checked with an HTTP `HEAD` request on every run (nothing is downloaded); consumers
  rebuild when one changes. Offline, the last check is kept with a warning.
- **Dynamic branching** (`pattern = :other`): the function runs once per element of
  the pattern target's vector. Branches are named by the hash of their element, so
  adding, removing or reordering elements rebuilds only the new ones, and a change to
  one element rebuilds one branch (and, through `pattern = :branching_target`, one
  chain of branches). Downstream targets receive the vector of branch values.
- **Quarto reports** (`tar_quarto`, or `@quarto` in `@pipeline` and `@targets`): see below.

## Quarto reports

A report renders one Quarto document with the `quarto` CLI:

```julia
@pipeline begin
    @target model   = fit_model(clean_data)
    @quarto report  = "reports/report.qmd"
    @quarto "reports/appendix.qmd"  params = (draft = true,)   # named :appendix
end
# or: tar_quarto(:report, "reports/report.qmd"; quarto_args = ["--to", "pdf"])
```

Its dependencies are the targets its Julia cells (and inline `` `{julia} ...` ``
code, documents it includes with `{{< include >}}`, and Julia files its code
loads with `include("analysis.jl")`, recursively) read with `tar_read(:name)` or
`@tar_load name`; they are found without running anything, so add any whose
names are computed with `deps = [...]` (and computed include paths with
`extra_files`). The report is rebuilt when one of those targets changes, when
the text of the document or an included file changes (by content: touching it
does nothing), or when an output file is deleted or edited. Code loaded from
packages (`using MyAnalysis`) is not tracked. `tar_read(:report)` gives the
output paths followed by the source paths. Paths are relative to `_targets.jl`.

Inside the document, `tar_read` and `@tar_load` read the store of the build that
is rendering it, wherever the document's Julia environment is (this needs
Quarto's `engine: julia`). When rendering by hand, name the store in the front
matter, relative to the document, or set a `store` preference for the project:

```yaml
engine: julia
targets-store: ../_targets
```

Each render restarts Quarto's Julia worker for the document, so edited code is
never stale (`restart = false` keeps it), and refreshes Quarto's cache. Quarto's
output is shown only when a render fails; `quiet = false` prints it in the REPL
as the render runs, but only when the build runs one job at a time (with `jobs > 1`
it stays quiet, since concurrent output would interleave). Quarto
projects (`_quarto.yml`) and rendering one document several times with different
parameters are not supported.

## Running builds

`tar_make(; names, force, keep_going, fresh, jobs, executor, ...)`:

- `names = [:model]` builds those targets and everything they depend on; a `tar_map`
  template name stands for all of its targets.
- `force = true` rebuilds the selection (or everything) whatever its status.
- `keep_going = true` carries on with independent targets after a failure.
- `fresh = true` builds in a new Julia process with the same project, so nothing from
  your session (code loaded before you edited it, globals or methods changed at the REPL,
  packages the script does not load) can affect the results. It costs a Julia start-up
  and package load per call, so use it for final and CI runs.
- `jobs = 4` (or `:auto`) runs independent targets and branches in parallel; see below.

It returns a `BuildSummary` listing what was built, skipped, errored or blocked, and
logs one line per finished target to the terminal and to `_targets/log/progress.log`:
`✔ target 1.2s (reason)` in green, `✖ target: error` in red. In a terminal, the targets
still running stay pinned below the log, each with a spinner and its time so far, above
a count of the targets done, running and queued (`progress = :lines` prints a
`▶ target (reason)` line at each start instead). Targets that need no build never wait
for a job slot: every up-to-date target in the selection is reported (`· target up to
date`) before the first job starts, and a target whose upstream was rebuilt to the same
value is settled as soon as that upstream finishes. `tar_outdated(names = [...])` shows
what a build would do without building. Values are held in memory only while a later
target in the run still needs them.

If you edit a source file without Revise and without restarting, the session still
runs the old code while the files on disk have changed, so `tar_make` stops with an
explanation rather than record the wrong hashes. Load Revise, restart, or use
`fresh = true`.

### Parallel builds

With `jobs = n`, up to `n` independent targets and branches run at once, each as a
Julia task; targets on the longest remaining path (by their last build times) start
first. `jobs = :auto` is one job per thread of the default threadpool. `jobs` counts
tasks, not threads: more jobs than threads still overlap targets that wait on I/O, but
CPU-bound targets only run in parallel when Julia has threads (`julia -t 8`). The
default is `1`, or the project's `jobs` preference (see below).

```julia
tar_make(jobs = 4)
```

Per-target options control how a target shares the jobs:

- `slots = 2` (or `:all`) makes a target occupy several jobs while it runs, for targets
  that are parallel themselves; `tar_slots()` returns how many it was given, e.g.
  `OhMyThreads.tmap(f, xs; ntasks = tar_slots())`. Slots only decide what runs alongside
  a target: they cannot stop it from using more threads.
- `deployment = :main` runs a target in the task that called `tar_make`, never at the
  same time as another `:main` target, for code that is not safe to run concurrently.

Concurrent targets share the process: they must not `cd`, change `ENV`, or mutate their
arguments (consumers of one upstream receive the same object).
`tar_make(check_mutation = true)` checks the last of these, at a cost, so turn it on in
tests and CI.

To run targets on other processes or machines, pass a `DistributedExecutor`:

```julia
using Distributed
addprocs(4)
tar_make(executor = DistributedExecutor(workers()))
```

Each worker loads `_targets.jl` itself, and the store must be on a filesystem the workers
share with the main process. [Parallel and distributed builds](docs/src/guide/parallel.md)
explains how jobs, tasks, threads, slots and workers relate, and
[Running on a Slurm cluster](docs/src/guide/slurm.md) how to use workers from a Slurm
allocation with SlurmClusterManager.jl.

### Errors, retries and seeds

By default an error stops the build, after running jobs have finished, and is rethrown. A
target's `error` option changes that: `:continue` blocks only its descendants, `:null` gives
consumers `nothing`, and `:trim` (branching targets) leaves failed branches out of its
value. `retries = n` (with `retry_delay`) reruns a failing target within one build. To
investigate a failure, `tar_errored()` lists what failed, `tar_traceback(:model)` gives the
stack frames of its last failure, `tar_workspace(:model)` (or `@tar_workspace model`) the
arguments it failed with, and `tar_rerun(:model)` calls its current function on them.

Every target runs with its own seed, derived from the pipeline seed and its name, so
results are the same whatever the order or parallelism of the build. Set the pipeline
seed with `@pipeline seed = 2026 begin ... end` or `tar_pipeline(...; seed = 2026)`;
`tar_seed()` returns the running target's seed (e.g. `StableRNG(tar_seed())`).

To follow a build from another session, `tar_progress()` gives the latest status of every
target and branch, and `tar_poll()` prints a summary every few seconds until it finishes.

## Helpers

| Function | Does |
| --- | --- |
| `tar_read(:name)` / `@tar_load a b` | Read stored values; warns if one is not up to date (`on_outdated = :error` or `:ignore` to change that) |
| `tar_outdated()` | Targets that would rebuild, with reasons (conservative) |
| `tar_manifest()` / `tar_meta()` | Target table / stored metadata table |
| `tar_list(; names, descendants)` | Target names by section (constants, input files, computations, output files), per connected part of the graph, in build order |
| `tar_status(; names, descendants)` | `tar_list` with each target's status, coloured in the terminal: up to date (green), outdated with its reason (yellow), errored (red), not built (blue) |
| `tar_invalidate(names = [:a])` | Forget a target's metadata so it rebuilds; keep its object. `tar_invalidate()` does this for every target, after asking (`ask = false` skips the question) |
| `tar_delete(names = [:a])` | Delete a target's object and metadata |
| `tar_prune()` | Delete stored targets no longer in the pipeline |
| `tar_destroy()` | Delete the whole store (asks first) |
| `tar_dot(; names, descendants)` | Graphviz DOT, optionally for a sub-graph; renders as SVG in notebooks if Graphviz is installed, `write("p.dot", tar_dot())` saves it |
| `tar_visnetwork(; names, descendants, interactive)` | Plot (needs a Makie backend, e.g. `using CairoMakie`); with GLMakie (a window) or WGLMakie (a browser tab) active it is interactive by default: drag targets (shift-click or shift-drag to select several and move them together), pan and zoom, and hide targets by kind or status, hide the selection, show only the selection, or bring back everything upstream or downstream of the targets still shown, from the side panel (`interactive = false` for a static figure) |
| `tar_picker()` | At the REPL: pick targets in a fuzzy finder (type part of a name, tab or ctrl-a to select, enter to finish), then run `tar_make`, `tar_invalidate`, `tar_status` or `tar_visnetwork` on them, chosen the same way |

## Practical notes

- `tar_read` and `@tar_load` return the last stored value even when a target is
  outdated or invalidated, with a warning. For the project's own store the check
  uses `_targets.jl`, so code edits count. Make it an error (or skip the check)
  for a project in its `LocalPreferences.toml`:

  ```toml
  [Targets]
  on_outdated = "error"   # or "warn" (default), "ignore"
  store = "/scratch/me/_targets"   # the default store, relative to the project root
  jobs = "auto"   # tar_make's default jobs: a number, or "auto" (Threads.nthreads(:default))
  ```

- Put functions and types in a **named module or package**. Values are stored with
  JLD2, which records types by module path; types defined inside `_targets.jl` (a
  fresh anonymous module each run) cannot be loaded later.
- Target functions must have one method with positional arguments, unless you pass
  `deps = [...]`. Argument names starting with `_` are reserved.
- A user type can customise value hashing with `Targets.value_hash(x)`, returning a
  string; the default hashes the stored object file.
- Known limits: code reached only through dynamic dispatch on runtime values
  (`getfield(mod, sym)`), `@generated` functions, and several lambdas with identical
  arguments on one line (edits rebuild all of them). `cue = :always` and
  `tar_make(force = true)` cover these.
- With hundreds of targets, write `@pipeline`/`@targets` blocks at the top level of
  `_targets.jl` (or files it `include`s), where they are split into one statement per
  line, so loading the script stays fast. See
  [Large pipelines](docs/src/guide/large_pipelines.md).

## Development

Tests are `@testitem`s that live next to the code in `src/`, with Aqua and JET
checks in `test/runtests.jl`. Unit tests also run JET on the calls they make
with `@test_call` from the `JETChecks` test module (`src/testing.jl`), which
catches what `JET.test_package` misses with only declared argument types. Run
them with `juliati` (`juliati --filter ...` for one item or file). The design is described in [`plan.md`](plan.md), the user guide
lives in `docs/`, and runnable demos in [`examples/`](examples/README.md).
