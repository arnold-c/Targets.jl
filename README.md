# Targets

[![Build Status](https://github.com/arnold-c/Targets.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/arnold-c/Targets.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A pipeline toolkit for Julia in the spirit of R's
[`targets`](https://docs.ropensci.org/targets/). Declare an analysis as named
**targets**, each produced by a function of upstream targets. Every result is cached
(as a JLD2 file) and each run rebuilds only what changed: the code, the data
flowing in, or the input files.

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
tar_dot()                     # Graphviz text of the pipeline, coloured by status
```

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
7. an upstream value changed, or (for file targets) a file's contents changed.

A rebuilt target whose output is identical stops the change there: its consumers
see an unchanged value hash and are not rebuilt (*early cutoff*).

Hashes come from parsed source, not lowered code, so upgrading Julia does not by
itself rebuild anything. Only code whose source cannot be found (defined with
`eval`, or at the REPL without Revise) falls back to lowered code and is flagged.

"User code" is anything under the project directory, plus locations listed in
`tar_pipeline(...; track = [MyLabUtils, "../shared"])`. Installed packages are
covered by a Manifest check: when `Manifest.toml` changes, `tar_make` names the
packages that moved, and `track_manifest = true` rebuilds everything.

## Target kinds

- **Values** (default): the result is stored with JLD2. Even constants are targets,
  so changing a setting rebuilds exactly its consumers.
- **File targets** (`format = :file`): the function returns a path, a vector of
  paths, or a directory. Contents decide: editing an input file rebuilds its
  consumers, touching it does not, and deleting an output rebuilds the target
  that wrote it. Consumers receive the path. Paths are relative to the project root,
  which is the working directory during a build.
- **Dynamic branching** (`pattern = :other`): the function runs once per element of
  the pattern target's vector. Branches are named by the hash of their element, so
  adding, removing or reordering elements rebuilds only the new ones, and a change to
  one element rebuilds one branch (and, through `pattern = :branching_target`, one
  chain of branches). Downstream targets receive the vector of branch values.

## Running builds

`tar_make(; names, force, keep_going, fresh, ...)`:

- `names = [:model]` builds those targets and everything they depend on.
- `force = true` rebuilds the selection (or everything) whatever its status.
- `keep_going = true` carries on with independent targets after a failure.
- `fresh = true` builds in a new Julia process, so no stale session state can leak in
  (use it for final and CI runs).

It returns a `BuildSummary` listing what was built, skipped, errored or blocked, and
logs `▶ target (reason)` / `✔ target 1.2s` lines to the terminal and to
`_targets/log/progress.log`. Values are held in memory only while a later target in
the run still needs them.

If you edit a source file without Revise and without restarting, the session still
runs the old code while the files on disk have changed, so `tar_make` stops with an
explanation rather than record the wrong hashes. Load Revise, restart, or use
`fresh = true`.

## Helpers

| Function | Does |
| --- | --- |
| `tar_read(:name)` / `@tar_load a b` | Read stored values |
| `tar_outdated()` | Targets that would rebuild, with reasons (conservative) |
| `tar_manifest()` / `tar_meta()` | Target table / stored metadata table |
| `tar_invalidate(names = [:a])` | Forget a target's metadata so it rebuilds; keep its object |
| `tar_delete(names = [:a])` | Delete a target's object and metadata |
| `tar_prune()` | Delete stored targets no longer in the pipeline |
| `tar_destroy()` | Delete the whole store (asks first) |
| `tar_dot(; names, descendants)` | Graphviz DOT, optionally for a sub-graph; renders as SVG in notebooks if Graphviz is installed, `write("p.dot", tar_dot())` saves it |
| `tar_visnetwork(; names, descendants)` | Plot (needs a Makie backend, e.g. `using CairoMakie`) |

## Practical notes

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
- Parallel builds are not implemented yet; the build loop is structured so they
  can be added.

## Development

Tests are `@testitem`s that live next to the code in `src/`, with Aqua and JET
checks in `test/runtests.jl`. Run them with `juliati` (`juliati --filter ...` for
one item or file). The design is described in [`plan.md`](plan.md).
