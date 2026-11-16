# Running builds

[`tar_make`](@ref) loads `_targets.jl` and builds the targets that are outdated, in
dependency order:

```julia
tar_make()                          # everything that is outdated
tar_make(names = [:model])          # model and everything it depends on
tar_make(force = true)              # rebuild the selection whatever its status
tar_make(keep_going = true)         # carry on with independent targets after a failure
tar_make(fresh = true)              # build in a new Julia process
```

- `names` takes target names; a [`tar_map`](@ref) template name stands for all of its
  targets.
- `fresh = true` builds in a new Julia process, so no stale session state can leak in. Use
  it for final and CI runs.
- To see what a build would do without building, call [`tar_outdated`](@ref) with the same
  `names`.

`tar_make` returns a [`BuildSummary`](@ref) listing what was built, skipped, errored or
blocked. It logs one line per finished target to the terminal and to
`_targets/log/progress.log`: `✔ target 1.2s (reason)` in green, `✖ target: error` in red.
In a terminal, the targets still running stay pinned below the log with a spinner;
`progress = :lines` prints a `▶ target (reason)` line at each start instead.

Values are held in memory only while a later target in the run still needs them, so memory
use follows the width of the pipeline rather than its length.

!!! warning "Editing code without Revise"
    If you edit a source file without Revise and without restarting, the session still runs
    the old code while the files on disk have changed. `tar_make` then stops with an
    explanation rather than record the wrong hashes. Load Revise, restart, or use
    `fresh = true`.

## Parallel builds

With `jobs = n`, up to `n` independent targets and branches run at once, each as a Julia
task. Targets on the longest remaining path (by their last build times) start first.

```julia
tar_make(jobs = 4)
tar_make(jobs = :auto)              # one job per thread of the default threadpool
```

`jobs` counts tasks, not threads: more jobs than threads still overlap targets that wait on
I/O, but CPU-bound targets only run in parallel when Julia has threads (`julia -t 8`). Set
a default for a project in `LocalPreferences.toml`:

```toml
[Targets]
jobs = "auto"   # or a number such as 4
```

Per-target options control how a target shares the jobs:

- `slots = 2` (or `:all`) makes a target occupy several of the `n` jobs while it runs, for
  targets that are parallel themselves. [`tar_slots`](@ref) returns how many it was given,
  e.g. `OhMyThreads.tmap(f, xs; ntasks = tar_slots())`.
- `deployment = :main` runs a target in the task that called `tar_make`, never at the same
  time as another `:main` target, for code that is not safe to run concurrently.

Concurrent targets share the process: they must not `cd`, change `ENV`, or mutate their
arguments. `tar_make(check_mutation = true)` checks the last of these, at a cost, so turn it
on in tests and CI.

To run targets on other processes or machines, pass a
[`DistributedExecutor`](@ref) (with `using Distributed`):

```julia
using Distributed
addprocs(4)
tar_make(executor = DistributedExecutor(workers()))
```

Each worker loads `_targets.jl` itself, and the store must be on a filesystem the workers
share with the main process.

## Errors and retries

By default an error stops the build, after running jobs have finished, and is rethrown. A
target's `error` option changes what its failure does:

| `error` | A failure |
| --- | --- |
| `:stop` (default) | stops the build, unless `tar_make(keep_going = true)` |
| `:continue` | never stops the build, but blocks the target's descendants |
| `:null` | gives consumers `nothing`, so they still run |
| `:trim` | (branching targets) leaves the failed branches out of the target's value |

In every mode the failed target is retried on the next build. `retries = n` reruns a
failing target up to `n` more times within one build, waiting `retry_delay` seconds between
attempts, for flaky I/O.

To investigate a failure:

```julia
tar_errored()               # what failed, with the error and when
tar_traceback(:model)       # the stack frames of its last failure, from its own code inward
tar_workspace(:model)       # the arguments it failed with, as a NamedTuple
@tar_workspace model        # the same, assigned to variables named after them
tar_rerun(:model)           # call its current function on those arguments, in this session
```

## Random seeds

Every target runs with its own seed, derived from the pipeline seed and the target's name,
so results are the same whatever the order or parallelism of the build. Set the pipeline
seed with `@pipeline seed = 2026 begin ... end` or `tar_pipeline(...; seed = 2026)`;
changing it rebuilds every seeded target. A target's `seed` option pins its seed to an
integer, or `nothing` leaves the session's random number generator alone.
[`tar_seed`](@ref) returns the running target's seed, for creating your own random stream
(e.g. `StableRNG(tar_seed())`).

## Following a build from another session

```julia
tar_progress()      # the latest status of every target and branch of the latest run
tar_poll()          # print a one-line summary every few seconds until the run finishes
```
