"""
    PipelineError(msg)

Raised when a set of targets does not form a valid pipeline.
"""
struct PipelineError <: Exception
    msg::String
end
Base.showerror(io::IO, e::PipelineError) = print(io, "PipelineError: ", e.msg)

"""
    Pipeline

A validated, immutable collection of targets with its dependency graph.
`graph` has an edge `dep => dependent`; `order` is a deterministic build order.
`track` lists extra modules or directories whose code counts as user code.
`groups` maps each [`tar_map`](@ref) template name to its generated targets.
"""
struct Pipeline
    targets::Vector{Target}
    index::Dict{Symbol, Int}
    graph::SimpleDiGraph{Int}
    order::Vector{Symbol}
    track::Vector{Any}
    groups::Dict{Symbol, Vector{Symbol}}
end

"""
    tar_pipeline(targets...; track = [])

Build a [`Pipeline`](@ref). Arguments may be targets or (nested) collections of
targets, so comprehensions and [`tar_map`](@ref) results can be passed directly.
"""
tar_pipeline(ts...; track = []) = Pipeline(flatten_targets(ts), collect(Any, track))

flatten_targets(t::Target) = Target[t]
flatten_targets(ts::Union{AbstractVector, Tuple}) = reduce(
    vcat,
    (flatten_targets(t) for t in ts);
    init = Target[],
)
flatten_targets(ts::NamedTuple) = flatten_targets(Tuple(ts))
flatten_targets(x) = throw(ArgumentError(
    "tar_pipeline() accepts targets or collections of targets, got `$(typeof(x))`",
))

function Pipeline(targets::Vector{Target}, track::Vector{Any} = Any[])
    index = build_index(targets)
    check_dependencies(targets, index)
    check_patterns(targets)
    graph = build_graph(targets, index)
    order = build_order(targets, graph)
    return Pipeline(targets, index, graph, order, track, build_groups(targets, index))
end

function build_groups(targets, index)
    groups = Dict{Symbol, Vector{Symbol}}()
    for t in targets
        t.group === nothing && continue
        haskey(index, t.group) &&
            throw(PipelineError(
                "tar_map group `$(t.group)` has the same name as a target; rename one of them",
            ))
        push!(get!(groups, t.group, Symbol[]), t.name)
    end
    return groups
end

function build_index(targets)
    index = Dict{Symbol, Int}()
    for (i, t) in enumerate(targets)
        haskey(index, t.name) &&
            throw(PipelineError(
                "duplicate target name `$(t.name)` (targets $(index[t.name]) and $i)",
            ))
        index[t.name] = i
    end
    return index
end

function check_dependencies(targets, index)
    for t in targets, d in t.deps
        haskey(index, d) && continue
        throw(PipelineError(
            "target `$(t.name)` depends on `$d`, which is not defined" *
                hint_suffix(d, keys(index)),
        ))
    end
end

function check_patterns(targets)
    for t in targets
        t.pattern === nothing && continue
        t.pattern in t.deps ||
            throw(PipelineError(
                "target `$(t.name)` has pattern `$(t.pattern)`, which must also be one of its dependencies ($(join(t.deps, ", ")))",
            ))
    end
end

function build_graph(targets, index)
    g = SimpleDiGraph{Int}(length(targets))
    for (i, t) in enumerate(targets), d in t.deps
        add_edge!(g, index[d], i)
    end
    return g
end

# Kahn's algorithm; ties are broken by declaration order for a stable result.
function build_order(targets, graph)
    n = nv(graph)
    indegree = [length(inneighbors(graph, v)) for v in 1:n]
    ready = [v for v in 1:n if indegree[v] == 0]
    order = Int[]
    while !isempty(ready)
        v = popfirst!(ready)
        push!(order, v)
        for w in outneighbors(graph, v)
            indegree[w] -= 1
            indegree[w] == 0 && (insert!(ready, searchsortedfirst(ready, w), w))
        end
    end
    length(order) == n ||
        throw(PipelineError("dependency cycle: " * format_cycle(targets, graph, order)))
    return [targets[v].name for v in order]
end

function format_cycle(targets, graph, ordered)
    remaining = setdiff(1:nv(graph), ordered)
    cycle = find_cycle(graph, remaining)
    return join((targets[v].name for v in cycle), " → ")
end

# Depth-first search with a path stack, restricted to `vertices` (all of which
# lie on or downstream of a cycle). Returns the cycle as `[a, b, c, a]`.
function find_cycle(graph, vertices)
    allowed = Set(vertices)
    state = Dict{Int, Symbol}()
    path = Int[]
    function visit(v)
        state[v] = :active
        push!(path, v)
        for w in outneighbors(graph, v)
            w in allowed || continue
            if get(state, w, :new) == :active
                return vcat(path[findfirst(==(w), path):end], w)
            elseif get(state, w, :new) == :new
                found = visit(w)
                found === nothing || return found
            end
        end
        pop!(path)
        state[v] = :done
        return nothing
    end
    for v in vertices
        get(state, v, :new) == :new || continue
        found = visit(v)
        found === nothing || return found
    end
    return Int[]
end

# Names within a small edit distance, nearest first.
function close_names(name::Symbol, candidates; maxdist = 2)
    s = string(name)
    scored = [(edit_distance(s, string(c)), string(c)) for c in candidates]
    hits = sort!(filter(x -> x[1] <= maxdist, scored))
    return Symbol[Symbol(h[2]) for h in hits]
end

function edit_distance(a::AbstractString, b::AbstractString)
    a, b = collect(a), collect(b)
    prev = collect(0:length(b))
    for i in eachindex(a)
        cur = [i; zeros(Int, length(b))]
        for j in eachindex(b)
            cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (a[i] == b[j] ? 0 : 1))
        end
        prev = cur
    end
    return prev[end]
end

get_target(p::Pipeline, name::Symbol) = p.targets[p.index[name]]

"""
    resolve_names(p, names)

`names` with each [`tar_map`](@ref) group name replaced by the targets of that
group; errors on names that are neither.
"""
function resolve_names(p::Pipeline, names)
    resolved = unique(reduce(vcat, (get(p.groups, n, [n]) for n in names); init = Symbol[]))
    for n in resolved
        haskey(p.index, n) && continue
        known = union(keys(p.index), keys(p.groups))
        throw(PipelineError("no target or group named `$n`" * hint_suffix(n, known)))
    end
    return resolved
end

function hint_suffix(name, candidates)
    hint = close_names(name, candidates)
    return isempty(hint) ?
        "" :
        "; did you mean " * join(("`$h`" for h in hint), ", ", " or ") * "?"
end

"""
    ancestors(p, names)

The targets in `names` together with everything they transitively depend on,
in build order.
"""
function ancestors(p::Pipeline, names)
    names = resolve_names(p, names)
    seen = falses(nv(p.graph))
    queue = [p.index[n] for n in names]
    foreach(v -> seen[v] = true, queue)
    while !isempty(queue)
        v = popfirst!(queue)
        for u in inneighbors(p.graph, v)
            seen[u] && continue
            seen[u] = true
            push!(queue, u)
        end
    end
    return filter(n -> seen[p.index[n]], p.order)
end

"""
    descendants(p, names)

The targets in `names` together with everything that transitively depends on
them, in build order.
"""
function descendants(p::Pipeline, names)
    names = resolve_names(p, names)
    seen = falses(nv(p.graph))
    queue = [p.index[n] for n in names]
    foreach(v -> seen[v] = true, queue)
    while !isempty(queue)
        v = popfirst!(queue)
        for w in outneighbors(p.graph, v)
            seen[w] && continue
            seen[w] = true
            push!(queue, w)
        end
    end
    return filter(n -> seen[p.index[n]], p.order)
end

"A `names` argument as a vector: a single symbol is allowed, `nothing` means no selection."
as_names(::Nothing) = nothing
as_names(name::Symbol) = [name]
as_names(names::AbstractVector{Symbol}) = Vector{Symbol}(names)

"""
    selected_order(p, names)

Build order for `names` (plus ancestors), or the whole pipeline if `names` is `nothing`.
"""
selected_order(p::Pipeline, ::Nothing) = copy(p.order)
selected_order(p::Pipeline, names) = ancestors(p, as_names(names))

@testitem "pipeline orders targets by dependency, ties by declaration" begin
    using Targets
    p = tar_pipeline(
        target(:summary, (a, b) -> 1),
        target(:b, () -> 1),
        target(:a, b -> 1),
        target(:c, () -> 1),
    )
    # lowest declaration index among ready targets goes first
    @test p.order == [:b, :a, :summary, :c]
    @test tar_pipeline(target(:x, () -> 1), target(:y, () -> 1)).order == [:x, :y]
end

@testitem "pipeline flattens nested collections" begin
    using Targets
    fits = [target(Symbol(:fit_, m), () -> m) for m in (:ols, :lasso)]
    p = tar_pipeline(target(:data, () -> 1), fits, (target(:z, () -> 1),))
    @test p.order == [:data, :fit_ols, :fit_lasso, :z]
    @test_throws ArgumentError tar_pipeline(1)
end

@testitem "pipeline validation errors" begin
    using Targets
    using Targets: PipelineError
    @test_throws "duplicate target name `a`" tar_pipeline(
        target(:a, () -> 1),
        target(:a, () -> 2),
    )
    @test_throws "did you mean `clean`" tar_pipeline(
        target(:clean, () -> 1),
        target(:m, clen -> 1),
    )
    @test_throws "not defined" tar_pipeline(target(:m, nothing_here -> 1))
    @test_throws "a → b → c → a" tar_pipeline(
        target(:a, c -> 1),
        target(:b, a -> 1),
        target(:c, b -> 1),
    )
    @test_throws "must also be one of its dependencies" tar_pipeline(
        target(:g, () -> 1),
        target(:f, () -> 1; pattern = :g),
    )
    @test_throws PipelineError tar_pipeline(target(:a, a -> 1))
end

@testitem "ancestors returns the closure in build order" begin
    using Targets
    using Targets: ancestors, selected_order, PipelineError
    p = tar_pipeline(
        target(:raw, () -> 1),
        target(:clean, raw -> 1),
        target(:other, () -> 1),
        target(:model, clean -> 1),
        target(:report, (model, other) -> 1),
    )
    @test ancestors(p, [:model]) == [:raw, :clean, :model]
    @test ancestors(p, [:other, :clean]) == [:raw, :clean, :other]
    @test selected_order(p, nothing) == p.order
    @test_throws "did you mean `model`" ancestors(p, [:modle])
    @test_throws "no target or group named" ancestors(p, [:nothing_like_it])
end

@testitem "every names keyword takes a vector of symbols, or a single symbol" begin
    using Targets: selected_order, graph_nodes
    p = tar_pipeline(target(:a, () -> 1), target(:b, a -> 1), target(:c, b -> 1))
    @test selected_order(p, [:b]) == selected_order(p, :b) == [:a, :b]
    @test graph_nodes(p, :b, true) == graph_nodes(p, [:b], true) == [:a, :b, :c]
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        @test tar_make(p; names = :b, store, root = dir, io = devnull).built == [:a, :b]
        @test tar_outdated(p; names = :c, store, root = dir) ==
            [(name = :c, reason = :missing)]
        tar_invalidate(; names = :b, store)
        tar_delete(; names = [:a], store)
        @test tar_outdated(p; names = [:b], store, root = dir)[1].name == :a
    end
end

@testitem "tar_map group names select every arm" begin
    using Targets: ancestors, descendants, resolve_names, PipelineError
    m = tar_map((:a, :b)) do k
        (target(:fit, raw -> k), target(:summary, fit -> fit))
    end
    p = tar_pipeline(target(:raw, () -> 1), m, tar_combine(:all, (xs...) -> xs, m.summary))
    @test p.groups == Dict(:fit => [:fit_a, :fit_b], :summary => [:summary_a, :summary_b])
    @test resolve_names(p, [:fit, :fit_a, :raw]) == [:fit_a, :fit_b, :raw]
    @test ancestors(p, [:fit]) == [:raw, :fit_a, :fit_b]
    @test descendants(p, [:summary]) == [:summary_a, :summary_b, :all]
    @test_throws "did you mean `fit`" ancestors(p, [:fitt])
    @test_throws "same name as a target" tar_pipeline(
        target(:fit, () -> 1),
        tar_map(k -> target(:fit, () -> k), (:a,)),
    )
end

@testitem "descendants returns the downstream closure in build order" begin
    using Targets: descendants
    p = tar_pipeline(
        target(:raw, () -> 1),
        target(:clean, raw -> 1),
        target(:other, () -> 1),
        target(:model, clean -> 1),
        target(:report, (model, other) -> 1),
    )
    @test descendants(p, [:clean]) == [:clean, :model, :report]
    @test descendants(p, [:other]) == [:other, :report]
    @test descendants(p, [:report]) == [:report]
end
