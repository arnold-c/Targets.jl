# What triggers a rebuild

A target is rebuilt when, in order:

1. you force it (`tar_make(force = true)`, `cue = :always`),
2. it has never been built, or its object or files are missing,
3. its last build failed,
4. the **source of its function** changed (comments, whitespace and moving code do not
   count),
5. the source of any **user function, type or global it reaches** changed (recursively,
   all methods),
6. its dependencies changed, or
7. an upstream value changed, or, for file and URL targets, a file's contents or a URL
   changed.

`tar_outdated()` reports the first reason that applies to each target.

A rebuilt target whose output is identical stops the change there: its consumers see an
unchanged value and are not rebuilt (*early cutoff*).

## How code is tracked

Hashes come from parsed source, not lowered code, so upgrading Julia does not by itself
rebuild anything.

- Methods that a macro or `struct` generates (`@kwdef` constructors, default constructors,
  `@eval`) are hashed from the macro call or `struct` that generates them, and user-defined
  macros are followed like functions.
- Only code whose source cannot be found (defined with `eval`, or at the REPL without
  Revise) falls back to lowered code, and is flagged.
- Hashes do not depend on the numbers Julia gives the functions it generates (keyword
  bodies such as `#f#12`, anonymous functions and closures). Generated functions, including
  lambdas stored in globals or captured by a target, are identified by what they do.
- A name a function binds itself, such as an argument or a comprehension variable, is never
  mistaken for a global of the same name.

"User code" is anything under the project directory, plus locations listed in
`tar_pipeline(...; track = [MyLabUtils, "../shared"])` (or `@pipeline track = [...]`).
Installed packages are covered by a Manifest check: when `Manifest.toml` changes,
`tar_make` names the packages that moved, and `track_manifest = true` rebuilds everything.

Known limits: code reached only through dynamic dispatch on runtime values
(`getfield(mod, sym)`), `@generated` functions, and several lambdas with identical
arguments on one line (edits rebuild all of them). `cue = :always` and
`tar_make(force = true)` cover these.

## Cues

A target's `cue` changes which of these rules apply:

| `cue` | Rebuilds |
| --- | --- |
| `:thorough` (default) | by all the rules above |
| `:always` | on every build |
| `:never` | only when it is missing |
| [`Cue`](@ref)`(code = false)` | by all the rules except those turned off: `command` (its own code and seed), `code` (code it calls), `depend` (upstream changes) and `file` (its files or URLs) |
| [`cue_age`](@ref)`(Day(7))` | also once its last build is older than the period, for scraped or remote data |
| [`cue_force`](@ref)`(condition)` | also whenever `condition` is true when the pipeline is loaded |

For example, `cue = Cue(code = false)` keeps an expensive simulation from rebuilding after
a refactor of the code it calls. Missing or failed targets are always rebuilt.

## Forgetting results

- [`tar_invalidate`](@ref)`(names = [:a])` forgets a target's metadata, so it rebuilds on
  the next run, but keeps its stored value, so `tar_read` still works.
- [`tar_delete`](@ref)`(names = [:a])` deletes its value and metadata.
- [`tar_prune`](@ref)`()` deletes stored targets that are no longer in the pipeline.
- [`tar_destroy`](@ref)`()` deletes the whole store, after asking.
