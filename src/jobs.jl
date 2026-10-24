## Jobs: the unit of work handed to `execute`
##
## A build is split into three steps. *Planning* (in the scheduler task) decides
## what is outdated and resolves each job's arguments. *Executing* calls the
## user's function and writes the object; it depends only on its `Job` and never
## touches the `BuildContext`, so jobs can run concurrently. *Committing* (in the
## scheduler task again) writes the metadata record, the commit marker, and
## updates the run's state.

"""
    Job

Everything needed to build one target, or one branch (`branch > 0` is its
position in the pattern), without access to the build's shared state.
"""
struct Job
    target::Target
    key::String
    branch::Int
    args::Vector{Any}
    load_error::Any # an exception raised while loading the arguments, or `nothing`
    seed::Union{Nothing, UInt64}
    reason::Symbol
    cmd::CommandHash
    code::String
    dep_hashes::Dict{Symbol, String}
    pattern_use::Union{Nothing, Symbol} # a target that uses this one as its pattern
    store::Store
    root::String
end

"""
    JobResult

The outcome of [`execute`](@ref): the value consumers receive, its value hash
and extra record fields, or the exception (and backtrace) the job raised.
"""
struct JobResult
    job::Job
    value::Any
    value_hash::String
    stored::NamedTuple
    seconds::Float64
    exception::Any
    backtrace::Any
    retried::Vector{String} # messages of failed attempts before this outcome
end
JobResult(job, value, value_hash, stored, seconds, exception, backtrace) = JobResult(
    job,
    value,
    value_hash,
    stored,
    seconds,
    exception,
    backtrace,
    String[],
)

failed(r::JobResult) = r.exception !== nothing

"""
    BranchProgress

A branching target while its branch jobs run: the value hash of each branch
(empty until known), the positions of branches built so far, how many jobs
are still pending, and the first failure.
"""
mutable struct BranchProgress
    const target::Target
    const cmd::CommandHash
    const code::String
    const elements::Vector{Branch}
    const hashes::Vector{String}
    const built::Vector{Int}
    const failed::Vector{Int}
    const previous::Union{Nothing, Record}
    pending::Int
    failure::Any
end

"""
    execute(job) -> JobResult

Call the job's function with its arguments and seed, and write its object,
retrying a failure up to the target's `retries` times. Every exception except
`InterruptException` is returned inside the result.
"""
function execute(job::Job)
    retried = String[]
    while true
        r = attempt(job)
        retry = failed(r) &&
            job.load_error === nothing &&
            length(retried) < job.target.retries
        retry ||
            return JobResult(
                (getfield(r, f) for f in fieldnames(JobResult) if f !== :retried)...,
                retried,
            )
        push!(retried, first(sprint(showerror, r.exception), 200))
        sleep(job.target.retry_delay)
    end
end

"One attempt at a job."
function attempt(job::Job)
    started = time_ns()
    elapsed() = (time_ns() - started) / 1.0e9
    try
        job.load_error === nothing || throw(job.load_error)
        before = CHECK_MUTATION[] ? map(canonical_hash, job.args) : nothing
        value = call_target(job.target.f, job.args, job.seed)
        seconds = elapsed()
        before === nothing || check_unmutated(job, before)
        consumer_value, vhash, stored = persist_value(job, value)
        return JobResult(job, consumer_value, vhash, stored, seconds, nothing, nothing)
    catch e
        e isa InterruptException && rethrow()
        return JobResult(job, nothing, "", (;), elapsed(), e, catch_backtrace())
    end
end

"Whether `execute` checks that targets leave their arguments unchanged (`tar_make(; check_mutation)`)."
const CHECK_MUTATION = ScopedValue(false)

function check_unmutated(job::Job, before::Vector{String})
    for (i, h) in enumerate(before)
        canonical_hash(job.args[i]) == h && continue
        t = job.target
        error(
            "target `$(job.key)` mutated its argument `$(t.deps[i])`; targets must not " *
                "modify their inputs, which are shared with other consumers (copy it first)",
        )
    end
end

"""
    persist_value(job, value)

Persist what a target returned. Returns the value its consumers receive, its
value hash, and any extra record fields (a file target keeps no object).
"""
function persist_value(job::Job, value)
    t = job.target
    if job.branch > 0
        path = write_object(job.store, job.key, value; format = resolve_format(t.format))
        return value, object_hash(value, path), (;)
    end
    if t.format == :url
        urls, scalar = normalize_url_value(t, value)
        state = url_state(urls)
        (job.pattern_use === nothing || !scalar) ||
            error(
                "target `$(t.name)` is the pattern of `$(job.pattern_use)`, so it must return a vector of URLs",
            )
        stored = (; files = urls, file_scalar = scalar, file_hashes = state.hashes)
        return (scalar ? first(urls) : urls), state.value_hash, stored
    end
    if t.format == :file
        paths, scalar = normalize_file_value(t, value, job.root)
        state = file_state(job.root, paths)
        stored = (;
            files = paths,
            file_scalar = scalar,
            file_signatures = state.signatures,
            file_hashes = state.hashes,
        )
        (job.pattern_use === nothing || !scalar) ||
            error(
                "target `$(t.name)` is the pattern of `$(job.pattern_use)`, so it must return a vector of paths",
            )
        return (scalar ? first(paths) : paths), state.value_hash, stored
    end
    path = write_object(job.store, job.key, value; format = resolve_format(t.format))
    stored = (;)
    if job.pattern_use !== nothing && t.pattern === nothing
        has_branch_elements(value) ||
            error(
                "target `$(t.name)` is the pattern of `$(job.pattern_use)`, so it must return a vector, " *
                    "not a `$(typeof(value))` (or define `Targets.branch_elements` for it)",
            )
        stored = (; element_hashes = element_hashes(value), elements_recorded = true)
    end
    return value, object_hash(value, path), stored
end

"The metadata record of a successful job."
function job_record(r::JobResult)
    job = r.job
    return Record(;
        command_hash = something(job.cmd.hash, ""),
        code_hash = job.code,
        hash_source = string(job.cmd.kind),
        dep_hashes = Dict{String, String}(string(d) => h for (d, h) in job.dep_hashes),
        value_hash = r.value_hash,
        format_fields(job.target)...,
        built_at = string(Dates.now(Dates.UTC)),
        r.seconds,
        seed = seed_string(job.seed),
        r.stored...,
    )
end

@testitem "check_mutation catches a target that modifies its input" begin
    p = tar_pipeline(
        target(:xs, () -> [1, 2]),
        target(:fine, xs -> sum(xs)),
        target(:bad, xs -> push!(xs, 3)),
    )
    mktempdir() do dir
        build(; kwargs...) = tar_make(
            p;
            store = joinpath(dir, "_targets"),
            root = dir,
            io = devnull,
            kwargs...,
        )
        @test_throws "`bad` mutated its argument `xs`" build(; check_mutation = true)
        @test build(; force = true).built == [:xs, :fine, :bad] # unchecked by default
    end
end

@testitem "execute returns failures instead of throwing" begin
    using Targets: Job, execute, failed, open_store, CommandHash
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        job(f, args; load_error = nothing) = Job(
            target(:x, f; deps = [Symbol("a$i") for i in eachindex(args)]),
            "x",
            0,
            Any[args...],
            load_error,
            UInt64(1),
            :missing,
            CommandHash("c", :source),
            "k",
            Dict{Symbol, String}(),
            nothing,
            s,
            dir,
        )
        ok = execute(job(a1 -> a1 + 1, (1,)))
        @test !failed(ok) && ok.value == 2 && !isempty(ok.value_hash)
        bad = execute(job(a1 -> error("boom"), (1,)))
        @test failed(bad) && occursin("boom", sprint(showerror, bad.exception))
        unloaded = execute(job(() -> 1, (); load_error = ErrorException("no object")))
        @test failed(unloaded) && unloaded.exception.msg == "no object"
    end
end
