## Error handling: error modes (see the `error` option of `target`) and
## workspaces, which save what is needed to reproduce a failed call.

"The message of error `e` as recorded in a target's metadata: at most `limit` characters."
error_message(e; limit::Int = 2000) = first(sprint(showerror, e), limit)

"""
    user_frames(backtrace)

The stack frames of a failure that belong to the target's own code: everything
inside the call Targets made, without Targets' or the `invokelatest` frames.
"""
function user_frames(backtrace)
    backtrace === nothing && return String[]
    frames = stacktrace(backtrace)
    # every target is called through `call_target`; what lies inside it is the user's
    ours(fr) = occursin("call_target", string(fr.func))
    stop = findfirst(ours, frames)
    user = frames[1:(stop === nothing ? end : stop - 1)]
    while !isempty(user) && between_frame(user[end])
        pop!(user)
    end
    return [string(fr) for fr in user]
end

# The frames between Targets and the user's function: scoped values (before Julia
# 1.11 from ScopedValues.jl, through the logger), world age, and Targets' own
# callables, such as the function of a `@target`. Before Julia 1.11 inlined frames
# have no module, so for them the file decides. (The user's function itself is
# called dynamically, so never inlined, and trimming stops there.)
function between_frame(fr)
    occursin("invokelatest", string(fr.func)) && return true
    fr.func in (:with, :invoke_in_world, :with_logstate, :with_logger) && return true
    plumbing = (@__MODULE__, ScopedValues)
    m = parentmodule(fr)
    m === nothing || return m in plumbing
    file = string(fr.file)
    return any(plumbing) do p
        dir = pkgdir(p)
        dir !== nothing && startswith(file, joinpath(dir, ""))
    end
end

"""
    tar_errored(; store = default_store_path())

Targets (and branches) whose last build failed, as a vector of
`(; name, error, built_at)`.
"""
function tar_errored(; store::Union{Store, AbstractString} = default_store_path())
    s = as_store(store)
    rows = NamedTuple{(:name, :error, :built_at), Tuple{String, String, String}}[]
    for key in meta_keys(s)
        r = read_meta(s, key)::Record
        isempty(r.error) ||
            push!(rows, (name = key, error = r.error, built_at = r.built_at))
    end
    return rows
end

"""
    tar_traceback(key; store = default_store_path())

The stack frames of the target's (or branch's) last failure, from its own code
inward, without Targets' frames.
"""
function tar_traceback(key; store::Union{Store, AbstractString} = default_store_path())
    r = read_meta(as_store(store), key)
    r === nothing && error("no record for `$key`")
    return r.traceback
end

## Capturing warnings

"""
Keeps the messages of warnings and errors, and passes records on to `parent` as
it would have handled them. Warnings are kept even when `parent` would drop
them, so silencing the console does not silence the record.
"""
struct WarningCollector <: Logging.AbstractLogger
    parent::Logging.AbstractLogger
    messages::Vector{String}
    lock::ReentrantLock
end
WarningCollector(parent) = WarningCollector(parent, String[], ReentrantLock())

Logging.min_enabled_level(l::WarningCollector) = min(
    Logging.min_enabled_level(l.parent),
    Logging.Warn,
)
Logging.shouldlog(l::WarningCollector, level, args...) = level >= Logging.Warn ||
    Logging.shouldlog(l.parent, level, args...)
Logging.catch_exceptions(l::WarningCollector) = Logging.catch_exceptions(l.parent)
function Logging.handle_message(
    l::WarningCollector,
    level,
    message,
    _module,
    group,
    id,
    args...;
    kwargs...,
)
    level >= Logging.Warn &&
        lock(() -> push!(l.messages, first(string(message), 500)), l.lock)
    parent_wants = level >= Logging.min_enabled_level(l.parent) &&
        Logging.shouldlog(l.parent, level, _module, group, id)
    parent_wants || return nothing
    return Logging.handle_message(
        l.parent,
        level,
        message,
        _module,
        group,
        id,
        args...;
        kwargs...,
    )
end

"Call `f()` and return its result with the warnings it logged (also from tasks it spawns)."
function collecting_warnings(f)
    collector = WarningCollector(ScopedValues.current_logger())
    value = ScopedValues.with_logger(f, collector)
    return value, collector.messages
end

workspace_path(s::Store, key) = key_path(s, "workspaces", key, ".jld2")

"""
    save_workspace!(store, result)

Save the arguments, seed and error of a failed job to `_targets/workspaces`, so
the call can be reproduced with [`tar_rerun`](@ref). Arguments that cannot be
saved are listed under `unsaved` instead of failing the save.
"""
function save_workspace!(s::Store, r::JobResult)
    job = r.job
    names = job.target.deps
    args = Any[job.args...]
    length(args) == length(names) || (args = Any[nothing for _ in names]) # not loaded
    unsaved = String[]
    for (i, value) in enumerate(args)
        savable(value) && continue
        push!(unsaved, string(names[i]))
        args[i] = nothing
    end
    path = workspace_path(s, job.key)
    atomic_write(path) do tmp
        JLD2.jldsave(
            tmp;
            args = NamedTuple{Tuple(names)}(Tuple(args)),
            seed = job.seed,
            error = error_message(r.exception),
            backtrace = r.backtrace === nothing ?
                "" :
                sprint(Base.show_backtrace, r.backtrace),
            unsaved,
        )
    end
    return path
end

function savable(value)
    path = tempname()
    try
        JLD2.jldsave(path; value)
        return true
    catch e
        e isa InterruptException && rethrow()
        return false
    finally
        rm(path; force = true)
    end
end

# Saving a workspace must never turn into a second failure.
function keep_workspace!(ctx, r::JobResult)
    try
        save_workspace!(ctx.store, r)
    catch e
        e isa InterruptException && rethrow()
        @warn "could not save the workspace of `$(r.job.key)`" exception = e
    end
    return nothing
end

delete_workspace!(s::Store, key) = rm(workspace_path(s, key); force = true)

function load_workspace(s::Store, key)
    path = workspace_path(s, key)
    isfile(path) || error("no workspace for `$key`: it has not failed since it last built")
    return JLD2.load(path)
end

"""
    tar_workspace(key; store = default_store_path())

The arguments of the last failed call of target `key` (or branch `"name/id"`) as a
`NamedTuple` named after its dependencies.
"""
tar_workspace(
    key;
    store::Union{Store, AbstractString} = default_store_path(),
) = load_workspace(as_store(store), key)["args"]

"""
    @tar_workspace name [store = ...]

Assign the arguments of the last failed call of `name` to global variables
named after its dependencies in the calling module (the names are only known at
run time, so unlike [`@tar_load`](@ref) they cannot be locals). Returns them as
a `NamedTuple`.
"""
macro tar_workspace(name, options...)
    kwargs = [esc(Expr(:kw, o.args...)) for o in options]
    key = name isa Symbol ? QuoteNode(name) : name
    return quote
        local args = tar_workspace($key; $(kwargs...))
        for (k, v) in pairs(args)
            Core.eval($__module__, Expr(:(=), k, QuoteNode(v)))
        end
        args
    end
end

"""
    tar_rerun(p::Pipeline, key; store = default_store_path(), root = nothing)

Call target `key`'s current function on the arguments saved by its last failure,
with the same seed, in this session, so the error can be inspected (for example
with Infiltrator.jl or Debugger.jl). As in `tar_make`, it runs with the working
directory set to the project `root` (default: the active project), so relative
paths mean the same. `tar_rerun(key)` loads `_targets.jl`.
"""
function tar_rerun(
    p::Pipeline,
    key;
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
)
    ws = load_workspace(as_store(store), key)
    t = get_target(p, Symbol(first(split(string(key), '/'))))
    isempty(ws["unsaved"]) ||
        @warn "these arguments could not be saved and are passed as `nothing`" ws["unsaved"]
    args = collect(Any, values(ws["args"]))
    return cd(() -> call_target(t.f, args, ws["seed"]), something(root, project_root()))
end
tar_rerun(key; script::AbstractString = default_script(), kwargs...) = tar_rerun(
    load_pipeline(script),
    key;
    kwargs...,
)

@testitem "error modes: stop, continue and null on a chain" setup = [SourceFixtures] begin
    code(mode) = """
    p = tar_pipeline(
        target(:bad, () -> error("boom"); error = :$mode),
        target(:after, bad -> something(bad, 0) + 1),
        target(:other, () -> 7),
    )
    """
    mktempdir() do dir
        @test_throws "boom" build_source(code("stop"), dir)
    end
    mktempdir() do dir
        s = build_source(code("continue"), dir)
        @test s.errored == [:bad] && s.blocked == [:after] && s.built == [:other]
    end
    mktempdir() do dir
        s = build_source(code("null"), dir)
        @test s.errored == [:bad] && s.built == [:after, :other]
        @test read_values(dir, :after) == (1,)
        # the failed target is retried, and its consumers rebuilt once it succeeds
        s = build_source(replace(code("null"), "error(\"boom\")" => "41"), dir)
        @test s.built == [:bad, :after]
        @test read_values(dir, :after) == (42,)
    end
end

@testitem "retries rerun a failing target within one build" begin
    attempts = Ref(0)
    flaky() = (attempts[] += 1; attempts[] < 3 ? error("flaky $(attempts[])") : attempts[])
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        io = IOBuffer()
        p = tar_pipeline(target(:x, () -> flaky(); retries = 2, cue = :always))
        @test tar_make(p; store, root = dir, io).built == [:x]
        @test tar_read(:x; store) == 3
        log = String(take!(io))
        @test occursin("x attempt 1 failed", log) && occursin("x attempt 2 failed", log)
        attempts[] = 0
        q = tar_pipeline(target(:x, () -> flaky(); retries = 1, cue = :always))
        @test_throws "flaky 2" tar_make(q; store, root = dir, io = devnull)
    end
    @test_throws "must not be negative" target(:x, () -> 1; retries = -1)
end

@testitem "error = :trim drops failed branches and retries them" setup = [
    SourceFixtures,
] begin
    # a branch fails while its marker file exists, so fixing it changes no code
    code = """
    p = tar_pipeline(
        target(:grid, () -> [1, 2, 3]),
        target(:fits, grid -> isfile("fail_\$grid") ? error("bad element") : grid * 10;
            pattern = :grid, error = :trim),
        target(:total, fits -> sum(fits)),
    )
    """
    mktempdir() do dir
        touch(joinpath(dir, "fail_2"))
        s = build_source(code, dir)
        @test s.built == [:grid, :fits, :total]
        @test length(s.trimmed[:fits]) == 1
        @test read_values(dir, :fits, :total) == ([10, 30], 40)
        @test outdated_source(code, dir)[1] == (name = :fits, reason = :errored)
        rm(joinpath(dir, "fail_2"))
        s = build_source(code, dir)
        @test isempty(s.trimmed) && length(s.branches[:fits]) == 1 # only the retried one
        @test read_values(dir, :total) == (60,)
    end
    @test_throws "needs a branching target" target(:x, () -> 1; error = :trim)
    @test_throws "error must be" target(:x, () -> 1; error = :ignore)
end

@testitem "failures keep a traceback of the user's frames; warnings are recorded" setup = [
    JETChecks,
] begin
    using Targets: read_meta, open_store
    inner(x) = x > 0 ? error("deep") : x
    outer(x) = inner(x) + 1
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        p = tar_pipeline(
            target(:w, () -> (@warn "careful"; 1)),
            target(:bad, w -> outer(w); error = :continue),
        )
        io = IOBuffer()
        s = @test_logs (:warn, "careful") match_mode = :any tar_make(
            p;
            store,
            root = dir,
            io,
        )
        @test read_meta(open_store(store), :w).warnings == ["careful"]
        @test occursin("1 with warnings", String(take!(io)))
        tb = tar_traceback(:bad; store)
        @test any(f -> occursin("inner", f), tb) && any(f -> occursin("outer", f), tb)
        @test !any(f -> occursin("call_target", f) || occursin("execute", f), tb)
        @test only(tar_errored(; store)).name == "bad"
        @test_call tar_traceback(:bad; store)
        @test_call tar_errored(; store)
        # a macro target's traceback ends at its own line, not in Targets
        q = @pipeline begin
            @target w = 1
            @target bad = outer(w) error = :continue
        end
        tar_make(q; store, root = dir, io = devnull, force = true)
        tb = tar_traceback(:bad; store)
        @test any(f -> occursin("outer", f), tb)
        @test !any(f -> occursin("Targets.", f), tb)
    end
end

@testitem "warnings are recorded even when the console logger drops them" begin
    using Logging
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        p = tar_pipeline(target(:w, () -> (@warn "quiet"; 1)))
        with_logger(NullLogger()) do
            tar_make(p; store, root = dir, io = devnull)
        end
        @test Targets.read_meta(Targets.open_store(store), :w).warnings == ["quiet"]
    end
end

@testitem "a failed target leaves a workspace to rerun it from" setup = [JETChecks] begin
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        p(fail) = tar_pipeline(
            target(:x, () -> [1, 2, 3]),
            target(:y, x -> fail ? error("bad $(sum(x)) $(rand())") : sum(x)),
        )
        bad = p(true)
        err = try
            tar_make(bad; store, root = dir, io = devnull)
        catch e
            e
        end
        @test tar_workspace(:y; store) == (x = [1, 2, 3],)
        rerun = try
            tar_rerun(bad, :y; store)
        catch e
            e
        end
        @test sprint(showerror, rerun) == sprint(showerror, err) # same seed, same error
        @test_call tar_workspace(:y; store)
        @test_call tar_rerun(bad, :y; store, root = dir)
        ws = @tar_workspace y store = store
        # a new global is only visible to code compiled afterwards, as at the REPL
        @test Base.invokelatest(getproperty, @__MODULE__, :x) == [1, 2, 3] == ws.x
        tar_make(p(false); store, root = dir, io = devnull)
        @test_throws "no workspace" tar_workspace(:y; store)
    end
end
