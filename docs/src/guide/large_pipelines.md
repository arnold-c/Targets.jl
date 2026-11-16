# Large pipelines

Every `tar_make`, `tar_outdated` and `tar_read` (unless it skips its check) starts by
loading `_targets.jl` into a fresh module. With hundreds of targets, how the script is laid
out decides how long that takes.

## What a load costs

Julia prepares ("lowers") each top-level statement of a file as a whole, before running it,
in a time that grows with the square of the number of functions the statement contains.
Every target contains at least one: the lambda in `target(:b, a -> clean(a))`, or the code
`@target` generates. So a single statement holding every target gets slow quickly, while
the same targets spread over many statements stay fast.

What counts as one statement:

```julia
# one statement holding every target
tar_pipeline(
    target(:raw, () -> load_raw("data.csv")),
    target(:cleaned, raw -> clean(raw)),
    target(:model, cleaned -> fit_model(cleaned)),
)

# one statement per target, combined at the end
raw_t     = target(:raw, () -> load_raw("data.csv"))
cleaned_t = target(:cleaned, raw -> clean(raw))
model_t   = target(:model, cleaned -> fit_model(cleaned))
tar_pipeline([raw_t, cleaned_t, model_t])
```

A `@pipeline` or `@targets` block written at the top level of `_targets.jl`, or of a file
it loads with `include`, is split automatically: each line runs as its own statement, with
the same targets and hashes. Blocks inside functions cannot be split.

Warm load times for a chain of trivial targets, on one machine:

| Layout | 100 targets | 400 targets |
| --- | --- | --- |
| function form, one `tar_pipeline(...)` call | 0.13 s | 1.9 s |
| function form, one statement per target | 0.03 s | 0.11 s |
| `@pipeline` at top level (split automatically) | 0.31 s | 1.3 s |
| function form, built inside a function | 1.0 s | 7.0 s |
| `@pipeline`, built inside a function | 1.5 s | 14 s |

The macro form does more work per target than the function form (it analyses each
expression, and compiles a small closure per target to look up the names it uses), but the
automatic split makes it faster than a single large `tar_pipeline(...)` call.

## Recommendations

- **Write large pipelines at the top level of `_targets.jl`** (or of files it `include`s),
  not inside a function. A function that returns a fragment is fine when the fragment is
  small.
- **In the function form, split the targets over several statements**: one per target, or
  one vector per stage of the analysis, combined with `tar_pipeline`.
- **Generate repeated targets instead of writing them out**: static and dynamic branching
  cost the same however many targets they produce, because the template is written once
  (see [Branching](branching.md)).
- **Skip the check when reading many values**: `tar_read(:x; on_outdated = :ignore)`, or the
  `on_outdated = "ignore"` preference, reads without loading the script at all. `@tar_load a
  b c` loads it once for all three.
- **Load files with a plain `include("file.jl")`** in `_targets.jl`. `Base.include(...)` and
  Revise's `includet` bypass the automatic split.
