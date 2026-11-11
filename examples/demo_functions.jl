# The demo pipelines declared with functions: `target`, `tar_map`, `tar_combine`
# and `tar_rep`. A target's dependencies are the argument names of its function.
# `demo_macros.jl` declares the same pipelines with macros; both give the same
# targets, dependencies and values. See README.md in this directory.
#
# Set up the interactive projects (`examples/.demo-functions/` and
# `examples/.features-functions/`, git-ignored) from the repository root:
#
#   julia --project=. -e 'include("examples/demo_functions.jl"); demo_setup()'
#   julia --project=. -e 'include("examples/demo_functions.jl"); features_setup()'
#
# Then, in `examples/.demo-functions/`:
#
#   julia --project=.
#   julia> using Targets, CairoMakie  # or GLMakie, or WGLMakie
#   julia> tar_make()
#   julia> include("../demo_functions.jl")
#   julia> write_demo(; scale = 4)    # regenerate the project with one edit
#   julia> tar_outdated(); tar_make()
#
# Or run both scripted walkthroughs in temporary directories:
#
#   julia --project=. -t 4 examples/demo_functions.jl [--distributed]

include(joinpath(@__DIR__, "demo.jl"))

struct FunctionStyle <: DemoStyle end
style_name(::FunctionStyle) = "functions"
DEMO_STYLE = FunctionStyle()

# The core demo: a file input, dynamic branching over `grid`, and static
# branching over `shifts`, combined into one total.
demo_targets(::FunctionStyle; grid, shifts) = """
# Static branching: `shifted_low`, `shift_summary_low`, ... one pair per named shift.
# Within a branch, `shifted` is the argument name of that branch's `shifted` target.
shifts = tar_map($shifts) do k
    (
        target(:shifted, cleaned -> cleaned .+ k),
        target(:shift_summary, shifted -> summarize(shifted)),
    )
end

tar_pipeline(
    target(:raw_file, () -> "data/raw.csv"; format = :file),
    target(:raw, raw_file -> parse.(Float64, split(read(raw_file, String)))),
    target(:cleaned, raw -> clean(raw)),
    target(:grid, () -> $grid),
    target(:scores, (grid, cleaned) -> score(Params(grid), cleaned); pattern = :grid),
    target(:report, scores -> summarize(scores)),
    shifts,
    # the generated names are not argument names, so their values come positionally
    tar_combine(
        :shifted_total,
        (summaries...) -> sum(s.total for s in summaries),
        shifts.shift_summary,
    ),
)
"""

# The v0.2 features, one target each.
features_targets(::FunctionStyle; seed, fast_format) = """
tar_pipeline(
    target(:mus, () -> [0.0, 10.0, 20.0]),
    target(:sizes, () -> [1, 2]),
    # seeded branches: the same draws however and wherever they are built
    target(:draws, mus -> simulate(mus); pattern = :mus),
    # pattern combinators
    target(:combos, (mus, sizes) -> mus * sizes; pattern = Cross(:mus, :sizes)),
    target(:paired, (mus, sizes) -> (mus, sizes); pattern = Map(Head(:mus, 2), :sizes)),
    target(:sampled, mus -> mus; pattern = Sample(:mus, 2)),
    # batched replication: 2 branches of 5 reps
    tar_rep(:sims, () -> randn(); batches = 2, reps = 5),
    # error modes and retries
    target(:fragile_fits, mus -> fragile(mus); pattern = :mus, error = :trim),
    target(:maybe, () -> maybe_value(); error = :null),
    target(:uses_maybe, maybe -> maybe === nothing ? "no value" : "value \$maybe"),
    target(:flaky, () -> flaky(); retries = 2),
    # warnings are recorded
    target(:noisy, draws -> noisy_sum(draws)),
    # concurrency options
    target(:exclusive, () -> tar_slots(); slots = :all),
    target(:on_main, () -> "ran in the calling task"; deployment = :main),
    # cues and formats
    target(:cached_total, mus -> total(mus); cue = Cue(code = false)),
    target(:fast, () -> Dict(:a => [1, 2, 3]); format = :$fast_format);
    seed = $seed,
)
"""

if abspath(PROGRAM_FILE) == @__FILE__
    run_walkthroughs(ARGS) || exit(1)
end
