## Quarto documents
##
## Reading a `.qmd` without Quarto: its executable Julia code, the files it
## includes, its front matter's output formats, and the targets its code reads
## with `tar_read` / `@tar_load`. This is what lets a report's dependencies be
## known when the pipeline is built, with no Quarto call.

const FENCE = r"^\s*(`{3,}|~{3,})\s*(.*?)\s*$"
const JULIA_CELL = r"^\{julia(?:[\s,}]|$)"
const INLINE_JULIA = r"`\{julia\}\s+([^`]+)`"
const INCLUDE_SHORTCODE = r"\{\{<\s*include\s+(\"[^\"]+\"|'[^']+'|[^\s>]+)\s*>\}\}"
const EVAL_FALSE = r"^\s*#\|\s*eval\s*:\s*false\s*$"

# Untyped `m`: packages such as StringViews return their own match types.
"Capture group `i` of regex match `m`, or an empty string if it did not participate."
capture(m, i::Integer) = something(m.captures[i], "")

"""
    QuartoText(cells, inline, prose)

The parts of a Quarto document: the code of its executable Julia cells, its
inline Julia expressions, and the lines outside code blocks.
"""
struct QuartoText
    cells::Vector{String}
    inline::Vector{String}
    prose::Vector{String}
end

"Whether a fence line `closing` ends the block opened by `fence`."
closes(fence::AbstractString, closing) = isempty(capture(closing, 2)) &&
    capture(closing, 1)[1] == fence[1] &&
    length(capture(closing, 1)) >= length(fence)

"""
    quarto_text(text)

Split a Quarto document into its executable Julia cells (those not marked
`#| eval: false`), inline `` `{julia} ...` `` expressions and the remaining
lines. Code in other blocks (including non-executable ```` ```julia ````
blocks) is left out of all three.
"""
function quarto_text(text::AbstractString)
    cells, inline, prose = String[], String[], String[]
    fence = nothing # the opening fence of the block we are in
    cell = nothing  # lines of the Julia cell we are in
    for line in eachsplit(text, '\n')
        m = match(FENCE, line)
        if fence === nothing
            if m === nothing
                push!(prose, line)
                append!(
                    inline,
                    (strip(capture(c, 1)) for c in eachmatch(INLINE_JULIA, line))
                )
            else
                fence = capture(m, 1)
                cell = occursin(JULIA_CELL, capture(m, 2)) ? String[] : nothing
            end
        elseif m !== nothing && closes(fence, m)
            cell === nothing ||
                any(l -> occursin(EVAL_FALSE, l), cell) ||
                push!(cells, join(cell, '\n'))
            fence, cell = nothing, nothing
        elseif cell !== nothing
            push!(cell, line)
        end
    end
    return QuartoText(cells, inline, prose)
end

"Paths of the files `prose` includes with `{{< include ... >}}`, as written."
function quarto_includes(prose::Vector{String})
    return String[
        strip(capture(m, 1), ['"', '\''])
        for line in prose
        for m in eachmatch(INCLUDE_SHORTCODE, line)
    ]
end

is_julia_file(file::AbstractString) = endswith(lowercase(file), ".jl")

"""
    source_code(file)

The executable Julia code of a source file: all of a `.jl` file, or the
executable cells and inline code of a document.
"""
function source_code(file::AbstractString)
    text = read(file, String)
    is_julia_file(file) && return [text]
    parts = quarto_text(text)
    return vcat(parts.cells, parts.inline)
end

"""
    quarto_sources(path; dynamic = String[])

The absolute paths of a document and of every file it uses, recursively, in
the order they are first reached: documents it includes with
`{{< include >}}`, and Julia files its code (or theirs) loads with
`include("...")` or `includet("...")`. As in Quarto, paths in a document,
included documents too, are relative to the directory of the top document
(`root`); paths in a Julia file are relative to that file. An include that
does not exist is an error. Includes whose path is not a literal are pushed
to `dynamic`, as text.
"""
function quarto_sources(
    path::AbstractString,
    found = String[];
    dynamic::Vector{String} = String[],
    root::AbstractString = dirname(normpath(abspath(path))),
)
    file = normpath(abspath(path))
    file in found && return found
    isfile(file) || error("Quarto document `$file` does not exist")
    push!(found, file)
    linked = is_julia_file(file) ?
        String[] :
        quarto_includes(quarto_text(read(file, String)).prose)
    for code in source_code(file)
        paths, dyn = code_includes(code; file)
        append!(linked, paths)
        append!(dynamic, dyn)
    end
    base = is_julia_file(file) ? dirname(file) : root
    for inc in linked
        target = normpath(joinpath(base, inc))
        isfile(target) || error("`$file` includes `$inc`, which does not exist")
        quarto_sources(target, found; dynamic, root)
    end
    return found
end

## Dependencies

# `name`, `Mod.name` or a `GlobalRef` to `name`.
function is_named(ex, name::Symbol)
    ex === name && return true
    ex isa GlobalRef && return ex.name === name
    return Meta.isexpr(ex, :.) && length(ex.args) == 2 && ex.args[2] == QuoteNode(name)
end

positional_args(call::Expr) = [
    a
    for a in call.args[2:end]
    if !Meta.isexpr(a, (:parameters, :kw))
]

"""
    read_targets!(found, dynamic, ex)

Collect into `found` the target names `ex` reads with `tar_read(:name, ...)`
or `@tar_load name...` (plain or qualified), and into `dynamic` the reads
whose names are not literals.
"""
function read_targets!(found::Vector{Symbol}, dynamic::Vector{String}, ex)
    ex isa Expr || return nothing
    Meta.isexpr(ex, :quote) && return nothing
    if Meta.isexpr(ex, :call) && is_named(ex.args[1], :tar_read)
        args = positional_args(ex)
        name = isempty(args) ? nothing : args[1]
        name isa QuoteNode && name.value isa Symbol ?
            push!(found, name.value) :
            push!(dynamic, string(ex))
    elseif Meta.isexpr(ex, :macrocall) && is_named(ex.args[1], Symbol("@tar_load"))
        for a in ex.args[3:end]
            a isa LineNumberNode && continue
            Meta.isexpr(a, :(=)) && continue # an option such as `store = ...`
            a isa Symbol ? push!(found, a) : push!(dynamic, string(ex))
        end
        return nothing
    end
    foreach(a -> read_targets!(found, dynamic, a), ex.args)
    return nothing
end

const INCLUDE_CALLS = (:include, :includet)

# A path written as a literal: `"a.jl"`, or `joinpath(@__DIR__, "a", "b.jl")`
# (relative to the including file either way). `nothing` otherwise.
literal_path(p::AbstractString) = String(p)
function literal_path(p::Expr)
    (Meta.isexpr(p, :call) && is_named(p.args[1], :joinpath)) || return nothing
    parts = p.args[2:end]
    (
        !isempty(parts) &&
            Meta.isexpr(parts[1], :macrocall) &&
            parts[1].args[1] === Symbol("@__DIR__") &&
            all(x -> x isa AbstractString, parts[2:end])
    ) ||
        return nothing
    return joinpath(String.(parts[2:end])...)
end
literal_path(_) = nothing

"""
    include_paths!(paths, dynamic, ex)

Collect into `paths` the files `ex` loads with `include("...")`,
`Base.include(mod, "...")` or `includet("...")`, and into `dynamic` the
includes (as text) whose path is not a literal.
"""
function include_paths!(paths::Vector{String}, dynamic::Vector{String}, ex)
    ex isa Expr || return nothing
    Meta.isexpr(ex, :quote) && return nothing
    if Meta.isexpr(ex, :call) && any(n -> is_named(ex.args[1], n), INCLUDE_CALLS)
        args = positional_args(ex)
        path = isempty(args) ? nothing : literal_path(args[end])
        path === nothing ? push!(dynamic, string(ex)) : push!(paths, path)
        return nothing
    end
    foreach(a -> include_paths!(paths, dynamic, a), ex.args)
    return nothing
end

"`(paths, dynamic)`: the files Julia `code` includes (see [`include_paths!`](@ref))."
function code_includes(code::AbstractString; file::AbstractString = "none")
    paths, dynamic = String[], String[]
    include_paths!(paths, dynamic, Meta.parseall(code; filename = file))
    return unique!(paths), unique!(dynamic)
end

"""
    code_reads(code; file = "none")

`(names, dynamic)`: the targets Julia `code` reads, in order of first use, and
the reads (as text) whose target name is not a literal. Code that does not
parse contributes what parses.
"""
function code_reads(code::AbstractString; file::AbstractString = "none")
    found, dynamic = Symbol[], String[]
    read_targets!(found, dynamic, Meta.parseall(code; filename = file))
    return unique!(found), unique!(dynamic)
end

"""
    quarto_reads(path)

`(names, dynamic)` for a document and the files it uses (see
[`code_reads`](@ref) and [`quarto_sources`](@ref)); `dynamic` also holds the
includes whose path is not a literal.
"""
function quarto_reads(path::AbstractString)
    found, dynamic = Symbol[], String[]
    for file in quarto_sources(path; dynamic)
        for code in source_code(file)
            names, dyn = code_reads(code; file)
            append!(found, names)
            append!(dynamic, dyn)
        end
    end
    return unique!(found), unique!(dynamic)
end

## Front matter and outputs

"The lines of a document's YAML front matter (empty if it has none)."
function front_matter(text::AbstractString)
    lines = split(text, '\n')
    (isempty(lines) || rstrip(lines[1]) != "---") && return String[]
    stop = findnext(l -> rstrip(l) in ("---", "..."), lines, 2)
    stop === nothing && return String[]
    return String.(lines[2:(stop - 1)])
end

unquote(s::AbstractString) = strip(strip(replace(s, r"\s+#.*$" => "")), ['"', '\''])

"The value of a top-level `key: value` line of the front matter, or `nothing`."
function front_matter_value(lines::Vector{String}, key::AbstractString)
    for l in lines
        m = match(Regex("^" * key * raw"\s*:\s*(.*)$"), l)
        m === nothing || return unquote(capture(m, 1))
    end
    return nothing
end

"""
    front_matter_formats(lines)

The output formats named by the front matter's `format` key: its value
(`format: pdf`), or the keys nested under it; `["html"]`, Quarto's default,
without one.
"""
function front_matter_formats(lines::Vector{String})
    i = findfirst(l -> occursin(r"^format\s*:", l), lines)
    i === nothing && return ["html"]
    inline = unquote(split(lines[i], ':'; limit = 2)[2])
    isempty(inline) || return [inline]
    formats = String[]
    indent = nothing
    for l in lines[(i + 1):end]
        isempty(strip(l)) && continue
        lead = length(match(r"^\s*", l).match)
        lead == 0 && break
        indent = something(indent, lead)
        m = match(r"^\s*-?\s*([A-Za-z0-9_+\-]+)\s*:?", l)
        lead == indent && m !== nothing && push!(formats, capture(m, 1))
    end
    return isempty(formats) ? ["html"] : formats
end

const FORMAT_EXTENSIONS = Dict(
    "html" => "html",
    "revealjs" => "html",
    "dashboard" => "html",
    "pdf" => "pdf",
    "typst" => "pdf",
    "beamer" => "pdf",
    "docx" => "docx",
    "odt" => "odt",
    "pptx" => "pptx",
    "epub" => "epub",
    "rtf" => "rtf",
    "ipynb" => "ipynb",
    "latex" => "tex",
    "gfm" => "md",
    "commonmark" => "md",
    "markdown" => "md",
    "md" => "md",
    "hugo-md" => "md",
    "docusaurus-md" => "md",
    "asciidoc" => "adoc",
    "rst" => "rst",
    "jats" => "xml",
)

"""
    format_extension(format)

The output file extension of a Quarto format: `markdown+emoji` is `markdown`,
and an extension format such as `acm-pdf` is its base format `pdf`. `nothing`
for an unknown format.
"""
function format_extension(format::AbstractString)
    base = first(split(format, '+'))
    for candidate in (base, first(split(base, '-')), last(split(base, '-')))
        haskey(FORMAT_EXTENSIONS, candidate) && return FORMAT_EXTENSIONS[candidate]
    end
    return nothing
end

"The formats chosen with `--to`/`-t` in `args`, or `nothing`."
function requested_formats(args::Vector{String})
    for (i, a) in enumerate(args)
        value = startswith(a, "--to=") ?
            a[6:end] :
            (a in ("--to", "-t") && i < length(args)) ? args[i + 1] : nothing
        (value === nothing || value == "all") && continue
        return String.(split(value, ','))
    end
    return nothing
end

## Report targets

"""
    QuartoReport

The function of a [`tar_quarto`](@ref) target. Called during a build, it renders
its document with the `quarto` CLI and returns the output files followed by the
source files (the document, the files it includes and `extra_files`), all of
which the file target then tracks by content. Paths are absolute; `base` is the
directory relative paths were given from. `runner(args, dir)` runs Quarto with
the command-line arguments `args` in `dir` (`nothing`: the `quarto` CLI).
"""
struct QuartoReport
    path::String
    base::String
    extra_files::Vector{String}
    output::Vector{String}
    params::Vector{String}
    quarto_args::Vector{String}
    quarto::String
    restart::Bool
    quiet::Bool
    runner::Any
end

# A report reads the store itself (see `passes_values`).
passes_values(::QuartoReport) = false

portable(r::QuartoReport, path::AbstractString) = replace(
    relpath(path, r.base),
    '\\' => '/',
)

# What goes into a report's command hash: its options, with paths relative to
# `base` so that a moved project does not rebuild, and without the machine's
# Quarto location, the runner or `quiet`, which do not change the output.
closure_captures(r::QuartoReport) = (
    path = portable(r, r.path),
    extra_files = [portable(r, f) for f in r.extra_files],
    output = [portable(r, f) for f in r.output],
    params = r.params,
    quarto_args = r.quarto_args,
    restart = r.restart,
)

"""
    expected_outputs(r::QuartoReport)

The files rendering `r` writes: `output` when given, else the document's stem
with the extension of each format chosen by `--to` in `quarto_args` or listed
in the front matter (`html` by default).
"""
function expected_outputs(r::QuartoReport)
    isempty(r.output) || return r.output
    lines = front_matter(read(r.path, String))
    front_matter_value(lines, "output-file") === nothing ||
        error(
            "`$(r.path)` sets `output-file`, so pass the files it writes to tar_quarto as `output`",
        )
    formats = something(requested_formats(r.quarto_args), front_matter_formats(lines))
    stem = splitext(r.path)[1]
    return unique([stem * "." * output_extension(f) for f in formats])
end

function output_extension(format::AbstractString)
    ext = format_extension(format)
    ext === nothing &&
        error(
            "cannot tell which file Quarto format `$format` writes; pass the files as `output`",
        )
    return ext
end

"The command-line arguments that render `r` into `store`'s build."
function quarto_cli_args(r::QuartoReport, store::AbstractString)
    args = ["render", r.path]
    r.restart && push!(args, "--execute-daemon-restart")
    push!(args, "--cache-refresh")
    append!(args, ["-M", "targets-store:" * store, "-M", "targets-rendering:true"])
    foreach(p -> append!(args, ["-P", p]), r.params)
    return append!(args, r.quarto_args)
end

"""
    run_quarto(quarto, args, dir; echo = devnull)

Run the executable `quarto` with `args` in `dir`, copying its output (stdout
and stderr) to `echo` line by line as it arrives. A failure's error ends with
that output.
"""
function run_quarto(
    quarto::AbstractString,
    args::Vector{String},
    dir::AbstractString;
    echo::IO = devnull,
)
    exe = Sys.which(quarto)
    exe === nothing &&
        error(
            "cannot find the Quarto CLI `$quarto`; install it from https://quarto.org or " *
                "pass its path as `quarto = ...`",
        )
    output = IOBuffer()
    pipe = Pipe()
    process = run(
        pipeline(Cmd(`$exe $args`; dir); stdout = pipe, stderr = pipe);
        wait = false,
    )
    close(pipe.in)
    try
        for line in eachline(pipe; keep = true)
            write(output, line)
            write(echo, line)
            flush(echo)
        end
        wait(process)
    catch
        kill(process) # interrupted: do not leave Quarto running
        rethrow()
    end
    success(process) || error("quarto render failed:\n" * last(String(take!(output)), 3000))
    return nothing
end

# Where a render's output goes: `stdout` only when asked for and the build runs
# one job at a time, since concurrent renders would interleave their output.
quarto_echo(r::QuartoReport) = r.quiet || BUILD_JOBS[] > 1 ? devnull : stdout

function (r::QuartoReport)(_...)
    place = RUNNING_PLACE[]
    store = place === nothing ? abspath(default_store_path()) : place.store
    root = place === nothing ? project_root() : place.root
    sources = vcat(quarto_sources(r.path), r.extra_files)
    missing_extra = filter(!ispath, r.extra_files)
    isempty(missing_extra) ||
        error("extra files of the report do not exist: $(join(missing_extra, ", "))")
    before = map(path_hash, sources)
    outputs = expected_outputs(r)
    args = quarto_cli_args(r, store)
    if r.runner === nothing
        run_quarto(r.quarto, args, root; echo = quarto_echo(r))
    else
        r.runner(args, root)
    end
    map(path_hash, sources) == before ||
        error("`$(r.path)` or a file it uses changed while it was rendered; build again")
    absent = filter(!ispath, outputs)
    isempty(absent) ||
        error(
            "Quarto did not write $(join(absent, ", ")); pass the files the document " *
                "writes as `output`",
        )
    support = splitext(r.path)[1] * "_files"
    isempty(r.output) && isdir(support) && push!(outputs, support)
    return vcat(outputs, sources)
end

"The directory relative paths in a pipeline script are taken from: the script's."
function script_dir()
    path = Base.source_path(nothing)
    return path === nothing ? project_root() : dirname(path)
end

"A target name from a document's file name: `reports/summary.qmd` is `:summary`."
function report_name(path::AbstractString)
    stem = splitext(basename(path))[1]
    Base.isidentifier(stem) ||
        throw(ArgumentError(
            "cannot name a target after `$path`; give a name, e.g. tar_quarto(:report, \"$path\")",
        ))
    return Symbol(stem)
end

"""
    param_args(name, params)

The `key:value` arguments of Quarto's `-P` for the parameters of report `name`,
sorted by key. Values are numbers, booleans, strings or symbols; strings are
quoted so that Quarto reads them as strings.
"""
param_args(name::Symbol, params) = sort!(
    String[string(k, ":", param_value(name, k, v)) for (k, v) in pairs(params)]
)

function param_value(name::Symbol, key, value)
    Base.isidentifier(string(key)) ||
        throw(ArgumentError("report `$name`: parameter `$key` is not a valid Julia name"))
    value isa Bool && return string(value)
    (value isa Integer || (value isa AbstractFloat && isfinite(value))) &&
        return string(value)
    value isa Union{AbstractString, Symbol} &&
        return "\"" * escape_string(string(value), '"') * "\""
    throw(ArgumentError(
        "report `$name`: parameter `$key` must be a number, boolean, string or symbol, " *
            "got `$(repr(value))`",
    ))
end

as_paths(base, paths::AbstractString) = as_paths(base, [paths])
as_paths(base, paths) = String[normpath(joinpath(base, p)) for p in paths]

"""
    tar_quarto([name,] path; deps = [], extra_files = [], output = nothing,
               params = (;), quarto_args = [], quarto = "quarto", restart = true,
               quiet = true, kwargs...)

A target that renders the Quarto document `path` (a `.qmd` file) with the
`quarto` CLI. `name` defaults to the file's stem (`reports/summary.qmd` is
`:summary`). Relative paths are relative to the directory of the pipeline
script (`_targets.jl`).

Its dependencies are the targets the document's executable Julia cells (and
inline Julia code, the documents it includes with Quarto's `include` shortcode,
and the Julia files its code loads with `include("file.jl")`, `includet` or
`include(joinpath(@__DIR__, ...))`, recursively) read with `tar_read(:name)`
or `@tar_load name`, found without running anything, plus `deps`. Cells
marked `#| eval: false` are skipped. Reads whose name, and includes whose path,
is not a literal give a warning: list those in `deps` and `extra_files`. The
values are not passed in: the document reads them from the store, which is the
one `tar_make` is building (see [`tar_read`](@ref)).

It is a file target whose files are the outputs followed by the document, the
files it includes (documents and Julia files) and `extra_files` (e.g. a
bibliography). So it is rebuilt when any of them changes in content (not when
the files are only touched), when an output is deleted, or when a target it
reads changes. Code the document loads from packages (`using MyAnalysis`) is
not tracked; code in the Julia files it includes is, by their text.

The outputs are `output` when given, else the document's stem with the
extension of each format in its front matter (or chosen with `--to` in
`quarto_args`), `html` by default, plus the `<stem>_files` directory if Quarto
writes one. `params` (a `NamedTuple` or `Dict` of numbers, booleans, strings
and symbols) sets the document's parameters (`quarto render -P key:value`),
which it declares with defaults under `params:` in its front matter; changing
one rebuilds the report. Each render restarts Quarto's Julia worker for the document, so
edited code is never stale (`restart = false` keeps it, which is faster),
and refreshes Quarto's cache. `quiet = false` prints Quarto's output in the
REPL while it renders, but only when the build runs one job at a time (`jobs = 1`,
the default): with more jobs the output of concurrent renders would interleave, so
it stays quiet without editing the pipeline. By default the output is shown only
if the render fails. Neither
changes when the report rebuilds. `quarto` is the Quarto executable. Other keyword
arguments go to [`target`](@ref) (`cue`, `error`, `retries`, ...).
"""
function tar_quarto(
    name::Symbol,
    path::AbstractString;
    deps = Symbol[],
    extra_files = String[],
    output = nothing,
    params = (;),
    quarto_args = String[],
    quarto::AbstractString = "quarto",
    restart::Bool = true,
    quiet::Bool = true,
    render = nothing,
    seed = nothing,
    kwargs...,
)
    for k in (:format, :pattern, :source)
        haskey(kwargs, k) &&
            throw(ArgumentError("tar_quarto `$name`: `$k` cannot be set for a report"))
    end
    base = script_dir()
    file = only(as_paths(base, path))
    endswith(lowercase(file), ".qmd") ||
        throw(ArgumentError("tar_quarto `$name`: `$path` is not a `.qmd` file"))
    isfile(file) || throw(ArgumentError("tar_quarto `$name`: `$file` does not exist"))
    report = QuartoReport(
        file,
        base,
        as_paths(base, extra_files),
        output === nothing ? String[] : as_paths(base, output),
        param_args(name, params),
        collect(String, quarto_args),
        String(quarto),
        restart,
        quiet,
        render,
    )
    expected_outputs(report) # report problems when the pipeline is built
    reads, dynamic = quarto_reads(file)
    isempty(dynamic) ||
        @warn "report `$name` reads targets or includes files whose names are not " *
            "literals, so they are not tracked; list them in `deps` or `extra_files`" calls = dynamic
    return target(
        name,
        report;
        deps = unique!(vcat(reads, collect(Symbol, deps))),
        format = :file,
        source = :(tar_quarto(1)),
        seed,
        kwargs...,
    )
end
tar_quarto(path::AbstractString; kwargs...) = tar_quarto(report_name(path), path; kwargs...)

"Reject two reports that render the same document: they would overwrite each other's outputs."
function check_reports(targets)
    seen = Dict{String, Symbol}()
    for t in targets
        t.f isa QuartoReport || continue
        other = get(seen, t.f.path, nothing)
        other === nothing ||
            throw(PipelineError(
                "targets `$other` and `$(t.name)` both render `$(t.f.path)`; a document can " *
                    "only be rendered by one target",
            ))
        seen[t.f.path] = t.name
    end
end

## Inside a notebook

"""
    notebook_options()

The options of the Quarto notebook this code runs in, from the `julia`
engine's `QuartoNotebookWorker.notebook_options()`, or `nothing` outside a
notebook.
"""
function notebook_options()
    isdefined(Main, :QuartoNotebookWorker) || return nothing
    worker = getfield(Main, :QuartoNotebookWorker)
    (worker isa Module && isdefined(worker, :notebook_options)) || return nothing
    options = try
        Base.invokelatest(getfield(worker, :notebook_options))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    return options isa AbstractDict ? options : nothing
end

"The value of document metadata `key` in notebook `options` (`nothing` if unset)."
function notebook_value(options::AbstractDict, key::AbstractString)
    format = get(options, "format", nothing)
    metadata = format isa AbstractDict ? get(format, "metadata", nothing) : nothing
    metadata isa AbstractDict && haskey(metadata, key) && return metadata[key]
    return get(options, key, nothing)
end
notebook_value(::Nothing, key::AbstractString) = nothing

"The directory of the notebook being run: its document's, or the working directory."
function notebook_dir()
    path = Base.source_path(nothing)
    (path !== nothing && endswith(lowercase(path), ".qmd")) && return dirname(path)
    return pwd()
end

"""
    notebook_store(options = notebook_options(), dir = nothing)

The store named by the notebook's `targets-store` metadata, relative to `dir`
(by default the notebook's directory):
the store of the `tar_make` rendering it (which passes an absolute path), else
the document's front matter. `nothing` outside a notebook or without one.
"""
function notebook_store(options = notebook_options(), dir = nothing)
    value = notebook_value(options, "targets-store")
    value isa AbstractString || return nothing
    return normpath(joinpath(something(dir, notebook_dir()), expanduser(value)))
end

"Whether the notebook is being rendered by `tar_make` (see [`tar_quarto`](@ref))."
rendered_by_make(options = notebook_options()) = notebook_value(
    options,
    "targets-rendering",
) ===
    true

@testitem "quarto_text keeps executable Julia cells, inline code and prose" begin
    using Targets: quarto_text
    doc = """
    ---
    title: x
    ---
    Text with `{julia} tar_read(:n)` inline.

    ```{julia}
    #| label: a
    x = tar_read(:a)
    ```

    ```julia
    tar_read(:not_executed)
    ```

    ````{julia}
    #| eval: false
    tar_read(:skipped)
    ````

    ~~~{julia echo=false}
    ```
    y = 1
    ~~~

    ```{python}
    z = 2
    ```
    """
    parts = quarto_text(doc)
    @test parts.cells == ["#| label: a\nx = tar_read(:a)", "```\ny = 1"]
    @test parts.inline == ["tar_read(:n)"]
    @test any(contains("Text with"), parts.prose)
    @test !any(contains("not_executed"), parts.prose)
end

@testitem "property: quarto_text finds exactly the cells, inline code and prose written" setup = [
    Properties,
] begin
    using Targets: quarto_text, quarto_includes

    # Prose: plain text, inline Julia and include shortcodes, none starting a fence.
    text(chars, n) = Data.Text(Data.SampledFrom(collect(chars)); max_len = n)
    none = String[]
    segment = Data.OneOf(
        map(s -> (text = s, inline = none, includes = none), text("ab (),.:", 6)),
        map(
            (h, t) -> (text = "`{julia} $h$t`", inline = [strip("$h$t")], includes = none),
            Data.SampledFrom(['a', 'x']),
            text("ab (:)", 5),
        ),
        map(
            (name, quote_) -> (
                text = "{{< include $quote_$name.qmd$quote_ >}}",
                inline = none,
                includes = ["$name.qmd"],
            ),
            map(s -> "f" * s, text("ab_", 3)),
            Data.SampledFrom(["", "\"", "'"]),
        ),
    )
    prose = map(Data.Vectors(segment; max_size = 3)) do segments
        return (
            lines = [join((s.text for s in segments), " ")],
            cells = none,
            inline = reduce(vcat, (s.inline for s in segments); init = none),
            includes = reduce(vcat, (s.includes for s in segments); init = none),
            prose = [join((s.text for s in segments), " ")],
        )
    end

    # A fenced block. Its body holds code, `#| eval: false` lines and fence-like
    # lines that do not close it: shorter, of the other character, or with an
    # info string. It is a cell if its info string makes it executable Julia.
    infos = [
        ("{julia}", true),
        ("{julia echo=false}", true),
        ("{julia, label}", true),
        ("julia", false),
        ("{python}", false),
        ("", false),
        ("{julialike}", false),
    ]
    body_line = Data.OneOf(
        map(s -> (_, _) -> "x" * s, text("ab =(1)", 6)),
        map(s -> (_, _) -> s, Data.SampledFrom(["#| eval: false", "  #|eval :false "])),
        Data.Just((c, n) -> c^(n - 1)),
        Data.Just((c, n) -> (c == '`' ? '~' : '`')^n),
        Data.Just((c, n) -> c^n * "{julia}"),
    )
    block = @composed (
        char = Data.SampledFrom(['`', '~']),
        len = Data.Integers(3, 5),
        indent = Data.Integers(0, 3),
        info = Data.SampledFrom(infos),
        body = Data.Vectors(body_line; max_size = 4),
        longer = Data.Integers(0, 2),
        trailing = Data.Integers(0, 2),
    ) -> begin
        lines = [render(char, len) for render in body]
        executable = last(info) && !any(l -> occursin("eval", l), lines)
        (
            lines = [
                " "^indent * char^len * first(info)
                lines
                " "^indent * char^(len + longer) * " "^trailing
            ],
            cells = executable ? [join(lines, '\n')] : none,
            inline = none,
            includes = none,
            prose = none,
        )
    end

    report = @check config = check_config(;
        max_examples = 500,
    ) rng = property_rng() function quarto_parts_are_found(parts = Data.Vectors(
        Data.OneOf(prose, block);
        max_size = 6,
    ))
        doc = join(reduce(vcat, (p.lines for p in parts); init = String[]), '\n')
        expected(field) = reduce(vcat, (getfield(p, field) for p in parts); init = String[])
        found = quarto_text(doc)
        isempty(parts) && return found.prose == [""]
        return found.cells == expected(:cells) &&
            found.inline == expected(:inline) &&
            found.prose == expected(:prose) &&
            quarto_includes(found.prose) == expected(:includes)
    end
    @test check_result(report).holds
end

@testitem "quarto_sources resolves document includes from the top document" begin
    using Targets: quarto_sources
    mktempdir() do dir
        mkpath(joinpath(dir, "parts"))
        mkpath(joinpath(dir, "code"))
        write(
            joinpath(dir, "report.qmd"),
            "A\n{{< include parts/_a.qmd >}}\n{{< include \"parts/_a.qmd\" >}}\n",
        )
        write(
            joinpath(dir, "parts", "_a.qmd"),
            "B\n{{< include parts/_b.qmd >}}\n```\n{{< include _no.qmd >}}\n```\n" *
                "```{julia}\ninclude(\"code/x.jl\")\n```\n",
        )
        write(joinpath(dir, "parts", "_b.qmd"), "C\n{{< include report.qmd >}}\n")
        write(joinpath(dir, "code", "x.jl"), "include(\"y.jl\")\n")
        write(joinpath(dir, "code", "y.jl"), "y = 1\n")
        @test quarto_sources(joinpath(dir, "report.qmd")) ==
            normpath.([
                joinpath(dir, "report.qmd"),
                joinpath(dir, "parts", "_a.qmd"),
                joinpath(dir, "parts", "_b.qmd"),
                joinpath(dir, "code", "x.jl"),
                joinpath(dir, "code", "y.jl"),
            ])
        # Not resolved from the including document: Quarto does not do that.
        write(joinpath(dir, "parts", "_c.qmd"), "{{< include _b.qmd >}}\n")
        write(joinpath(dir, "nested.qmd"), "{{< include parts/_c.qmd >}}\n")
        @test_throws "includes `_b.qmd`" quarto_sources(joinpath(dir, "nested.qmd"))
        write(joinpath(dir, "bad.qmd"), "{{< include missing.qmd >}}\n")
        @test_throws "includes `missing.qmd`" quarto_sources(joinpath(dir, "bad.qmd"))
        @test_throws "does not exist" quarto_sources(joinpath(dir, "none.qmd"))
    end
end

@testitem "code_reads finds tar_read and @tar_load names" begin
    using Targets: code_reads
    code = """
    using Targets
    a = tar_read(:a)
    b = Targets.tar_read(:b; store = "../_targets", on_outdated = :ignore)
    @tar_load c d
    Targets.@tar_load store = s e
    f(x) = tar_read(:a) + x
    g = tar_read(name)
    q = :(tar_read(:quoted))
    """
    names, dynamic = code_reads(code)
    @test names == [:a, :b, :c, :d, :e]
    @test dynamic == ["tar_read(name)"]
    @test code_reads("x = (") == (Symbol[], String[]) # unparsable code finds nothing
end

@testitem "quarto_reads covers cells, inline code and included files" begin
    using Targets: quarto_reads
    mktempdir() do dir
        write(
            joinpath(dir, "r.qmd"),
            """
        `{julia} tar_read(:n)`
        ```{julia}
        @tar_load model
        ```
        {{< include _x.qmd >}}
        """,
        )
        write(joinpath(dir, "_x.qmd"), "```{julia}\ntar_read(:extra)\ntar_read(:n)\n```\n")
        @test quarto_reads(joinpath(dir, "r.qmd")) == ([:model, :n, :extra], String[])
    end
end

@testitem "front matter gives the output formats and their extensions" begin
    using Targets:
        front_matter,
        front_matter_formats,
        front_matter_value,
        format_extension,
        requested_formats
    fm(text) = front_matter(text)
    @test front_matter("no front matter\n") == String[]
    @test front_matter_formats(fm("---\ntitle: x\n---\n")) == ["html"]
    @test front_matter_formats(fm("---\nformat: pdf # comment\n---\n")) == ["pdf"]
    @test front_matter_formats(fm("---\nformat: \"docx\"\n---\n")) == ["docx"]
    nested = "---\ntitle: x\nformat:\n  html:\n    toc: true\n    code-fold: true\n  typst: default\nengine: julia\n---\n"
    @test front_matter_formats(fm(nested)) == ["html", "typst"]
    @test front_matter_value(fm(nested), "engine") == "julia"
    @test front_matter_value(fm(nested), "output-file") === nothing
    @test format_extension("html") == "html"
    @test format_extension("typst") == "pdf"
    @test format_extension("acm-pdf") == "pdf"
    @test format_extension("markdown+emoji") == "md"
    @test format_extension("gfm-yaml_metadata_block") == "md"
    @test format_extension("something") === nothing
    @test requested_formats(["--to", "pdf"]) == ["pdf"]
    @test requested_formats(["--to=html,docx"]) == ["html", "docx"]
    @test requested_formats(["-P", "a:1"]) === nothing
end

@testmodule QuartoFixtures begin
    export report_pipeline, write_report

    "A pipeline script with a report on `report.qmd`, rendered by a fake renderer."
    report_pipeline(n = 1; unused = 2, options = "") = """
    function fake(args, dir)
        write(joinpath(dir, "args.txt"), join(args, "\\n"))
        write(splitext(args[2])[1] * ".html", "rendered: " * read(args[2], String))
    end
    p = tar_pipeline(
        target(:n, () -> $n),
        target(:unused, () -> $unused),
        tar_quarto(:report, "report.qmd"; render = fake$options),
    )
    """

    write_report(dir, text; name = "report.qmd") = write(joinpath(dir, name), text)
end

@testitem "a report rebuilds when its text, a target it reads or its output changes" setup = [
    SourceFixtures,
    QuartoFixtures,
] begin
    mktempdir() do dir
        doc(text) = "---\ntitle: r\n---\n$text\n\n```{julia}\ntar_read(:n)\n```\n"
        write_report(dir, doc("Hello"))
        @test build_source(report_pipeline(), dir).built == [:n, :unused, :report]
        @test read_values(dir, :report) == (["report.html", "report.qmd"],)
        @test read(joinpath(dir, "report.html"), String) == "rendered: " * doc("Hello")
        @test isempty(build_source(report_pipeline(), dir).built)
        touch(joinpath(dir, "report.qmd")) # a new modification time, same text
        @test isempty(build_source(report_pipeline(), dir).built)
        write_report(dir, doc("Hello again")) # prose only
        @test outdated_source(report_pipeline(), dir) ==
            [(name = :report, reason = :file_changed)]
        @test build_source(report_pipeline(), dir).built == [:report]
        @test build_source(report_pipeline(; unused = 3), dir).built == [:unused]
        @test build_source(report_pipeline(5; unused = 3), dir).built == [:n, :report]
        rm(joinpath(dir, "report.html"))
        @test build_source(report_pipeline(5; unused = 3), dir).built == [:report]
        write(joinpath(dir, "report.html"), "edited by hand")
        @test build_source(report_pipeline(5; unused = 3), dir).built == [:report]
    end
end

@testitem "a report's dependencies come from its code, and it renders into the build's store" setup = [
    SourceFixtures,
    QuartoFixtures,
] begin
    mktempdir() do dir
        report(extra = "") = """
        ```{julia}
        #| eval: false
        tar_read(:n)
        ```
        $extra
        {{< include _part.qmd >}}
        """
        write_report(dir, report())
        write_report(dir, "```{julia}\n@tar_load unused\n```\n"; name = "_part.qmd")
        m, _ = load_source(report_pipeline(); dir)
        p = Base.invokelatest(getproperty, m, :p)
        @test Targets.get_target(p, :report).deps == [:unused]
        @test build_source(report_pipeline(), dir).built == [:n, :unused, :report]
        @test read_values(dir, :report) == (["report.html", "report.qmd", "_part.qmd"],)
        args = readlines(joinpath(dir, "args.txt"))
        @test args[1:2] == ["render", joinpath(dir, "report.qmd")]
        @test "targets-store:" * joinpath(dir, "_targets") in args
        @test "targets-rendering:true" in args
        @test "--execute-daemon-restart" in args && "--cache-refresh" in args
        write_report(dir, "```{julia}\n@tar_load unused\n```\nmore\n"; name = "_part.qmd")
        @test build_source(report_pipeline(), dir).built == [:report] # an included file
        write_report(dir, report("`{julia} tar_read(:n)`"))
        @test outdated_source(report_pipeline(), dir) ==
            [(name = :report, reason = :deps_changed)]
        @test build_source(report_pipeline(), dir).built == [:report]
        build_source(report_pipeline(; options = ", restart = false"), dir)
        @test !("--execute-daemon-restart" in readlines(joinpath(dir, "args.txt")))
    end
end

@testitem "tar_quarto validates its document and options" setup = [JETChecks] begin
    using Targets: expected_outputs
    mktempdir() do dir
        qmd(name, text = "Hi\n") = (path = joinpath(dir, name); write(path, text); path)
        a = qmd("summary.qmd")
        t = tar_quarto(a)
        @test t.name == :summary &&
            t.format == :file &&
            isempty(t.deps) &&
            t.seed === nothing
        @test expected_outputs(t.f) == [joinpath(dir, "summary.html")]
        @test_call tar_quarto(a)
        @test_call tar_quarto(:x, a; deps = [:name], params = (n = 1,), quiet = false)
        @test expected_outputs(tar_quarto(a; quarto_args = ["--to", "pdf"]).f) ==
            [joinpath(dir, "summary.pdf")]
        b = qmd("multi.qmd", "---\nformat:\n  html: default\n  docx: default\n---\n")
        @test expected_outputs(tar_quarto(b).f) ==
            joinpath.(dir, ["multi.html", "multi.docx"])
        @test_throws "not a `.qmd`" tar_quarto(:x, qmd("x.md"))
        @test_throws "does not exist" tar_quarto(:x, joinpath(dir, "none.qmd"))
        @test_throws "cannot name a target" tar_quarto(qmd("01-intro.qmd"))
        o = qmd("o.qmd", "---\noutput-file: other\n---\n")
        @test_throws "output-file" tar_quarto(:x, o)
        @test tar_quarto(:x, o; output = joinpath(dir, "other.html")).f.output ==
            [joinpath(dir, "other.html")]
        @test_throws "format `weird`" tar_quarto(
            :x,
            qmd("w.qmd", "---\nformat: weird\n---\n"),
        )
        @test_throws "cannot be set" tar_quarto(a; format = :jld2)
        dyn = qmd("dyn.qmd", "```{julia}\ntar_read(name)\n```\n")
        t = @test_logs (:warn, r"not literals") tar_quarto(dyn; deps = [:name])
        @test t.deps == [:name]
        @test_throws "both render" tar_pipeline(tar_quarto(:r1, a), tar_quarto(:r2, a))
    end
end

@testitem "a report's command hash does not depend on where the project is" setup = [
    SourceFixtures,
] begin
    function report_hash(options = "")
        dir = mktempdir()
        write(joinpath(dir, "r.qmd"), "text")
        m, _ = load_source("t = tar_quarto(:r, \"r.qmd\"$options)"; dir)
        return Targets.command_hash(Base.invokelatest(getproperty, m, :t))
    end
    @test report_hash() == report_hash()
    @test report_hash().kind == :source
    @test report_hash() != report_hash("; quarto_args = [\"--to\", \"pdf\"]")
end

@testitem "notebooks find their store in their metadata" begin
    using Targets: notebook_store, notebook_options, rendered_by_make, default_store_path
    @test notebook_options() === nothing # not in a notebook
    @test notebook_store() === nothing
    @test !rendered_by_make()
    meta(pairs...) = Dict{String, Any}("format" => Dict{String, Any}("metadata" => Dict{
        String,
        Any,
    }(pairs...)))
    dir = joinpath("project", "reports")
    @test notebook_store(meta(), dir) === nothing
    @test notebook_store(meta("targets-store" => "../_targets"), dir) ==
        normpath(joinpath("project", "_targets"))
    absolute = abspath(joinpath("elsewhere", "_targets"))
    @test notebook_store(meta("targets-store" => absolute), dir) == absolute
    @test notebook_store(Dict{String, Any}("targets-store" => "s"), dir) ==
        joinpath(dir, "s")
    @test rendered_by_make(meta("targets-rendering" => true))
    @test !rendered_by_make(meta("targets-store" => "x"))
end

@testitem "the store preference sets the default store" begin
    using Targets: default_store_path, project_root
    @test default_store_path() == joinpath(project_root(), "_targets")
    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "[deps]\nTargets = \"ccd79084-dcf1-4aa0-8fea-6744ff5e7af6\"\n",
        )
        prefs(store) = write(
            joinpath(dir, "LocalPreferences.toml"),
            "[Targets]\nstore = $(repr(store))\n",
        )
        pushfirst!(LOAD_PATH, dir)
        try
            prefs(joinpath(dir, "store"))
            @test default_store_path() == joinpath(dir, "store")
            prefs("../shared/_targets")
            @test default_store_path() ==
                normpath(joinpath(project_root(), "..", "shared", "_targets"))
        finally
            popfirst!(LOAD_PATH)
        end
    end
end

@testitem "report parameters are passed to Quarto, and changing one rebuilds" setup = [
    SourceFixtures,
    QuartoFixtures,
] begin
    using Targets: param_args
    @test param_args(:r, (b = true, a = 0.5, c = "x \"y\"", d = :z, e = 3)) ==
        ["a:0.5", "b:true", "c:\"x \\\"y\\\"\"", "d:\"z\"", "e:3"]
    @test param_args(:r, Dict("k" => 1)) == ["k:1"]
    @test_throws "must be a number" param_args(:r, (a = [1, 2],))
    @test_throws "must be a number" param_args(:r, (a = NaN,))
    @test_throws "not a valid Julia name" param_args(:r, Dict("a-b" => 1))
    mktempdir() do dir
        write_report(dir, "---\nparams:\n  alpha: 0.1\n---\nText\n")
        code(alpha) = report_pipeline(; options = ", params = (alpha = $alpha,)")
        @test build_source(code(0.2), dir).built == [:n, :unused, :report]
        args = readlines(joinpath(dir, "args.txt"))
        i = findfirst(==("-P"), args)
        @test args[i + 1] == "alpha:0.2"
        @test isempty(build_source(code(0.2), dir).built)
        @test outdated_source(code(0.3), dir) ==
            [(name = :report, reason = :command_changed)]
        @test build_source(code(0.3), dir).built == [:report]
    end
end

@testitem "run_quarto streams the output it captures, and reports failures" begin
    using Targets: run_quarto
    if Sys.iswindows()
        @test_skip "needs sh" == ""
    else
        mktempdir() do dir
            echo = IOBuffer()
            script = "echo one; echo two 1>&2; pwd"
            @test run_quarto("sh", ["-c", script], dir; echo) === nothing
            lines = split(String(take!(echo)), '\n'; keepempty = false)
            @test sort(lines[1:2]) == ["one", "two"]
            @test realpath(lines[3]) == realpath(dir)                     # runs in `dir`
            @test run_quarto("sh", ["-c", "echo quiet"], dir) === nothing # default: devnull
            failure = "echo first; echo last 1>&2; exit 3"
            @test_throws r"quarto render failed:\n.*first.*last"s run_quarto(
                "sh",
                ["-c", failure],
                dir,
            )
            @test_throws "cannot find the Quarto CLI" run_quarto(
                "no-such-quarto",
                String[],
                dir,
            )
        end
    end
end

@testitem "quiet does not change a report's command hash" begin
    mktempdir() do dir
        path = joinpath(dir, "r.qmd")
        write(path, "text")
        loud = tar_quarto(:r, path; quiet = false)
        @test !loud.f.quiet && tar_quarto(:r, path).f.quiet
        @test Targets.command_hash(loud) == Targets.command_hash(tar_quarto(:r, path))
    end
end

@testitem "quiet = false prints only while the build runs one job at a time" begin
    using Targets: BUILD_JOBS, quarto_echo, with
    mktempdir() do dir
        path = joinpath(dir, "r.qmd")
        write(path, "text")
        loud = tar_quarto(:r, path; quiet = false).f
        quiet = tar_quarto(:r, path).f
        @test quarto_echo(loud) === stdout # outside a build
        @test quarto_echo(quiet) === devnull
        with(BUILD_JOBS => 4) do
            @test quarto_echo(loud) === devnull
        end
        # tar_make tells jobs how wide it runs
        seen = Int[]
        p = tar_pipeline(target(:w, () -> (push!(seen, BUILD_JOBS[]); 1)))
        for jobs in (1, 3)
            tar_make(p; store = joinpath(dir, "s$jobs"), root = dir, io = devnull, jobs)
        end
        @test seen == [1, 3]
    end
end

@testitem "a real Quarto render (skipped without Quarto)" setup = [SourceFixtures] begin
    if Sys.which("quarto") === nothing
        @test_skip "quarto is not installed" == ""
    else
        mktempdir() do dir
            write(joinpath(dir, "report.qmd"), "---\ntitle: Test\n---\n\nNo code here.\n")
            code = "p = tar_pipeline(tar_quarto(:report, \"report.qmd\"))"
            @test build_source(code, dir).built == [:report]
            @test isfile(joinpath(dir, "report.html"))
            @test isempty(build_source(code, dir).built)
        end
    end
end
