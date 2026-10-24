## Error handling: error modes (see the `error` option of `target`) and
## workspaces, which save what is needed to reproduce a failed call.

workspace_path(s::Store, key) = joinpath(s.root, "workspaces", string(key) * ".jld2")

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
            error = first(sprint(showerror, r.exception), 2000),
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
    tar_rerun(p::Pipeline, key; store = default_store_path())

Call target `key`'s current function on the arguments saved by its last failure,
with the same seed, in this session, so the error can be inspected (for example
with Infiltrator.jl or Debugger.jl). `tar_rerun(key)` loads `_targets.jl`.
"""
function tar_rerun(
    p::Pipeline,
    key;
    store::Union{Store, AbstractString} = default_store_path(),
)
    ws = load_workspace(as_store(store), key)
    t = get_target(p, Symbol(first(split(string(key), '/'))))
    isempty(ws["unsaved"]) ||
        @warn "these arguments could not be saved and are passed as `nothing`" ws["unsaved"]
    return call_target(t.f, collect(Any, values(ws["args"])), ws["seed"])
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

@testitem "a failed target leaves a workspace to rerun it from" begin
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
        ws = @tar_workspace y store = store
        # a new global is only visible to code compiled afterwards, as at the REPL
        @test Base.invokelatest(getproperty, @__MODULE__, :x) == [1, 2, 3] == ws.x
        tar_make(p(false); store, root = dir, io = devnull)
        @test_throws "no workspace" tar_workspace(:y; store)
    end
end
