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
- `fresh = true` builds in a new Julia process, so nothing from your session can affect
  the results (see [Fresh builds](#Fresh-builds)). Use it for final and CI runs.
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

## Fresh builds

`tar_make()` already loads `_targets.jl` into a new module on every call, so variables
left over from an earlier load of the script cannot leak in. Everything else in your
session is shared with the build, though, and some of it can change results without
changing anything on disk:

- **Packages are loaded once per session.** `using MyAnalysis` in `_targets.jl` reuses the
  copy your session already loaded. Without Revise, edits made since then are not running.
  `tar_make` notices edited files that its targets' code reaches, and stops (see the
  warning above), but not every way session code can differ from the files.
- **Session state.** Global variables you changed at the REPL
  (`MyAnalysis.SETTINGS[:n] = 10`), methods you defined or overwrote there, the working
  directory, `ENV` and settings such as `BLAS.set_num_threads` all affect the targets that
  use them, but are not part of any hash.
- **Packages the script does not load.** A package loaded in your session, but not by
  `_targets.jl`, can still change what targets do, by adding methods or enabling a package
  extension. The build then works in your session but not anywhere else.

`tar_make(fresh = true)` avoids all three. It starts a new Julia process with the same
project and the same number of default threads, without your `startup.jl` file, and runs
`tar_make` there with the same options. The new process loads everything from the files on
disk, so the results depend only on the project. Its log is printed as usual, and the
[`BuildSummary`](@ref) is returned to your session. Values go to the same store, so
`tar_read` in your session sees them.

The price is starting Julia and loading and compiling your packages on every call, from
seconds to minutes, so use it for final and CI runs rather than while iterating. It also
needs the pipeline to come from a script (not a `Pipeline` value), and it cannot be
combined with `executor`, since workers belong to the session that started them.

## Parallel builds

```julia
tar_make(jobs = 4)                  # up to 4 targets and branches at once, as Julia tasks
tar_make(jobs = :auto)              # one job per thread of the default threadpool
tar_make(executor = DistributedExecutor(workers()))   # on worker processes
```

`jobs` counts tasks, not threads: CPU-bound targets only run in parallel when Julia has
threads (`julia -t 8`). A target's `slots` option says how much of the build's capacity it
occupies, and `deployment = :main` keeps a target in your session's task. [Parallel and
distributed builds](parallel.md) explains how jobs, tasks, threads, slots and workers relate,
and what targets must avoid when they run concurrently.

## Errors and retries

By default an error stops the build: nothing new starts, jobs that are already running
finish and are recorded, and then the error is rethrown. Interrupting a build (Ctrl-C)
stops it the same way, except that results arriving after the interrupt are not recorded;
running jobs cannot be killed, so interrupt again to stop waiting for them. A target's
`error` option changes what its failure does:

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
