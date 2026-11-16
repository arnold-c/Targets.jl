# Kinds of targets

## Values

By default a target's value is stored with JLD2 in the store (`_targets/` at the project
root). Even constants are targets, so changing a setting rebuilds exactly its consumers:

```julia
@target settings = (alpha = 0.05, n_boot = 1000)
```

`format` chooses another storage format, by name or as a [`StorageFormat`](@ref) value with
options:

| `format` | Stores | Needs |
| --- | --- | --- |
| `:jld2` (default) | any value, with JLD2 | |
| `:jls` | any value, with Julia's `Serialization`: fast, but tied to the Julia version, so an upgrade rebuilds the target | |
| `:arrow`, [`ArrowFormat`](@ref)`(; compress)` | Tables.jl tables, as Arrow IPC files | `using Arrow` |
| `:parquet`, [`ParquetFormat`](@ref)`()` | Tables.jl tables, as Parquet files | `using Parquet2` |
| `:csv`, [`CSVFormat`](@ref)`(; delim)` | Tables.jl tables, as CSV text | `using CSV` |

Reading an Arrow or Parquet target returns the package's table type; use
`DataFrame(tar_read(:x))` for a data frame. A package can add a format by defining the
methods listed under [`StorageFormat`](@ref).

A rebuilt value is compared by the hash of its stored file. A type whose stored bytes are not
deterministic can define `Targets.value_hash(x)`, returning a string to hash instead.

## Files

A file target (`format = :file`) returns a path, a vector of paths, or a directory. Its
value is the path, which consumers receive, and its contents decide what rebuilds:

```julia
@target raw_file = "data/raw.csv"  format = :file                  # an input file
@target raw      = CSV.read(raw_file, DataFrame)
@target figure   = save_plot(model, "output/fit.png")  format = :file   # an output file
```

- Editing an input file rebuilds its consumers; touching it without changing its contents
  does not.
- Deleting or editing an output file rebuilds the target that wrote it.
- Paths are relative to the project root, which is the working directory during a build.
- Files are re-checked on every run, cheaply: a file whose size and modification time are
  unchanged is not hashed again.

## URLs

A URL target (`format = :url`) returns one or more URLs. Nothing is downloaded: each URL is
checked with an HTTP `HEAD` request (its ETag, or else Last-Modified and Content-Length) on
every run, and consumers, which receive the URL, rebuild when it changes. When a URL cannot
be reached, the last check is kept with a warning, so working offline neither fails nor
rebuilds anything.

## Quarto reports

A report renders one Quarto document with the `quarto` CLI:

```julia
@pipeline begin
    @target model   = fit_model(clean_data)
    @quarto report  = "reports/report.qmd"
    @quarto "reports/appendix.qmd"  params = (draft = true,)   # named :appendix
end
# or, in the function form:
tar_quarto(:report, "reports/report.qmd"; quarto_args = ["--to", "pdf"])
```

Its dependencies are the targets the document reads with `tar_read(:name)` or
`@tar_load name`. They are found without running anything, in its Julia cells, inline
`` `{julia} ...` `` code, documents it includes with Quarto's `include` shortcode, and Julia files its
code loads with `include("analysis.jl")`, recursively. Add any whose names are computed with
`deps = [...]`, and computed include paths with `extra_files`.

The report is rebuilt when one of those targets changes, when the text of the document or
an included file changes, or when an output file is deleted or edited. Code loaded from
packages (`using MyAnalysis`) is not tracked. `tar_read(:report)` gives the output paths
followed by the source paths. Paths are relative to `_targets.jl`.

Inside the document, `tar_read` and `@tar_load` read the store of the build that is
rendering it (this needs Quarto's `engine: julia`). When rendering by hand, name the store
in the front matter, relative to the document, or set a `store` preference for the project:

```yaml
engine: julia
targets-store: ../_targets
```

Each render restarts Quarto's Julia worker for the document, so edited code is never stale
(`restart = false` keeps it, which is faster). Quarto's output is shown only when a render
fails. `quiet = false` prints it while the render runs, but only when the build runs one
job at a time, since the output of concurrent renders would interleave. Quarto projects
(`_quarto.yml`) and rendering one document several times with different parameters are not
supported.
