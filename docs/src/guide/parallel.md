# Parallel and distributed builds

By default [`tar_make`](@ref) builds one target at a time, in your session. Two options
let it do more at once:

- `jobs = n` runs up to `n` targets and branches at the same time as Julia tasks in your
  session.
- `executor = DistributedExecutor(pids)` runs them on other Julia processes, the
  *workers*, which can be on other machines.

Both work with any pipeline: switching between them does not change any target, any
result or what counts as outdated. Every target runs with its own
[seed](builds.md#Random-seeds), so results also do not depend on how many targets ran at
once or where.

## Jobs, tasks, threads, slots and workers

These words mean different things, and the settings below each control one of them:

| Term | What it is | Set with |
| --- | --- | --- |
| **job** | One piece of work for the build: one target, or one branch of a branching target | the pipeline |
| **task** | Julia's unit of concurrent work, sometimes called a *green thread*: cheap to create, run by Julia on one of its threads, and able to pause (for I/O, `sleep`, a lock or an external program) so another task runs on the same thread | `Threads.@spawn`; Targets makes one per job |
| **thread** | An operating-system thread that runs tasks, one at a time. Julia's *default threadpool* has a fixed number of them, chosen at startup | `julia -t 8` or `JULIA_NUM_THREADS` |
| **slot** | One unit of a build's capacity, used only to decide what may start | `jobs = n` (`n` slots); `slots` per target |
| **worker** | A separate Julia process, with its own memory, threads, loaded packages and global variables, on this machine or another | `addprocs`, ClusterManagers.jl, SlurmClusterManager.jl; [`DistributedExecutor`](@ref) |

They relate like this:

- **A build has a number of slots.** With `jobs = n` it has `n`. With a
  `DistributedExecutor`, it has one per worker, or `slots_per_worker` per worker. When
  `executor` is given, `jobs` is ignored.
- **Each job occupies slots while it runs**: one by default, or the target's `slots`.
  A job starts only when its slots are free (or nothing else is running).
- **Each running job is a task.** With `jobs = n`, the task runs in your session and Julia
  puts it on any free thread of the default threadpool. With workers, the job is sent to a
  worker and runs there as a task.
- **Threads are what run tasks in parallel.** Slots and tasks only decide what is
  *started*; how many tasks make progress at the same instant is limited by the number of
  threads (for workers, see [Threads on workers](#Threads-on-workers)).

The build itself (deciding what is outdated, starting jobs, and recording their results)
runs in the task that called `tar_make`. Jobs only compute their value and write it to the
store; everything else waits for them to report back. When the build has a single slot
(`jobs = 1`, the default), jobs run directly in that task, one after another, and no tasks
are created.

## Jobs and threads

```julia
tar_make(jobs = 4)
tar_make(jobs = :auto)        # one job per thread of the default threadpool
```

`jobs` counts tasks, not threads. A task keeps its thread until it pauses, so:

- **More jobs than threads** still helps targets that mostly wait: downloads, reading and
  writing files, external programs, Quarto renders. While one waits, another runs.
  CPU-bound targets only take turns, so they finish no sooner than one at a time.
  `jobs = 4` in a session started without `-t` behaves like this.
- **No more jobs than threads** lets CPU-bound targets run in parallel. Threads not used
  by jobs are available to tasks that targets start themselves.
- `jobs = :auto` is `Threads.nthreads(:default)`: the number of default threads, so `1`
  when Julia was started without `-t`.

To run CPU-bound targets in parallel, start Julia with threads, e.g. `julia -t 8`, and
use `jobs = 8` or `jobs = :auto`. A project can make this the default in its
`LocalPreferences.toml`, which `tar_make` reads only when `jobs` and `executor` are not
given:

```toml
[Targets]
jobs = "auto"   # or a number such as 4
```

When several jobs are ready, those on the longest remaining path through the pipeline (by
the targets' last build times) start first, so that the build as a whole finishes sooner.
With one slot, targets are built in the pipeline's order.

Jobs run on any thread, and may move between threads while they run, so target code must
not rely on `Threads.threadid()`.

The progress footer is redrawn from Julia's interactive threadpool when there is one (as
with `julia -t 8,1`), so it keeps updating even when CPU-bound targets occupy every
default thread.

## Slots

A target's `slots` option (default `1`) is how many of the build's slots it occupies while
it runs. Use it for targets that are parallel themselves, so that the build leaves room for
them:

```julia
@target posterior = sample_chains(model, data)  slots = 4
@target simulation = run_simulation(settings)   slots = :all   # runs with nothing else
```

- A number larger than the build's slots counts as all of them; `:all` is all of them.
- Jobs start strictly in priority order: when the next job's slots are not free, the build
  waits for running jobs to finish instead of starting smaller jobs behind it. So a
  `slots = :all` target waits for everything running to finish, and nothing starts until
  it is done.
- [`tar_slots`](@ref)`()` returns the slots the running target was given, to size its own
  parallelism:

  ```julia
  sample_chains(model, data) =
      OhMyThreads.tmap(k -> sample_chain(model, data, k), 1:4; ntasks = tar_slots())
  ```

**Slots do not limit what a target uses.** They only decide what else the build starts
next to it. Julia cannot confine a task to some of its threads, so a `slots = 1` target
that starts 16 tasks of its own can still use every thread. A target's own tasks share
the default threadpool with the build's jobs; the two levels never deadlock, but together
they can keep more tasks busy than there are slots.

### BLAS threads

Linear algebra libraries (OpenBLAS, MKL) use their own threads, which are neither Julia
threads nor slots. When several BLAS-heavy targets run at once, each can try to use every
core, and they slow each other down. Set `BLAS.set_num_threads(1)` (from `LinearAlgebra`)
in the session or in `_targets.jl` to avoid this. It is a global setting, so Targets does
not change it for you.

## Targets that must not run concurrently

`deployment = :main` runs a target in the task that called `tar_make`, in your session,
whatever the executor:

```julia
@target figure = draw_with_gui_backend(model)  deployment = :main
```

Two `:main` targets never run at the same time. While one runs, the build is busy running
it, so no new jobs start, but jobs that were already running carry on. Use it for code
that is not safe to run concurrently with itself. Code that is unsafe alongside *any*
other use of a library needs every target that uses the library marked `:main`.

`deployment = :main` does not choose a thread. Libraries that must run on Julia's first
thread (such as PythonCall, or some GUI toolkits) are satisfied only when `tar_make` itself
was called from that thread.

## Sharing one process

With `jobs = n`, targets that run at the same time share your session: its memory, its
global variables and its working directory. So target code must not:

- **`cd`**: the project root is the working directory for the whole build; use paths
  relative to it instead.
- **change `ENV`** or other global settings that other targets read.
- **mutate its arguments.** Every consumer of a target receives the same object, so a
  target that modifies its input in place races with the others, and corrupts the value
  for later consumers even with `jobs = 1`. Copy the input first.

`tar_make(check_mutation = true)` hashes every argument before and after each call, and
errors, naming the target and argument, if a target changed one. It is slow, so it is off
by default; turn it on in tests and CI.

More jobs also hold more values in memory at once. Values are released as soon as their
last consumer in the build has finished, and `jobs` is the knob for peak memory.

## Worker processes

A [`DistributedExecutor`](@ref) runs jobs on `Distributed` workers:

```julia
using Distributed
addprocs(4)                                        # four local workers
tar_make(executor = DistributedExecutor(workers()))
```

Workers are worth their start-up cost for long targets that allocate a lot, for libraries
that are not safe to use from several tasks of one process, for code that might crash, and
for using more than one machine. For many small targets, `jobs = n` is cheaper.

### What happens

- **Start-up.** Each worker loads Targets and `_targets.jl` itself, so `_targets.jl` must
  load every package its targets need. Functions are never sent between processes: a
  worker looks targets up by name in its own copy of the pipeline. The build then checks
  that every worker can see the store, and that every worker computes the same code hashes
  as your session, and refuses to start otherwise.
- **Workers keep what they loaded.** A worker loads `_targets.jl` once and reuses it in
  later builds, and it keeps the packages it loaded. After editing `_targets.jl` or your
  functions, start new workers (`rmprocs(workers()); addprocs(4)`); otherwise the
  start-up check reports the targets whose code differs.
- **Each job.** Your session sends the job's arguments to a worker (a copy, so large
  inputs cost transfer time). The worker runs the target and writes the value to the store
  itself, and sends back only its hash and record. Your session alone writes the
  metadata; consumers that need the value load it from the store.
- **The store must be on a filesystem that every worker shares** with your session, such
  as a cluster's shared home or scratch directory.
- `deployment = :main` targets still run in your session.

### Slots on workers

The build has `slots_per_worker` slots per worker (default 1), and each job goes to the
worker with the most free slots. A job always runs on a single worker, so it is given at
most `slots_per_worker` slots there (that is what `tar_slots()` returns). A target with
more `slots` than that still occupies them in the build, which keeps other jobs from
starting: a `slots = :all` target waits for every worker to finish its jobs, then runs alone
on one of them.

### Threads on workers

Workers start with one thread unless you give them more. Distributed runs every job a
worker receives as a task tied to one thread, so the jobs running on one worker take turns,
however many threads it has. In practice:

- **For targets that are not parallel themselves**, use one slot per worker (the default)
  and as many workers as you want targets running at once.
- **For targets that are parallel themselves**, give workers threads, and let those targets
  start their own tasks, which can use all of the worker's threads:

  ```julia
  addprocs(4; exeflags = "--threads=8")
  tar_make(executor = DistributedExecutor(workers()))
  # in a target: OhMyThreads.tmap(f, xs; ntasks = Threads.nthreads())
  ```

  `tar_slots()` is `1` here, since each worker has one slot; size the target's own tasks by
  the worker's threads instead.
- `slots_per_worker > 1` lets a worker overlap jobs that mostly wait (I/O, external
  programs), as more jobs than threads do in your session.

Local workers start with OpenBLAS limited to one thread; pass
`addprocs(n; enable_threaded_blas = true)` for BLAS-heavy targets.

### Environments and machines

Workers started with `addprocs(n)` on this machine use your session's active project. Workers
on other machines, or started by a cluster manager, must load the same project and package
versions, e.g. with `exeflags = "--project=/path/to/project"`. If they load different code,
the start-up check names the targets whose code differs. For Slurm clusters, see
[Running on a Slurm cluster](slurm.md).

### What differs from `jobs = n`

- Each job's arguments are a copy, so a target that mutates them cannot affect other
  targets; `check_mutation` does not check jobs that run on workers.
- A crash (for example a segmentation fault in a C library) ends that worker rather than
  your session, and the target that was running on it fails.
- Warnings from targets are printed as `From worker N: ...`.
- Quarto renders on workers never print their output.
- `fresh = true` cannot be combined with `executor`: workers attach to the session that
  started them, not to the new process a fresh build runs in.

## Summary

| | `jobs = n` (tasks) | `DistributedExecutor` (workers) |
| --- | --- | --- |
| Runs in | your session | separate processes |
| Start-up cost | none | starting workers and loading packages and `_targets.jl` in each |
| Cost per job | small | copying arguments to the worker; values go through the store |
| Memory | shared by every target | separate per worker |
| Code unsafe to run concurrently | needs `deployment = :main` | isolated in its own process |
| A crash | ends the session | ends one worker |
| Machines | one | several, with a shared filesystem |
| CPU parallelism | up to the session's threads | one job per worker, plus each target's own tasks |
