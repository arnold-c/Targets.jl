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
closes(fence::AbstractString, closing::RegexMatch) = isempty(closing.captures[2]) &&
    closing.captures[1][1] == fence[1] &&
    length(closing.captures[1]) >= length(fence)

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
                    (strip(c.captures[1]) for c in eachmatch(INLINE_JULIA, line))
                )
            else
                fence = m.captures[1]
                cell = occursin(JULIA_CELL, m.captures[2]) ? String[] : nothing
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
        strip(m.captures[1], ['"', '\''])
        for line in prose
        for m in eachmatch(INCLUDE_SHORTCODE, line)
    ]
end

"""
    quarto_sources(path)

The absolute paths of a document and of every file it includes, recursively,
in the order they are first reached. Included paths are relative to the file
that includes them; an include that does not exist is an error.
"""
function quarto_sources(path::AbstractString, found = String[])
    file = normpath(abspath(path))
    file in found && return found
    isfile(file) || error("Quarto document `$file` does not exist")
    push!(found, file)
    for inc in quarto_includes(quarto_text(read(file, String)).prose)
        target = normpath(joinpath(dirname(file), inc))
        isfile(target) || error("`$file` includes `$inc`, which does not exist")
        quarto_sources(target, found)
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

`(names, dynamic)` for a document and the files it includes (see
[`code_reads`](@ref)).
"""
function quarto_reads(path::AbstractString)
    found, dynamic = Symbol[], String[]
    for file in quarto_sources(path)
        parts = quarto_text(read(file, String))
        for code in vcat(parts.cells, parts.inline)
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
        m === nothing || return unquote(m.captures[1])
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
        lead == indent && m !== nothing && push!(formats, m.captures[1])
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

@testitem "quarto_sources follows includes relative to the including file" begin
    using Targets: quarto_sources
    mktempdir() do dir
        mkpath(joinpath(dir, "parts"))
        write(
            joinpath(dir, "report.qmd"),
            "A\n{{< include parts/_a.qmd >}}\n{{< include \"parts/_a.qmd\" >}}\n",
        )
        write(
            joinpath(dir, "parts", "_a.qmd"),
            "B\n{{< include _b.qmd >}}\n```\n{{< include _no.qmd >}}\n```\n",
        )
        write(joinpath(dir, "parts", "_b.qmd"), "C\n{{< include ../report.qmd >}}\n")
        @test quarto_sources(joinpath(dir, "report.qmd")) ==
            normpath.([
                joinpath(dir, "report.qmd"),
                joinpath(dir, "parts", "_a.qmd"),
                joinpath(dir, "parts", "_b.qmd"),
            ])
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
