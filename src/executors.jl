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
TaskExecutor(n::Integer) = TaskExecutor(resolve_jobs(n), Channel{JobResult}(Inf))

capacity(e::TaskExecutor) = e.jobs
function submit!(e::TaskExecutor, job::Job, slots::Int)
    results = e.results
    Threads.@spawn put!(results, execute_granted(job, slots))
    return nothing
end
take_result!(e::TaskExecutor) = take!(e.results)

"Whether `job` runs in the scheduler task instead of being submitted."
runs_inline(e::Executor, job::Job) = capacity(e) == 1 || job.target.deployment === :main
