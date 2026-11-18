# Inspecting a pipeline

## Reading results

```julia
tar_read(:summary)              # the stored value
@tar_load clean_data fits       # assign each to a variable of the same name
```

[`tar_read`](@ref) and [`@tar_load`](@ref) return the last stored value even when a target
is outdated, with a warning. For the project's own store the check uses `_targets.jl`, so
code edits count. Pass `on_outdated = :error` to make that an error, or `:ignore` to skip the
check, which also makes reads much faster on large pipelines (see
[Large pipelines](large_pipelines.md)). `@tar_load` checks all of its targets together.

For a file target the value is its path (or paths); for a branching target it is the vector
of its branch values.

## Project preferences

Set defaults for a project in its `LocalPreferences.toml`:

```toml
[Targets]
on_outdated = "error"            # or "warn" (default), "ignore"
store = "/scratch/me/_targets"   # the default store, relative to the project root
jobs = "auto"                    # tar_make's default jobs: a number, or "auto"
on_error = "continue"            # or "stop" (default): tar_make's default keep_going
```

## Helpers

| Function | Does |
| --- | --- |
| [`tar_outdated`](@ref)`()` | Targets that would rebuild, with reasons (conservative: everything downstream of an outdated target counts) |
| [`tar_manifest`](@ref)`()` | One row per target: name, dependencies, format, pattern and options |
| [`tar_meta`](@ref)`()` | The stored metadata of every target and branch |
| [`tar_list`](@ref)`(; names, descendants)` | Target names by section (constants, input files, computations, output files), per connected part of the graph, in build order |
| [`tar_status`](@ref)`(; names, descendants)` | `tar_list` with each target's status, coloured in the terminal: up to date (green), outdated with its reason (yellow), errored (red), not built (blue) |
| [`tar_dot`](@ref)`(; names, descendants)` | Graphviz DOT text, optionally of a sub-graph, coloured by status; renders as SVG in notebooks if Graphviz is installed, and `write("p.dot", tar_dot())` saves it |
| [`tar_visnetwork`](@ref)`(; names, descendants)` | A plot of the graph (needs a Makie backend) |
| [`tar_picker`](@ref)`()` | At the REPL: pick targets in a fuzzy finder, then run `tar_make`, `tar_invalidate`, `tar_status` or `tar_visnetwork` on them |

`names` restricts a view to those targets and their ancestors; `descendants = true` adds
everything downstream of them.

## Plotting the graph

[`tar_visnetwork`](@ref) draws the pipeline with Makie, coloured by status. Load a backend
first:

```julia
using CairoMakie     # a static figure
tar_visnetwork()
```

With GLMakie (a window) or WGLMakie (a browser tab) the figure is interactive by default:
drag targets (shift-click or shift-drag to select several and move them together), pan and
zoom, and use the side panel to hide targets by kind or status, hide the selection, show
only the selection, or bring back everything upstream or downstream of the targets still
shown. `interactive = false` gives a static figure.
