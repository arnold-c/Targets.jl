## Executors run jobs away from the scheduler task and hand their results back.
## Phase 12 adds a distributed executor in a package extension.

"""
    Executor

Where jobs run. An executor has a `capacity` (slots), `submit!(exec, job,
slots)` starts a job, and `take_result!(exec)` waits for the next
[`JobResult`](@ref). `start!` and `stop!` bracket a build. See
[`TaskExecutor`](@ref).
"""
abstract type Executor end

start!(::Executor, ctx) = nothing
stop!(::Executor) = nothing

"""
    TaskExecutor(n)

Run up to `n` slots' worth of jobs at once as tasks in this process (what
`tar_make(; jobs = n)` uses).
"""
struct TaskExecutor <: Executor
    jobs::Int
    results::Channel{JobResult}
end
TaskExecutor(n::Union{Integer, Symbol}) =
    TaskExecutor(resolve_jobs(n), Channel{JobResult}(Inf))

capacity(e::TaskExecutor) = e.jobs
function submit!(e::TaskExecutor, job::Job, slots::Int)
    results = e.results
    Threads.@spawn put!(results, execute_granted(job, slots))
    return nothing
end
take_result!(e::TaskExecutor) = take!(e.results)

"Whether `job` runs in the scheduler task instead of being submitted."
runs_inline(e::Executor, job::Job) = capacity(e) == 1 || job.target.deployment === :main

"""
    DistributedExecutor(pids; script = joinpath(project_root(), "_targets.jl"),
                        slots_per_worker = 1)

Run jobs on `Distributed` worker processes (for example from `addprocs`,
ClusterManagers.jl or SlurmClusterManager.jl), each with `slots_per_worker`
slots. Needs `using Distributed`. Functions are never sent between processes:
each worker loads `script` itself and looks targets up by name, and the build
aborts if a worker's code hashes differ from the main process's. Workers write
objects to the store, which must be on a filesystem they share with the main
process (checked at start-up); only hashes and record fields come back, and the
main process alone writes metadata. Arguments are sent to the worker with the
job. `deployment = :main` targets still run in the main process.
"""
struct DistributedExecutor <: Executor
    pids::Vector{Int}
    script::String
    slots_per_worker::Int
    results::Channel{JobResult}
    used::Dict{Int, Int}                    # slots in use per worker
    assigned::Dict{String, Tuple{Int, Int}} # job key => (worker, slots)
end
function DistributedExecutor(
    pids;
    script::AbstractString = default_script(),
    slots_per_worker::Integer = 1,
)
    isempty(pids) && throw(ArgumentError("DistributedExecutor needs at least one worker"))
    slots_per_worker >= 1 || throw(ArgumentError("slots_per_worker must be positive"))
    return DistributedExecutor(
        collect(Int, pids),
        abspath(script),
        Int(slots_per_worker),
        Channel{JobResult}(Inf),
        Dict{Int, Int}(Int(p) => 0 for p in pids),
        Dict{String, Tuple{Int, Int}}(),
    )
end

capacity(e::DistributedExecutor) = length(e.pids) * e.slots_per_worker
runs_inline(::DistributedExecutor, job::Job) = job.target.deployment === :main

# Implemented by the Distributed extension.
function distributed_start! end
function distributed_submit! end

function require_distributed()
    isempty(methods(distributed_start!)) &&
        error("DistributedExecutor needs `using Distributed`")
end
# Called dynamically: the methods only exist once the extension is loaded.
start!(e::DistributedExecutor, ctx) = (
    require_distributed();
    Base.invokelatest(distributed_start!, e, ctx)
)
submit!(e::DistributedExecutor, job::Job, slots::Int) = Base.invokelatest(
    distributed_submit!,
    e,
    job,
    slots,
)
function take_result!(e::DistributedExecutor)
    r = take!(e.results)
    pid, slots = pop!(e.assigned, r.job.key)
    e.used[pid] -= slots
    return r
end

"The worker with the most free slots."
function pick_worker(e::DistributedExecutor)
    return argmax(pid -> e.slots_per_worker - e.used[pid], e.pids)
end

## The worker side, called through Distributed by the extension.

"A job's result as sent back from a worker: no function, no value."
struct RemoteResult
    value_hash::String
    stored::NamedTuple
    seconds::Float64
    error::Union{Nothing, String}
    traceback::Vector{String}
    retried::Vector{String}
end

"Raised in the main process for a target that failed on a worker."
struct RemoteTargetError <: Exception
    msg::String
end
Base.showerror(io::IO, e::RemoteTargetError) = print(io, e.msg)

"Values computed on a worker stay in the store; consumers load them from there."
struct Unloaded end

const WORKER_PIPELINES = Dict{String, Pipeline}()

worker_pipeline(script::AbstractString) = get!(
    () -> load_pipeline(script),
    WORKER_PIPELINES,
    script,
)

"Command and code hashes of every target, as a worker computes them."
function worker_hashes(script::AbstractString, root::AbstractString)
    p = worker_pipeline(script)
    discovery = Discovery(user_roots(root, p.track))
    return Dict(
        t.name => (something(command_hash(t).hash, ""), code_hash(discovery, t))
        for t in p.targets
    )
end

"Run one job on a worker: the target comes from the worker's own pipeline."
function run_remote(
    script,
    root,
    store_root,
    name,
    key,
    branch,
    args,
    seed,
    reason,
    cmd,
    code,
    dep_hashes,
    pattern_use,
    slots,
)
    t = get_target(worker_pipeline(script), name)
    job = Job(
        t,
        key,
        branch,
        args,
        nothing,
        seed,
        reason,
        cmd,
        code,
        dep_hashes,
        pattern_use,
        Store(store_root),
        root,
    )
    # the worker loaded the script after this function was compiled
    r = cd(() -> Base.invokelatest(execute_granted, job, slots), root)
    failed(r) ||
        return RemoteResult(r.value_hash, r.stored, r.seconds, nothing, String[], r.retried)
    return RemoteResult(
        "",
        (;),
        r.seconds,
        first(sprint(showerror, r.exception), 2000),
        user_frames(r.backtrace),
        r.retried,
    )
end

"The main process's `JobResult` for a worker's answer."
function from_remote(job::Job, rr::RemoteResult)
    rr.error === nothing &&
        return JobResult(
            job,
            Unloaded(),
            rr.value_hash,
            rr.stored,
            rr.seconds,
            nothing,
            nothing,
            rr.retried,
        )
    return JobResult(
        job,
        nothing,
        "",
        (;),
        rr.seconds,
        RemoteTargetError(rr.error),
        nothing,
        rr.retried,
    )
end

@testitem "a distributed build matches a task-based build" begin
    using Distributed
    pids = addprocs(2; exeflags = "--project=$(Base.active_project())")
    try
        mktempdir() do dir
            script = joinpath(dir, "_targets.jl")
            write(
                script,
                """
                tar_pipeline(
                    target(:grid, () -> [1, 2, 3]),
                    target(:draws, grid -> grid + rand(); pattern = :grid),
                    target(:who, () -> Distributed.myid()),
                    target(:total, draws -> sum(draws)),
                    target(:files, () -> (write("out.txt", "x"); "out.txt"); format = :file),
                )
                """,
            )
            # the script uses Distributed too
            write(script, "using Distributed\n" * read(script, String))
            build(store; kwargs...) = tar_make(;
                script,
                store,
                root = dir,
                io = devnull,
                kwargs...,
            )
            local_store = joinpath(dir, "local")
            remote_store = joinpath(dir, "remote")
            build(local_store; jobs = 2)
            s = build(remote_store; executor = DistributedExecutor(pids; script))
            @test s.built == [:grid, :draws, :who, :total, :files]
            @test tar_read(:who; store = remote_store) in pids
            for n in (:grid, :draws, :total, :files)
                @test tar_read(n; store = remote_store) == tar_read(n; store = local_store)
            end
            @test isempty(
                build(remote_store; executor = DistributedExecutor(pids; script)).built,
            )
            # a worker running different code is rejected
            remotecall_eval(Main, pids[1:1], :(empty!(Targets.WORKER_PIPELINES)))
            remotecall_eval(
                Main,
                pids[1:1],
                :(
                    Targets.WORKER_PIPELINES[$script] = tar_pipeline(target(
                        :grid,
                        () -> [9],
                    ))
                ),
            )
            @test_throws "different code" build(
                remote_store;
                executor = DistributedExecutor(pids; script),
                force = true,
            )
        end
    finally
        rmprocs(pids)
    end
    @test_throws "positive" DistributedExecutor([1]; slots_per_worker = 0)
end
