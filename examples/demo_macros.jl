# The demo pipelines declared with macros: `@pipeline`, `@target`, `@map` and
# `@rep`. A target's dependencies are the targets its expression refers to.
# `demo_functions.jl` declares the same pipelines with functions; both give the
# same targets, dependencies and values. See README.md in this directory.
#
# Set up the interactive projects (`examples/.demo-macros/` and
# `examples/.features-macros/`, git-ignored) from the repository root:
#
#   julia --project=. -e 'include("examples/demo_macros.jl"); demo_setup()'
#   julia --project=. -e 'include("examples/demo_macros.jl"); features_setup()'
#
# Then, in `examples/.demo-macros/`:
#
#   julia --project=.
#   julia> using Targets, CairoMakie  # or GLMakie, or WGLMakie
#   julia> tar_make()
#   julia> include("../demo_macros.jl")
#   julia> write_demo(; scale = 4)    # regenerate the project with one edit
#   julia> tar_outdated(); tar_make()
#
# Or run both scripted walkthroughs in temporary directories:
#
#   julia --project=. -t 4 examples/demo_macros.jl [--distributed]

include(joinpath(@__DIR__, "demo.jl"))

struct MacroStyle <: DemoStyle end
style_name(::MacroStyle) = "macros"
DEMO_STYLE = MacroStyle()

# The core demo: a file input, dynamic branching over `grid`, and static
# branching over `shifts`, combined into one total.
demo_targets(::MacroStyle; grid, shifts) = """
@pipeline begin
    @target raw_file = "data/raw.csv"  format = :file
    @target raw      = parse.(Float64, split(read(raw_file, String)))
    @target cleaned  = clean(raw)
    @target grid     = $grid
    @target scores   = score(Params(grid), cleaned)  pattern = grid
    @target report   = summarize(scores)

    # Static branching: `shifted_low`, `shift_summary_low`, ... one pair per named shift.
    # Within a branch, `shifted` is that branch's `shifted` target.
    @map($shifts) do k
        @target shifted       = cleaned .+ k
        @target shift_summary = summarize(shifted)
    end

    # Outside the @map, `shift_summary` is all of its branches: a NamedTuple keyed
    # by suffix, `(low = ..., high = ...)`.
    @target shifted_total = sum(s.total for s in shift_summary)
end
"""

# The v0.2 features, one target each.
features_targets(::MacroStyle; seed, fast_format) = """
@pipeline seed = $seed begin
    @target mus   = [0.0, 10.0, 20.0]
    @target sizes = [1, 2]
    # seeded branches: the same draws however and wherever they are built
    @target draws = simulate(mus)  pattern = mus
    # pattern combinators
    @target combos  = mus * sizes     pattern = cross(mus, sizes)
    @target paired  = (mus, sizes)    pattern = map(head(mus, 2), sizes)
    @target sampled = mus             pattern = sample(mus, 2)
    # batched replication: 2 branches of 5 reps
    @rep sims = randn()  batches = 2  reps = 5
    # error modes and retries
    @target fragile_fits = fragile(mus)  pattern = mus  error = :trim
    @target maybe        = maybe_value()  error = :null
    @target uses_maybe   = maybe === nothing ? "no value" : "value \$maybe"
    @target flaky        = flaky()  retries = 2     # a target's own name is the function
    # warnings are recorded
    @target noisy = noisy_sum(draws)
    # concurrency options
    @target exclusive = tar_slots()  slots = :all
    @target on_main   = "ran in the calling task"  deployment = :main
    # cues and formats
    @target cached_total = total(mus)  cue = Cue(code = false)
    @target fast         = Dict(:a => [1, 2, 3])  format = :$fast_format
end
"""

if abspath(PROGRAM_FILE) == @__FILE__
    run_walkthroughs(ARGS) || exit(1)
end
