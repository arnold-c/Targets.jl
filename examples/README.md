# Examples

Two small projects for trying Targets by hand, a scripted walkthrough of each,
and a check that hashes survive a Julia upgrade. Everything lives in
[`demo.jl`](demo.jl) and [`version_check.jl`](version_check.jl).

| Project | Directory (git-ignored) | Shows |
| --- | --- | --- |
| Core demo | `examples/.demo/` | `@pipeline`, file targets, change detection, early cutoff, dynamic and static branching, the DAG plot |
| Feature demo | `examples/.demo-features/` | seeds, concurrent jobs and slots, storage formats, pattern combinators, `tar_rep`, error modes, retries, workspaces, tracebacks and warnings, cues, progress events, worker processes |
| Version check | `examples/.version_check/` | hashes that do not change with the Julia version |

Each project directory is a normal Julia project with its own environment, a
`_targets.jl` pipeline and a `_targets/` store. Delete the directory to start
over. All commands below are run from the repository root unless they say
otherwise.

## Quick check: the scripted walkthroughs

```sh
julia --project=. -t 4 examples/demo.jl                  # both walkthroughs
julia --project=. -t 4 examples/demo.jl --distributed    # also build on 2 workers
```

Each walkthrough runs in a temporary directory, prints `✓` or `✗` per step,
and exits with status 1 if any step failed. They don't need the interactive
projects set up.

---

## 1. Core demo (v0.1 features)

### Set up

```sh
julia --project=. -e 'include("examples/demo.jl"); demo_setup()'
```

This writes `examples/.demo/` and gives it an environment with this
repository's Targets and three Makie backends: CairoMakie (static figures),
GLMakie (an interactive window) and WGLMakie (an interactive browser tab).
The project contains:

- `data/raw.csv`: an input file (`1.0 2.0 NaN 4.0`)
- `analysis.jl`: helpers (`clean`, `score`, `summarize`, ...) and a `const SCALE`
- `_targets.jl`: the pipeline:
  - `raw_file` (a file target), then `raw`, `cleaned`
  - `grid`, a pattern target with three elements
  - `scores`, branching over `grid`, then `report`
  - `shifted_low/high` and `shift_summary_low/high`, from `tar_map`
  - `shifted_total`, from `tar_combine`

### Run it interactively

```
cd examples/.demo
julia --project=.
julia> using Targets, CairoMakie   # or GLMakie, or WGLMakie
julia> tar_make()          # builds all 11 targets
julia> tar_make()          # "up to date" for everything
julia> tar_read(:report)   # (n = 3, total = 33.6)
julia> tar_outdated()      # empty
julia> print(tar_dot())    # Graphviz DOT of the DAG
julia> tar_visnetwork()    # the DAG as a Makie figure, coloured by status; with
                           # GLMakie or WGLMakie, drag targets, pan and zoom
```

Pick the backend in the REPL: `_targets.jl` loads none, because loading a
backend makes it the active one, and a `using CairoMakie` there would
override a GLMakie or WGLMakie chosen in the REPL whenever the pipeline is
loaded. To have `_targets.jl` load one anyway, pass it by name, e.g.
`demo_setup(; makie = :GLMakie)` or `write_demo(; makie = :WGLMakie)`; it is
kept when the files are regenerated, and `makie = nothing` removes it.

### Make edits

`write_demo` regenerates the project with one thing changed. Call it from the
same REPL, then look at `tar_outdated()` before running `tar_make()`. Each
call resets the other knobs to their defaults, so repeat earlier changes if
you want to keep them.

```
julia> include("../demo.jl")
julia> write_demo(; scale = 4)
julia> tar_outdated()
julia> tar_make()
```

| Edit | What it changes | Expect `tar_make()` to rebuild |
| --- | --- | --- |
| `note = "# a comment"` | adds a comment and moves every line | nothing |
| `discount = "x + 0"` | a helper two calls deep from `scores`, same results | `scores` only; `report` is kept (early cutoff) |
| `scale = 4` | a `const` that `score` reaches | `scores`, `report` |
| `grid = "[0.1, 0.5, 1.0, 2.0]"` | adds an element to the pattern | `grid`, one new `scores` branch, `report` |
| `shifts = "(low = 1, high = 3)"` | one `tar_map` value | `shifted_high`, `shift_summary_high`, `shifted_total` |
| `shifts = "(low = 1, mid = 2, high = 2)"` | adds a `tar_map` value | the new `*_mid` targets, `shifted_total` |
| `data = "1.0 2.0 NaN 4.0 8.0"` | the input file | everything downstream of `raw_file` (not `grid`) |
| `touch("data/raw.csv")` | modification time only | nothing |

### The scripted version

`walkthrough()` makes these edits in sequence, starting from defaults, and
checks the exact set of targets rebuilt each time:

| Step | Expected `built` |
| --- | --- |
| first build | all 11 targets |
| second build | none |
| comment added | none |
| helper edited, outputs unchanged | `scores` (early cutoff stops `report`) |
| global edited | `scores`, `report` |
| one element added to the pattern | `grid`, `scores`, `report` |
| static branch value changed | `shifted_high`, `shift_summary_high`, `shifted_total` |
| static branch added | `shifted_mid`, `shift_summary_mid`, `shifted_total` |
| input file edited | `raw_file` and everything after it, except `grid` |
| input file touched, same bytes | none |

It ends with `All steps behaved.`

---

## 2. Feature demo (v0.2 features)

### Set up

```sh
julia --project=. -e 'include("examples/demo.jl"); features_setup()'
```

This writes `examples/.demo-features/` with an environment (Targets,
CairoMakie, GLMakie, WGLMakie, Distributed), a pipeline in `_targets.jl` and helpers in
`features.jl`. It also creates two **marker files**, so that the first build
shows the error handling:

- `fail_10`: makes the `fragile_fits` branch for element `10.0` fail
- `fail_maybe`: makes `maybe` fail

The pipeline has one target per feature:

| Target | Feature |
| --- | --- |
| `mus`, `sizes` | pattern targets (`[0.0, 10.0, 20.0]`, `[1, 2]`) |
| `draws` | seeded random branches over `mus` (`simulate` adds `NOISE * randn()`) |
| `combos` | `pattern = Cross(:mus, :sizes)`: 6 branches |
| `paired` | `pattern = Map(Head(:mus, 2), :sizes)`: 2 branches |
| `sampled` | `pattern = Sample(:mus, 2)`: 2 branches picked with the target's seed |
| `reps` (+ `reps_batch`, `reps_batches`) | `tar_rep(...; batches = 2, reps = 5)`: 10 replications |
| `fragile_fits` | `error = :trim`: failed branches are left out |
| `maybe`, `uses_maybe` | `error = :null`: the consumer receives `nothing` |
| `flaky` | `retries = 2`: fails on its first attempt only |
| `noisy` | logs a warning, which is recorded in its metadata |
| `exclusive` | `slots = :all`: returns `tar_slots()` |
| `on_main` | `deployment = :main`: runs in the calling task |
| `cached_total` | `cue = Cue(code = false)`: ignores edits to the code it calls |
| `fast` | `format = :jls` (Serialization) |

### Run it interactively

Start Julia with threads, so that concurrent targets really run in parallel.
`jobs = 4` also works on one thread, but then the tasks only take turns.

```
cd examples/.demo-features
julia --project=. -t 4
julia> using Targets, GLMakie   # or CairoMakie, or WGLMakie
julia> tar_make(; jobs = 4)
```

What to expect from the first build:

- **Log:** about 17 targets built, `✖ maybe: no value today`, a
  `↻ flaky attempt 1 failed, retrying` line, an `only 3 values` warning, and a
  summary ending in `1 errored, 0 blocked, 1 with warnings`.
- **Summary:** `errored = [:maybe]` and `trimmed = Dict(:fragile_fits => [...])`.
- **Build order:** the log lines interleave, because up to four targets and
  branches run at once.

Look around:

| Call | Expect |
| --- | --- |
| `tar_read(:uses_maybe)` | `"no value"` (with a warning that it isn't up to date, because `maybe` failed) |
| `tar_read(:fragile_fits)` | `[0.0, 200.0]`: the `10.0` branch was trimmed |
| `tar_read(:flaky)` | `2`: succeeded on the second attempt |
| `tar_read(:exclusive)` | `4`: all four slots of `jobs = 4` |
| `tar_read(:combos)` | `[0.0, 0.0, 10.0, 20.0, 20.0, 40.0]` |
| `tar_read(:reps)` | 10 random numbers |
| `tar_errored()` | rows for `fragile_fits`, its failed branch, and `maybe` |
| `tar_traceback(:maybe)` | the frames of `error`, `maybe_value` (features.jl) and the target's lambda (_targets.jl), with no Targets internals |
| `tar_workspace(:maybe)` | `NamedTuple()`: the saved arguments (`maybe` has none) |
| `tar_rerun(:maybe)` | throws `no value today` again, in your session, with the same seed |
| `tar_meta()` | the `noisy` row has `warnings = ["only 3 values"]` |
| `tar_progress()` | the last run's events, one row per target and branch |
| `tar_visnetwork()` | the DAG; `maybe` and `fragile_fits` coloured as errored (rearrange it with GLMakie or WGLMakie) |

### Fix the failures

```
julia> rm("fail_10"); rm("fail_maybe")
julia> tar_make(; jobs = 4)
```

Expect `built = [:fragile_fits, :maybe, :uses_maybe]`: only the failed branch,
the failed target and its consumer. Everything else is up to date.
`tar_read(:fragile_fits)` is now `[0.0, 100.0, 200.0]` and `tar_outdated()` is
empty.

### Make edits

```
julia> include("../demo.jl")
```

Each `write_features` call rewrites the project. As with `write_demo`, knobs
you leave out go back to their defaults.

| Edit | Expect |
| --- | --- |
| `write_features(; seed = 1)` | `tar_outdated()` says `:seed_changed` for every target without upstream targets, and `:upstream_outdated` for the rest. `tar_make()` rebuilds all 18 targets, and the random values change |
| `write_features(; seed = 1, total = "sum(xs) + 0")` | nothing rebuilds: `cached_total`'s cue ignores code edits |
| `write_features(; seed = 1, fast_format = :jld2)` | `tar_outdated()` is `[(name = :fast, reason = :format_changed)]`; only `fast` rebuilds, now stored as `fast.jld2` |
| `write_features(; seed = 1, noise = 2.0)` | `draws` and `noisy` rebuild: `NOISE` is a `const` that `simulate` reaches |
| `tar_make(; jobs = 4, check_mutation = true)` | nothing rebuilds and no error: no target modifies its inputs |

To see a failure again, `touch("fail_maybe")` and run `tar_make(; force = true)`.

### Run on worker processes

From the same REPL:

```
julia> using Distributed
julia> addprocs(2; exeflags = "--project=$(Base.active_project())")
julia> before = tar_read(:draws)
julia> tar_make(; executor = DistributedExecutor(workers()), force = true)
julia> tar_read(:draws) == before   # true: the seeds don't depend on where a target runs
julia> tar_make(; executor = DistributedExecutor(workers()))   # nothing to build
```

Workers load `_targets.jl` themselves. The build first checks that they can
see the store and compute the same code hashes as your session, and refuses
to run otherwise. A worker's warnings are printed as `From worker N: ...`.

### The scripted version

`features_walkthrough()` (or `features_walkthrough(; distributed = true)`)
does all of the above in a temporary directory, as 26 checks (27 with
workers):

| Group | Checks |
| --- | --- |
| first build (`jobs = 4`, with failures) | `errored == [:maybe]`; `:null` gives `"no value"`; `:trim` gives `[0.0, 200.0]`; retry gives `2`; `slots = :all` sees 4; `Cross`, `Map(Head(...))`, `Sample` and `tar_rep` sizes; `fast.jls` exists |
| debugging | `tar_errored` lists `maybe`; the workspace is saved; `tar_rerun` reproduces `no value today`; the traceback mentions `maybe_value`; the warning is recorded |
| after fixing | exactly `fragile_fits`, `maybe`, `uses_maybe` rebuild; the trimmed branch is back; nothing is outdated |
| seeds | a separate 1-job build gives the same `draws` and `reps`; a new seed is `:seed_changed` and rebuilds the seeded targets |
| cues and formats | `Cue(code = false)` ignores a helper edit; a format change is `:format_changed` and rebuilds only `fast` |
| progress | `tar_progress()` shows `fast` as built |
| `check_mutation` | a target that `push!`es onto its input is caught |
| workers (optional) | a build on two workers gives the same seeded `draws` |

It ends with `All feature checks passed.` The deliberate `only 3 values`
warning is kept off the console here (it is still recorded); in the REPL you
will see it.

**Not covered:** URL targets (`format = :url`), because they need an HTTP
server. Their tests in `src/urls.jl` use a local one.

---

## 3. Version check

`version_check.jl` builds the core demo once, then rebuilds it under other
Julia versions against the same store (`examples/.version_check/`). With
juliaup:

```sh
julia +1.10 examples/version_check.jl --reset    # reference build
julia +1.11 examples/version_check.jl            # must build nothing
julia +release examples/version_check.jl         # must build nothing
```

Each run prints the targets built and skipped, and per target how its code was
hashed:

- **`source`:** stable across Julia versions.
- **`lowered`:** not stable, so a version change may rebuild that target once.
  This is reported as expected, not as a failure.

A later run exits with status 1 if any source-hashed target was rebuilt.
Set `TARGETS_EXAMPLE_DIR` to put the store somewhere else.
