## Listing the targets of a pipeline, without their dependencies

"Section key => heading, in the order sections are listed."
const LIST_SECTIONS = (
    constants = "Constants",
    inputs = "Input files",
    computations = "Computations",
    outputs = "Output files",
)

"The targets of one connected component, by section (see [`tar_list`](@ref))."
const ListComponent = NamedTuple{keys(LIST_SECTIONS), NTuple{4, Vector{Symbol}}}

"""
    TargetList

The targets of a pipeline, returned by [`tar_list`](@ref): `components` holds one
`NamedTuple` per connected component of the graph, with the fields
`constants`, `inputs`, `computations` and `outputs`, each a vector of names.
Prints as a sectioned list.
"""
struct TargetList
    components::Vector{ListComponent}
end

"""
    list_section(t::Target)

Which section of [`tar_list`](@ref) `t` belongs to: file and URL targets are
`:inputs` without dependencies and `:outputs` with them; other targets are
`:constants` without dependencies and `:computations` with them.
"""
function list_section(t::Target)
    external = is_external(t)
    isempty(t.deps) && return external ? :inputs : :constants
    return external ? :outputs : :computations
end

"""
    connected_components(p, nodes)

`nodes` (in build order) split into the weakly connected components of the
graph between them, each in build order, ordered by their first target.
"""
function connected_components(p::Pipeline, nodes::Vector{Symbol})
    subgraph, vertices = induced_subgraph(p.graph, [p.index[n] for n in nodes])
    position = Dict(n => i for (i, n) in enumerate(nodes))
    components = [
        sort([p.targets[vertices[v]].name for v in c]; by = n -> position[n])
        for c in weakly_connected_components(subgraph)
    ]
    return sort!(components; by = c -> position[first(c)])
end

"""
    list_component(p, nodes)

The targets of one component, by section. Within a section, targets are
ordered by their layer (longest path from a root), so a target comes after the
targets it needs, and alphabetically within a layer.
"""
function list_component(p::Pipeline, nodes::Vector{Symbol})
    layer_of = layer_numbers(p, nodes)
    ordered = sort(nodes; by = n -> (layer_of[n], string(n)))
    in_section(s) = filter(n -> list_section(get_target(p, n)) === s, ordered)
    return ListComponent(map(in_section, keys(LIST_SECTIONS)))
end

"""
    tar_list(p::Pipeline; names = nothing, descendants = false)

List the pipeline's targets without their dependencies, as a [`TargetList`](@ref).
Targets are grouped into constants, input files, computations and output files
(file and URL targets count as files), and the list is split by the connected
components of the graph, so each independent part of the pipeline is listed on
its own. Within a section, targets appear in the order they can be built: a
target comes after those it needs, and targets at the same depth are listed
alphabetically.

With `names`, only those targets and their ancestors are listed;
`descendants = true` adds everything downstream of them (as in
[`tar_dot`](@ref)). The store is not consulted. `tar_list()` loads
`_targets.jl`.
"""
function tar_list(p::Pipeline; names = nothing, descendants::Bool = false)
    nodes = graph_nodes(p, names, descendants)
    return TargetList([list_component(p, c) for c in connected_components(p, nodes)])
end
tar_list(; script::AbstractString = default_script(), kwargs...) = tar_list(
    load_pipeline(script);
    kwargs...,
)

count_targets(c::ListComponent) = sum(length, c)
plural(n, word) = n == 1 ? "$n $word" : "$n $(word)s"

function Base.show(io::IO, l::TargetList)
    print(
        io,
        "TargetList(",
        plural(length(l.components), "component"),
        ", ",
        plural(sum(count_targets, l.components; init = 0), "target"),
        ")",
    )
end

function Base.show(io::IO, ::MIME"text/plain", l::TargetList)
    isempty(l.components) && return print(io, "No targets")
    several = length(l.components) > 1
    for (i, c) in enumerate(l.components)
        i > 1 && print(io, "\n\n")
        several &&
            printstyled(
                io,
                "Component $i of $(length(l.components)) (",
                plural(count_targets(c), "target"),
                ")\n";
                bold = true,
            )
        print_component(io, c, several ? "  " : "")
    end
end

function print_component(io::IO, c::ListComponent, indent::AbstractString)
    shown = filter(s -> !isempty(c[s]), collect(keys(LIST_SECTIONS)))
    for (j, s) in enumerate(shown)
        print(io, indent)
        printstyled(io, LIST_SECTIONS[s], " (", length(c[s]), ")"; bold = true)
        for n in c[s]
            print(io, "\n", indent, "  ", n)
        end
        j < length(shown) && println(io)
    end
end

@testmodule ListFixtures begin
    using Targets
    export listed

    "A pipeline with every section, declared out of build order, plus a separate part."
    listed() = tar_pipeline(
        target(:settings, () -> (; scale = 2)),
        target(:raw_file, () -> "raw.csv"; format = :file),
        target(:zeta, clean -> clean),
        target(:report, (zeta, beta) -> "report.txt"; format = :file),
        target(:clean, (raw_file, settings) -> 1),
        target(:beta, clean -> clean),
        target(:alpha, beta -> beta),
        target(:other, () -> 5),
        target(:other_summary, other -> other),
    )
end

@testitem "tar_list sorts targets into sections in build order" setup = [ListFixtures] begin
    l = tar_list(listed())
    @test length(l.components) == 2
    main, other = l.components
    @test main.constants == [:settings]
    @test main.inputs == [:raw_file]
    # clean is needed by beta and zeta (alphabetical), and beta by alpha
    @test main.computations == [:clean, :beta, :zeta, :alpha]
    @test main.outputs == [:report]
    @test other ==
        (
            constants = [:other],
            inputs = Symbol[],
            computations = [:other_summary],
            outputs = Symbol[],
        )
end

@testitem "tar_list splits disconnected parts and prints sections" setup = [
    ListFixtures,
] begin
    text = sprint(show, MIME("text/plain"), tar_list(listed()))
    @test startswith(text, "Component 1 of 2 (7 targets)\n  Constants (1)\n    settings\n")
    @test occursin(
        "  Computations (4)\n    clean\n    beta\n    zeta\n    alpha\n  Output files (1)\n    report",
        text,
    )
    @test endswith(
        text,
        "Component 2 of 2 (2 targets)\n  Constants (1)\n    other\n  Computations (1)\n    other_summary",
    )
    @test !occursin(
        "Input files",
        split(text, "Component 2")[2],
    ) # empty sections are left out
    @test sprint(show, tar_list(listed())) == "TargetList(2 components, 9 targets)"

    # one component: no component heading or indent
    one = sprint(show, MIME("text/plain"), tar_list(listed(); names = [:other_summary]))
    @test one == "Constants (1)\n  other\nComputations (1)\n  other_summary"
end

@testitem "tar_list selects targets by name like tar_dot" setup = [ListFixtures] begin
    p = listed()
    l = tar_list(p; names = [:beta])
    @test only(l.components).computations == [:clean, :beta]
    l = tar_list(p; names = [:beta], descendants = true)
    @test only(l.components).computations == [:clean, :beta, :alpha]
    @test only(l.components).outputs == [:report]
    @test isempty(
        tar_list(p; names = :settings, descendants = false).components[1].computations,
    )
end
