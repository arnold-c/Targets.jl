module TargetsDistributedExt

# Loaded once Distributed is: implements DistributedExecutor.

using Distributed: Distributed, remotecall_eval, remotecall_fetch
using Targets: Targets, DistributedExecutor, Job, JobResult

function Targets.distributed_start!(e::DistributedExecutor, ctx)
    remotecall_eval(Main, e.pids, :(using Targets))
    check_shared_store(e, ctx.store.root)
    check_same_code(e, ctx)
    return nothing
end

# Workers must see the main process's store, since they write objects into it.
function check_shared_store(e::DistributedExecutor, store_root::String)
    token = string(rand(UInt64); base = 16)
    path = joinpath(store_root, "worker-check-" * token)
    write(path, token)
    try
        for pid in e.pids
            seen = remotecall_fetch(p -> isfile(p) ? read(p, String) : "", pid, path)
            seen == token ||
                error(
                    "worker $pid cannot see the store at $store_root; workers need a shared filesystem",
                )
        end
    finally
        rm(path; force = true)
    end
end

# A worker running other code would record wrong hashes.
function check_same_code(e::DistributedExecutor, ctx)
    p = ctx.pipeline
    main = Dict(
        t.name => (
            something(Targets.command_for!(ctx, t).hash, ""),
            Targets.code_for!(ctx, t),
        )
        for t in p.targets
    )
    for pid in e.pids
        theirs = remotecall_fetch(Targets.worker_hashes, pid, e.script, ctx.root)
        differing = sort!([n for (n, h) in main if get(theirs, n, nothing) != h])
        isempty(differing) ||
            error(
                "worker $pid loaded different code for $(join(differing, ", ")) than this process; " *
                    "make sure workers load the same script and packages",
            )
    end
end

function Targets.distributed_submit!(e::DistributedExecutor, job::Job, slots::Int)
    pid = Targets.pick_worker(e)
    if job.load_error !== nothing
        # nothing to send: fail here
        e.used[pid] += slots
        e.assigned[job.key] = (pid, slots)
        put!(e.results, Targets.execute(job))
        return nothing
    end
    e.used[pid] += slots
    e.assigned[job.key] = (pid, slots)
    results = e.results
    @async begin
        r = try
            rr = remotecall_fetch(
                Targets.run_remote,
                pid,
                e.script,
                job.root,
                job.store.root,
                job.target.name,
                job.key,
                job.branch,
                job.args,
                job.seed,
                job.reason,
                job.cmd,
                job.code,
                job.dep_hashes,
                job.pattern_use,
                min(slots, e.slots_per_worker),
            )
            Targets.from_remote(job, rr)
        catch err
            JobResult(job, nothing, "", (;), 0.0, err, catch_backtrace())
        end
        put!(results, r)
    end
    return nothing
end

end
