# Shared machinery for the demo projects: writing them, setting up their
# environments, and the scripted walkthroughs. The pipelines themselves are in
#
#   demo_functions.jl   declared with `target`, `tar_map`, `tar_combine`, `tar_rep`
#   demo_macros.jl      the same pipelines with `@pipeline`, `@target`, `@map`, `@rep`
#
# Include one of those (it includes this file), not this file on its own. See
# README.md in this directory for what to try.

# Use the repository's Targets when no environment provides one (e.g. a fresh `julia`).
using Pkg
if Base.identify_package("Targets") === nothing
    Pkg.activate(; temp = true, io = devnull)
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using Targets
using Logging: Logging, ConsoleLogger, with_logger

## Styles

"""
    DemoStyle

How a demo project's `_targets.jl` declares its pipeline. `demo_functions.jl`
and `demo_macros.jl` each define one, with methods of [`style_name`](@ref),
[`demo_targets`](@ref) and [`features_targets`](@ref), and make it the default
of every function here by assigning it to `DEMO_STYLE`.
"""
abstract type DemoStyle end

"""
    style_name(style)

`"functions"` or `"macros"`: names the style's script and project directories.
"""
function style_name end

"""
    demo_targets(style; grid, shifts)

The code that ends the core demo's `_targets.jl` and returns its pipeline; see
[`write_demo`](@ref) for the keywords.
"""
function demo_targets end

"""
    features_targets(style; seed, fast_format)

The code that ends the feature demo's `_targets.jl` and returns its pipeline;
see [`write_features`](@ref) for the keywords.
"""
function features_targets end

style_script(style = DEMO_STYLE) = joinpath(@__DIR__, "demo_$(style_name(style)).jl")

## Writing a project

demo_dir(style = DEMO_STYLE) = joinpath(@__DIR__, ".demo-$(style_name(style))")
demo_store(dir = demo_dir()) = joinpath(dir, "_targets")
demo_script(dir = demo_dir()) = joinpath(dir, "_targets.jl")

# Every demo environment has all three, so each way of plotting can be tried.
const MAKIE_BACKENDS = (:CairoMakie, :GLMakie, :WGLMakie)

# The Makie backend the demo script in `dir` loads, if any (so regenerating keeps it).
function makie_backend(dir)
    isfile(demo_script(dir)) || return nothing
    script = read(demo_script(dir), String)
    i = findfirst(b -> occursin("using $b\n", script), MAKIE_BACKENDS)
    return i === nothing ? nothing : MAKIE_BACKENDS[i]
end

# The line of a `_targets.jl` that loads the Makie backend `makie`, if any.
function makie_line(makie)
    makie === nothing && return ""
    makie in MAKIE_BACKENDS ||
        throw(ArgumentError(
            "makie must be `nothing` or one of $MAKIE_BACKENDS, got $(repr(makie))",
        ))
    return "using $makie\n"
end

"Write `dir`'s `_targets.jl`: load Targets, `makie` and the `helpers` file, then `pipeline`."
write_script(dir, makie, helpers, pipeline) = write(
    demo_script(dir),
    """
    using Targets
    $(makie_line(makie))Base.include(@__MODULE__, joinpath(@__DIR__, "$helpers"))

    $pipeline""",
)

function print_plotting_help()
    println("  Plot with any Makie backend (all three are installed):")
    println("  using CairoMakie; tar_visnetwork()   # a static figure")
    println("  using GLMakie; tar_visnetwork()      # an interactive window")
    println("  using WGLMakie; tar_visnetwork()     # an interactive browser tab")
    return nothing
end

"""
    write_demo(dir = demo_dir(); style = DEMO_STYLE, scale = 3, note = "",
               data = "1.0 2.0 NaN 4.0", grid = "[0.1, 0.5, 1.0]", discount = "x",
               shifts = "(low = 1, high = 2)", makie = makie_backend(dir))

Write the core demo project into `dir`, its pipeline declared in `style`. Each
other keyword changes one thing:

- `scale`: a `const` in `analysis.jl` that `score` reaches (code edit, changes outputs)
- `note`: a comment line (formatting-only edit: must rebuild nothing)
- `data`: contents of the input file `data/raw.csv`
- `grid`: the pattern target's elements (branching)
- `discount`: an expression inside a helper two calls deep from the `scores` target
- `shifts`: a named tuple of shifts; each name gets a `shifted_<name>` and a
  `shift_summary_<name>` target (static branching), combined by `shifted_total`
- `makie`: a Makie backend for `_targets.jl` to load (`:CairoMakie`, `:GLMakie` or
  `:WGLMakie`), or `nothing`; kept on regeneration. Loading a backend activates it,
  so leave this `nothing` to choose the backend in the REPL instead
"""
function write_demo(
    dir::AbstractString = demo_dir();
    style::DemoStyle = DEMO_STYLE,
    scale = 3,
    note = "",
    data = "1.0 2.0 NaN 4.0",
    grid = "[0.1, 0.5, 1.0]",
    discount = "x",
    shifts = "(low = 1, high = 2)",
    makie = makie_backend(dir),
)
    mkpath(joinpath(dir, "data"))
    write(joinpath(dir, "data", "raw.csv"), data)
    write(
        joinpath(dir, "analysis.jl"),
        """
        $note
        const SCALE = $scale

        struct Params
            alpha::Float64
        end

        clean(xs) = filter(!isnan, xs)

        adjust(x) = $discount
        weight(p::Params, x) = p.alpha * adjust(x) * SCALE
        score(p::Params, xs) = sum(weight(p, x) for x in xs)

        summarize(scores) = (n = length(scores), total = round(sum(scores); digits = 3))
        """,
    )
    write_script(dir, makie, "analysis.jl", demo_targets(style; grid, shifts))
    return dir
end

"""
    demo_setup(dir = demo_dir(); style = DEMO_STYLE, makie = nothing)

Write the core demo project and give it its own environment with this
repository's Targets developed into it, plus CairoMakie, GLMakie and WGLMakie,
ready to `activate` and `tar_make()`. `style` and `makie` are passed to
[`write_demo`](@ref).
"""
function demo_setup(
    dir::AbstractString = demo_dir();
    style::DemoStyle = DEMO_STYLE,
    makie = nothing,
)
    write_demo(dir; style, makie)
    setup_environment(dir, [string.(MAKIE_BACKENDS)...])
    println("Demo project ($(style_name(style))) ready in ", dir)
    println("  cd(\"", relpath(dir), "\"); then start julia with --project=. and run:")
    println("  using Targets")
    println("  tar_make()")
    println("  include(\"", relpath(style_script(style), dir), "\")  # to edit it")
    print_plotting_help()
    return dir
end

"""
    setup_environment(dir, packages)

Give `dir` its own environment with this repository's Targets developed into it,
plus `packages`.
"""
function setup_environment(dir::AbstractString, packages)
    previous = Base.active_project()
    try
        Pkg.activate(dir; io = devnull)
        # Always (re)resolve: the Manifest records Targets' dependencies and
        # extensions, which go stale whenever the package's Project.toml changes.
        isfile(joinpath(dir, "Manifest.toml")) ?
            Pkg.resolve() :
            Pkg.develop(; path = dirname(@__DIR__))
        Pkg.add(packages)
    finally
        previous === nothing ?
            Pkg.activate(; io = devnull) :
            Pkg.activate(previous; io = devnull)
    end
    return dir
end

"Run `tar_make` on the demo project in `dir`, with the store inside it."
demo_make(dir = demo_dir(); io = stdout, kwargs...) = tar_make(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
    io,
    kwargs...,
)

"What a build would do, without building."
demo_outdated(dir = demo_dir(); kwargs...) = tar_outdated(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
    kwargs...,
)

"The demo's `Pipeline`, e.g. for `tar_dot`."
demo_pipeline(dir = demo_dir()) = Targets.load_pipeline(demo_script(dir))

"Remove the demo project and its store."
reset_demo(dir = demo_dir()) = rm(dir; recursive = true, force = true)

## Scripted walkthrough

function check(label, summary, expected_built)
    ok = sort(summary.built) == sort(expected_built)
    println(ok ? "  ✓ " : "  ✗ ", label, ": built ", summary.built)
    ok || println("      expected ", expected_built)
    return ok
end

"""
    walkthrough(dir = mktempdir(); style = DEMO_STYLE)

Build, edit and rebuild the core demo project, checking after each step that
exactly the expected targets were rebuilt. Returns `true` if every step matched.
"""
function walkthrough(dir = mktempdir(); style::DemoStyle = DEMO_STYLE)
    everything = [:raw_file, :raw, :cleaned, :grid, :scores, :report]
    shifted(names...) = [Symbol(p, n) for n in names for p in (:shifted_, :shift_summary_)]
    append!(everything, shifted(:low, :high), [:shifted_total])
    results = Bool[]
    run(label, expected) = push!(
        results,
        check(label, demo_make(dir; io = devnull), expected),
    )
    rewrite(; kwargs...) = write_demo(dir; style, kwargs...)

    println("Walkthrough (", style_name(style), ") in ", dir)
    rewrite()
    run("first build", everything)
    run("second build (nothing changed)", Symbol[])

    rewrite(; note = "# only a comment, and everything below it moves down a line")
    run("comment added", Symbol[])

    rewrite(; discount = "x + 0") # helper edited, same outputs
    run("helper edited, outputs unchanged (early cutoff)", [:scores])

    rewrite(; discount = "x + 0", scale = 4) # global edited, outputs change
    run("global edited", [:scores, :report])

    rewrite(; discount = "x + 0", scale = 4, grid = "[0.1, 0.5, 1.0, 2.0]")
    run("one element added to the pattern", [:grid, :scores, :report])

    rewrite(;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, high = 3)",
    )
    run("static branch value changed", [shifted(:high)..., :shifted_total])

    rewrite(;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, mid = 2, high = 3)",
    )
    run("static branch added", [shifted(:mid)..., :shifted_total])

    rewrite(;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, mid = 2, high = 3)",
        data = "1.0 2.0 NaN 4.0 8.0",
    )
    run(
        "input file edited",
        [
            :raw_file,
            :raw,
            :cleaned,
            :scores,
            :report,
            shifted(:low, :mid, :high)...,
            :shifted_total,
        ],
    )

    touch(joinpath(dir, "data", "raw.csv"))
    run("input file touched, same bytes", Symbol[])

    println("Pending: ", demo_outdated(dir))
    println("Report: ", tar_read(:report; store = demo_store(dir)))
    ok = all(results)
    println(ok ? "All steps behaved." : "Some steps did not.")
    return ok
end

## A second project exercising what v0.2 added: seeds, concurrent jobs and slots,
## storage formats, pattern combinators, replication, error modes, retries,
## workspaces, tracebacks and warnings, cues, progress events and executors.
## (URL targets need a server, so they are not part of it; see `format = :url`.)

features_dir(style = DEMO_STYLE) = joinpath(@__DIR__, ".features-$(style_name(style))")

"""
    write_features(dir = features_dir(); style = DEMO_STYLE, seed = 0, noise = 1.0,
                   total = "sum(xs)", fast_format = :jls, makie = makie_backend(dir))

Write the v0.2 feature project into `dir`, its pipeline declared in `style`.
Each other keyword changes one thing:

- `seed`: the pipeline seed (every `seed = :auto` target rebuilds, `:seed_changed`)
- `noise`: a `const` reached by the seeded `draws` target
- `total`: the body of a helper used by `cached_total`, whose cue ignores code edits
- `fast_format`: the storage format of `fast` (`:format_changed` when it changes)
- `makie`: a Makie backend for `_targets.jl` to load, or `nothing` (as in [`write_demo`](@ref));
  a backend loaded there is also loaded on `Distributed` workers

Targets fail while marker files exist: `fail_10` fails one branch of
`fragile_fits` (`error = :trim`), `fail_maybe` fails `maybe` (`error = :null`).
`flaky` fails on its first attempt in each fresh project and succeeds on retry.
"""
function write_features(
    dir::AbstractString = features_dir();
    style::DemoStyle = DEMO_STYLE,
    seed = 0,
    noise = 1.0,
    total = "sum(xs)",
    fast_format = :jls,
    makie = makie_backend(dir),
)
    mkpath(dir)
    write(
        joinpath(dir, "features.jl"),
        """
        const NOISE = $noise

        simulate(mu) = mu + NOISE * randn()
        fragile(x) = isfile("fail_\$(round(Int, x))") ? error("element \$x failed") : 10x
        maybe_value() = isfile("fail_maybe") ? error("no value today") : 42
        total(xs) = $total

        # fails on the first attempt only (the attempt count lives in a file, not in code)
        function flaky()
            n = isfile("attempts") ? parse(Int, read("attempts", String)) : 0
            write("attempts", string(n + 1))
            n == 0 && error("flaky connection")
            return n + 1
        end

        function noisy_sum(xs)
            length(xs) < 5 && @warn "only \$(length(xs)) values"
            return sum(xs)
        end
        """,
    )
    write_script(dir, makie, "features.jl", features_targets(style; seed, fast_format))
    return dir
end

"""
    features_setup(dir = features_dir(); style = DEMO_STYLE, makie = nothing)

Write the v0.2 feature project, with the marker files that make two targets
fail, and give it its own environment (Targets, CairoMakie, GLMakie, WGLMakie
and Distributed), ready to `activate` and `tar_make(; jobs = 4)`. `style` and
`makie` are passed to [`write_features`](@ref).
"""
function features_setup(
    dir::AbstractString = features_dir();
    style::DemoStyle = DEMO_STYLE,
    makie = nothing,
)
    write_features(dir; style, makie)
    touch(joinpath(dir, "fail_10"))
    touch(joinpath(dir, "fail_maybe"))
    setup_environment(dir, [string.(MAKIE_BACKENDS)..., "Distributed"])
    println("Feature project ($(style_name(style))) ready in ", dir)
    println("  cd(\"", relpath(dir), "\"); then start julia with --project=. -t 4 and run:")
    println("  using Targets")
    println("  tar_make(; jobs = 4)")
    println("  include(\"", relpath(style_script(style), dir), "\")  # to edit it")
    print_plotting_help()
    return dir
end

# `noisy` warns on purpose; the warning is still recorded in its metadata (checked
# below), so keep it off the console.
features_make(dir; kwargs...) = with_logger(ConsoleLogger(stderr, Logging.Error)) do
    tar_make(;
        script = demo_script(dir),
        store = demo_store(dir),
        root = dir,
        io = devnull,
        kwargs...,
    )
end

features_outdated(dir) = tar_outdated(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
)

"""
    features_walkthrough(dir = mktempdir(); style = DEMO_STYLE, distributed = false)

Build and edit the v0.2 feature project, checking each step. With
`distributed = true`, also build it on two `Distributed` workers. Returns `true`
if every check passed.
"""
function features_walkthrough(
    dir = mktempdir();
    style::DemoStyle = DEMO_STYLE,
    distributed = false,
)
    results = Bool[]
    function ok(label, cond, detail = "")
        println(
            cond ? "  \u2713 " : "  \u2717 ",
            label,
            (cond || isempty(detail)) ? "" : ": " * detail, # details only on failure
        )
        push!(results, cond)
        return cond
    end
    store = demo_store(dir)
    read_target(name) = tar_read(name; store, on_outdated = :ignore)

    println(
        "Feature walkthrough (",
        style_name(style),
        ") in ",
        dir,
        " (",
        Threads.nthreads(),
        " threads)",
    )
    write_features(dir; style)
    touch(joinpath(dir, "fail_10"))
    touch(joinpath(dir, "fail_maybe"))

    # 1. a concurrent first build, with failures handled by error modes and retries
    s = features_make(dir; jobs = 4)
    ok(
        "concurrent build finished despite failures",
        s.errored == [:maybe],
        "errored $(s.errored)",
    )
    ok(":null gives consumers nothing", read_target(:uses_maybe) == "no value")
    ok(
        ":trim drops the failed branch",
        read_target(:fragile_fits) == [0.0, 200.0],
        "got $(read_target(:fragile_fits))",
    )
    ok("retries recovered the flaky target", read_target(:flaky) == 2)
    ok("slots = :all got every slot", read_target(:exclusive) == 4)
    ok(
        "Cross builds every combination",
        read_target(:combos) == [0.0, 0.0, 10.0, 20.0, 20.0, 40.0],
    )
    ok("Map(Head(...), ...) pairs elements", read_target(:paired) == [(0.0, 1), (10.0, 2)])
    ok("Sample picks two", length(read_target(:sampled)) == 2)
    ok("replication gathers batches x reps", length(read_target(:sims)) == 10)
    ok(":jls objects are stored", isfile(joinpath(store, "objects", "fast.jls")))

    # 2. debugging the failure
    ok("tar_errored lists the failures", "maybe" in [r.name for r in tar_errored(; store)])
    ok("a workspace was saved", tar_workspace(:maybe; store) == NamedTuple())
    rerun = try
        tar_rerun(Targets.load_pipeline(demo_script(dir)), :maybe; store, root = dir)
    catch e
        sprint(showerror, e)
    end
    ok("tar_rerun reproduces the error", rerun == "no value today", "got $(repr(rerun))")
    ok(
        "the traceback starts in user code",
        any(f -> occursin("maybe_value", f), tar_traceback(:maybe; store)),
    )
    noisy = Targets.read_meta(Targets.open_store(store), :noisy)
    ok("warnings are recorded", noisy.warnings == ["only 3 values"])

    # 3. fixing the inputs rebuilds the failed parts only
    rm(joinpath(dir, "fail_10"))
    rm(joinpath(dir, "fail_maybe"))
    s = features_make(dir; jobs = 2)
    ok(
        "fixed targets rebuilt",
        sort(s.built) == sort([:fragile_fits, :maybe, :uses_maybe]),
        "built $(s.built)",
    )
    ok("the trimmed branch is back", read_target(:fragile_fits) == [0.0, 100.0, 200.0])
    ok("nothing left to do", isempty(features_outdated(dir)))

    # 4. seeds: a one-job build elsewhere gives the same random values
    other = mktempdir()
    write_features(other; style)
    features_make(other; jobs = 1)
    same(name) = tar_read(name; store = demo_store(other), on_outdated = :ignore) ==
        read_target(name)
    ok("seeded draws match across builds", same(:draws) && same(:sims))
    write_features(dir; style, seed = 1)
    reasons = Dict(r.name => r.reason for r in features_outdated(dir))
    ok(
        "a new pipeline seed is :seed_changed",
        get(reasons, :mus, nothing) == :seed_changed,
        "got $reasons",
    )
    s = features_make(dir; jobs = 4)
    ok("seeded targets rebuilt", :draws in s.built && :sims in s.built, "built $(s.built)")

    # 5. cues and formats
    write_features(dir; style, seed = 1, total = "sum(xs) + 0")
    ok("Cue(code = false) ignores a helper edit", isempty(features_make(dir).built))
    write_features(dir; style, seed = 1, total = "sum(xs) + 0", fast_format = :jld2)
    reasons = Dict(r.name => r.reason for r in features_outdated(dir))
    ok(
        "changing a format is :format_changed",
        get(reasons, :fast, nothing) == :format_changed,
    )
    ok("only that target rebuilds", features_make(dir).built == [:fast])

    # 6. progress events of the last run
    progress = tar_progress(; store)
    ok(
        "tar_progress reports the last run",
        any(r -> r.key == "fast" && r.status == :built, progress),
    )

    # 7. check_mutation catches a target that modifies its input
    p = tar_pipeline(target(:xs, () -> [1, 2]), target(:bad, xs -> push!(xs, 3)))
    caught = try
        tar_make(
            p;
            store = joinpath(dir, "mutation"),
            root = dir,
            io = devnull,
            check_mutation = true,
        )
        false
    catch e
        occursin("mutated its argument", sprint(showerror, e))
    end
    ok("check_mutation caught the mutation", caught)

    # 8. optionally, the same project on worker processes
    if distributed
        Dist = Base.require(Base.PkgId(
            Base.UUID("8ba89e20-285c-5b6f-9357-94700520ee1b"),
            "Distributed",
        ))
        pids = Base.invokelatest(
            Dist.addprocs,
            2;
            exeflags = "--project=$(Base.active_project())",
        )
        try
            remote = mktempdir()
            write_features(remote; style)
            exec = Base.invokelatest(
                DistributedExecutor,
                pids;
                script = demo_script(remote),
            )
            features_make(remote; executor = exec)
            r(name) = tar_read(name; store = demo_store(remote), on_outdated = :ignore)
            ok(
                "workers give the same seeded draws",
                r(:draws) ==
                    tar_read(:draws; store = demo_store(other), on_outdated = :ignore),
            )
        finally
            Base.invokelatest(Dist.rmprocs, pids)
        end
    end

    all_ok = all(results)
    println(all_ok ? "All feature checks passed." : "Some feature checks failed.")
    return all_ok
end

"""
    run_walkthroughs(args = ARGS; style = DEMO_STYLE)

Both walkthroughs in `style`, on workers too if `args` has `--distributed`.
Returns `true` if both passed.
"""
function run_walkthroughs(args = ARGS; style::DemoStyle = DEMO_STYLE)
    core = walkthrough(; style)
    features = features_walkthrough(; style, distributed = "--distributed" in args)
    return core && features
end
