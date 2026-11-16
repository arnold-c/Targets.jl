# Running on a Slurm cluster

[SlurmClusterManager.jl](https://github.com/JuliaParallel/SlurmClusterManager.jl) starts
`Distributed` workers inside a Slurm allocation, and a [`DistributedExecutor`](@ref) runs
the pipeline's jobs on them. Read [Parallel and distributed builds](parallel.md) first:
everything there about workers applies here.

## How it fits together

You ask Slurm for an allocation with `sbatch` (a batch job) or `salloc` (an interactive
one). Inside it:

- One Julia process runs `tar_make`. This is the *main process*: it loads `_targets.jl`,
  decides what is outdated, sends jobs to workers and records the results. In a batch job
  it runs on the first node of the allocation, outside the Slurm tasks; with `salloc` it
  runs wherever the shell `salloc` opens is (on many clusters, the login node).
- `addprocs(SlurmManager())` starts one worker per Slurm task (`--ntasks`), with `srun`,
  on whichever nodes Slurm gave the job. Each worker uses the cores of its task
  (`--cpus-per-task`).
- Each worker loads `_targets.jl` itself, runs the jobs it is sent, and writes their values
  to the store. The store must therefore be on a filesystem that every node shares, such as
  your home or scratch directory; the build checks this before it starts.

So `--ntasks` is the number of workers, which is the number of targets that run at once,
and `--cpus-per-task` is the number of threads each worker can give a target that is
parallel itself.

`SlurmManager()` takes no Slurm options: workers get exactly the resources of the
allocation, so request them with `sbatch` or `salloc`. It errors outside an allocation. If
workers are slow to start (a busy shared filesystem), raise its one-minute limit with
`SlurmManager(launch_timeout = 300)`.

## Setting up the project

Add the packages to the project that holds `_targets.jl`:

```julia
import Pkg
Pkg.add(["Distributed", "SlurmClusterManager"])
```

Workers use the same project, load path and depot as the main process, so they find the
same package versions. Before the first job, install and precompile the project once, so
that the workers do not all precompile at the same time when they start:

```sh
julia --project=. -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'
```

If the login nodes have a different CPU from the compute nodes, Julia may compile the
packages again on the compute nodes. Running the precompile step in a short job on a
compute node avoids this.

Put the store on a shared filesystem. It is `_targets/` in the project by default, which is
shared if the project is; to keep it elsewhere, such as on scratch, set the `store`
preference in the project's `LocalPreferences.toml`:

```toml
[Targets]
store = "/scratch/me/my_analysis/_targets"
```

## A batch job

A script that starts the workers and builds the pipeline, next to `_targets.jl`:

```julia
# make.jl
using Distributed, SlurmClusterManager
using Targets

threads = get(ENV, "SLURM_CPUS_PER_TASK", "1")
addprocs(SlurmManager(); exeflags = "--threads=$threads")

tar_make(executor = DistributedExecutor(workers()))
```

A batch script that requests 16 workers with 4 cores each:

```sh
#!/bin/bash
#SBATCH --job-name=targets
#SBATCH --ntasks=16              # workers: how many targets run at once
#SBATCH --cpus-per-task=4        # cores, and threads, for each worker
#SBATCH --mem-per-cpu=4G
#SBATCH --time=12:00:00
#SBATCH --output=targets-%j.log

julia --project=. make.jl
```

Submit it from the project root (the batch job starts in the directory it was submitted
from):

```sh
sbatch make.sbatch
```

The log of the build, and the output of the workers, go to `targets-%j.log`. A batch job
has no terminal, so the build prints one line per finished target rather than the live
footer.

If workers get fewer cores than `--cpus-per-task` (some Slurm versions do not pass it on
from `sbatch` to `srun`), add `export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK` before the
`julia` line.

## Following a build

From a Julia session on a login node, started in the project (`julia --project=.`), read
the progress the build writes to the shared store:

```julia
using Targets
tar_poll()          # a one-line summary every few seconds, until the build finishes
tar_progress()      # the latest status of every target and branch
```

Once the job has finished, `tar_read`, `tar_status` and the other helpers work as usual from
any node that sees the store.

## Interactive allocations

To work interactively on compute nodes, ask for an allocation with `salloc`, start Julia in
the shell it opens, and build from the REPL:

```sh
salloc --ntasks=8 --cpus-per-task=4 --time=2:00:00
julia --project=.
```

```julia
using Distributed, SlurmClusterManager, Targets
addprocs(SlurmManager(); exeflags = "--threads=$(ENV["SLURM_CPUS_PER_TASK"])")
tar_make(executor = DistributedExecutor(workers()))
```

Workers keep the code they loaded (see [Worker processes](parallel.md#Worker-processes)).
After editing `_targets.jl` or your functions, replace them:

```julia
rmprocs(workers())
addprocs(SlurmManager(); exeflags = "--threads=$(ENV["SLURM_CPUS_PER_TASK"])")
```

## Choosing resources

- **Targets that are not parallel themselves**: one core per task (`--cpus-per-task=1`) and
  as many tasks as targets you want running at once.
- **Targets that are parallel themselves**: give each task several cores, and have those
  targets start their own tasks sized by `Threads.nthreads()`. Each worker runs one job at a
  time; see [Threads on workers](parallel.md#Threads-on-workers).
- **Memory**: each worker gets `--mem-per-cpu` times `--cpus-per-task`, so size it for the
  largest target a worker builds. The main process also loads every argument it sends to a
  worker, so it needs memory for the largest inputs.
- **Short targets**: each job's arguments travel from the main process to a worker, and its
  value through the store. For many targets that take less than a second, that overhead
  dominates; branch over batches of work instead (`tar_rep` batches replications this
  way).
- **`deployment = :main` targets** run in the main process, on the first node, so give
  them small inputs, or the main process enough cores and memory.

## Time limits and resubmitting

Each target's result is recorded as soon as it finishes. If the job reaches its time limit
or is cancelled, the targets that had finished are kept, and the next build only runs what
is left (the targets that were running start again). So a long pipeline can be built over
several jobs: submit the same script again, or chain jobs with
`sbatch --dependency=afterany:<jobid> make.sbatch`.

Workers stop when the main process exits, so nothing is left running when the build ends or
fails.
