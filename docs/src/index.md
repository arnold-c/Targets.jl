# Targets.jl

Targets.jl is a pipeline toolkit for Julia in the spirit of R's
[`targets`](https://docs.ropensci.org/targets/). You declare an analysis as named
**targets**, each produced by a function of upstream targets. Every result is cached, and
each run rebuilds only what changed: the code, the data flowing in, or the input files.

!!! note "Name"
    "Targets" is a working name. A different package called `Targets.jl` is already in the
    General registry, so this one will be renamed before it is registered.

## Installation

Install Targets.jl directly from GitHub:

```julia
import Pkg
Pkg.add(url = "https://github.com/arnold-c/Targets.jl")
```

## A first pipeline

Keep functions and types in a project module or package, and keep the pipeline description
in `_targets.jl` at the project root. Its last expression returns the pipeline:

```julia
# _targets.jl
using Targets
using MyAnalysis            # defines clean, fit_model, summarize, ...

@pipeline begin
    @target raw_file   = "data/raw.csv"            format = :file
    @target clean_data = clean(CSV.read(raw_file, DataFrame))
    @target grid       = vec([(alpha = a, depth = d) for a in (0.1, 0.5), d in 2:4])
    @target fits       = fit_model(clean_data, grid)    pattern = grid
    @target summary    = summarize(fits)
end
```

Each `@target`'s dependencies are the targets its expression refers to: `clean_data`
depends on `raw_file`, and `summary` on `fits`. `pattern = grid` runs `fit_model` once per
element of `grid` (see [Branching](guide/branching.md)).

Run it from the project root:

```julia
using Targets
tar_make()                    # builds everything
tar_make()                    # builds nothing: everything is up to date
tar_read(:summary)            # the stored value
@tar_load clean_data fits     # clean_data = tar_read(:clean_data), ...
tar_outdated()                # what would rebuild, and why
tar_status()                  # each target and its status, in colour
```

Edit `clean`, and the next `tar_make()` rebuilds `clean_data` and whatever depends on it. If
`clean_data` comes out the same as before, nothing downstream rebuilds.

The same pipeline can be written with plain functions instead of macros. A target's
dependencies are then the argument names of its function:

```julia
tar_pipeline(
    target(:raw_file, () -> "data/raw.csv"; format = :file),
    target(:clean_data, raw_file -> clean(CSV.read(raw_file, DataFrame))),
    target(:grid, () -> vec([(alpha = a, depth = d) for a in (0.1, 0.5), d in 2:4])),
    target(:fits, (clean_data, grid) -> fit_model(clean_data, grid); pattern = :grid),
    target(:summary, fits -> summarize(fits)),
)
```

## Where next

- [Declaring pipelines](guide/pipelines.md): the macro and function forms, fragments, static
  branching and replication.
- [Branching](guide/branching.md): static against dynamic branching, and branching over
  several parameters.
- [Kinds of targets](guide/target_kinds.md): values, storage formats, files, URLs and Quarto
  reports.
- [Running builds](guide/builds.md): selecting targets, parallel jobs, errors and seeds.
- [What triggers a rebuild](guide/rebuilds.md): how changes are detected, and cues.
- [Inspecting a pipeline](guide/inspecting.md): reading results and viewing the graph.
- [Large pipelines](guide/large_pipelines.md): keeping loads and reads fast.
- [API reference](api.md).
