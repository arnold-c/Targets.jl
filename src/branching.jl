## Dynamic branching
##
## A branching target (`pattern = :other`) runs once per element of the pattern
## target's vector. Each branch is stored and checked like a small target under
## the key "name/id", where the id comes from the element's hash rather than its
## position, so inserting or reordering elements leaves other branches alone.

const BRANCH_ID_LENGTH = 8

"Name of some target that uses `name` in its pattern, or `nothing`."
function pattern_use_of(p::Pipeline, name::Symbol)
    i = findfirst(t -> name in pattern_names(t.pattern), p.targets)
    return i === nothing ? nothing : p.targets[i].name
end

"""
    disambiguate(hashes)

Make identity hashes unique: the second and later occurrences of a hash are
rehashed together with their occurrence count, so duplicate elements get their
own branches.
"""
function disambiguate(hashes::Vector{String})
    seen = Dict{String, Int}()
    return map(hashes) do h
        n = get!(seen, h, 0) + 1
        seen[h] = n
        n == 1 ? h : canonical_hash((h, n))
    end
end

"""
    Targets.branch_elements(x)

Extension point: the elements a branching target maps over when its pattern
target's value is `x`. The default accepts an `AbstractVector`; the DataFrames
extension maps a `GroupedDataFrame` to (copies of) its groups.
"""
branch_elements(x::AbstractVector) = x
branch_elements(x) = error(
    "a pattern target must return a vector (or a value with a `Targets.branch_elements` method), not a `$(typeof(x))`",
)

"Whether `x` can be a pattern value: it has a `branch_elements` method beyond the fallback."
has_branch_elements(x) = which(branch_elements, Tuple{typeof(x)}).sig !==
    Tuple{typeof(branch_elements), Any}

"""
    Targets.element_hashes(x)

Identity hashes of the elements of pattern value `x` (one per element of
[`branch_elements`](@ref), unique). Extension point for values whose elements
deserve a better identity than their canonical hash.
"""
element_hashes(x) = element_hashes(branch_elements(x))
element_hashes(values::AbstractVector) = disambiguate(
    String[canonical_hash(v) for v in values]
)

"""
    branch_ids(hashes)

Short branch ids for identity hashes: the first $BRANCH_ID_LENGTH hex characters, extended for
the (rare) elements whose short ids collide.
"""
function branch_ids(hashes::Vector{String})
    short = String[h[1:BRANCH_ID_LENGTH] for h in hashes]
    allunique(short) && return short
    counts = Dict{String, Int}()
    foreach(id -> counts[id] = get(counts, id, 0) + 1, short)
    return String[
        counts[short[i]] > 1 ? hashes[i][1:min(end, 2 * BRANCH_ID_LENGTH)] : short[i]
        for i in eachindex(short)
    ]
end

# Identity hashes of a file target's paths: the path together with its content hash.
file_element_hashes(record::Record) = disambiguate(
    String[canonical_hash((f, h)) for (f, h) in zip(record.files, record.file_hashes)]
)

"""
    pattern_elements(ctx, up, t)

The elements of pattern target `up` that branching target `t` maps over, as
(branch id, identity hash) in order, read from `up`'s record without loading
its value. If `up` is itself branching, its elements are its branches: each
keeps the upstream branch's id, and its hash is that branch's value hash.
"""
function pattern_elements(ctx::BuildContext, up::Target, t::Target)
    record = read_meta(ctx.store, up.name)::Record
    if up.pattern !== nothing
        return [
            PatternElement(id, h)
            for (id, h) in zip(record.branches, record.branch_hashes)
        ]
    end
    hashes = if is_external(up)
        record.file_scalar &&
            error(
                "target `$(up.name)` is the pattern of `$(t.name)`, so it must return a vector of paths",
            )
        file_element_hashes(record)
    elseif record.elements_recorded
        record.element_hashes
    else
        # built before it was a pattern: work the hashes out now, and keep them
        hs = element_hashes(get_value!(ctx, up.name))::Vector{String}
        write_meta(
            ctx.store,
            up.name,
            update(record; element_hashes = hs, elements_recorded = true),
        )
        hs
    end
    return [PatternElement(id, h) for (id, h) in zip(branch_ids(hashes), hashes)]
end

"""
    pattern_branches(ctx, t)

The branches of branching target `t`, in pattern order. A branch over a single
pattern target keeps that element's id and hash; a branch combining several
elements is identified by the hash of their hashes, in pattern order.
"""
function pattern_branches(ctx::BuildContext, t::Target)
    elements_of(name) = pattern_elements(ctx, get_target(ctx.pipeline, name), t)
    combos = select_combinations(t.pattern, elements_of, resolve_seed(ctx.pipeline, t))
    if all(c -> length(c) == 1, combos)
        return [Branch(only(c).element.id, only(c).element.hash, c) for c in combos]
    end
    hashes = disambiguate([
        canonical_hash(Tuple(p.element.hash for p in c))
        for c in combos
    ])
    return [Branch(id, h, c) for (id, h, c) in zip(branch_ids(hashes), hashes, combos)]
end

"The value of one pick of a branch, loaded only when the branch has to be built."
function pick_value(ctx::BuildContext, pick::Pick)
    up = get_target(ctx.pipeline, pick.name)
    up.pattern === nothing || return read_object(ctx.store, "$(up.name)/$(pick.element.id)")
    return branch_elements(get_value!(ctx, up.name))[pick.index]
end

# What a branch receives for dependency `d`: its element(s) if `d` is in the pattern.
function branch_arg(ctx::BuildContext, b::Branch, d::Symbol)
    picks = filter(p -> p.name == d, b.picks)
    isempty(picks) && return get_value!(ctx, d)
    length(picks) == 1 && return pick_value(ctx, only(picks))
    return Tuple(pick_value(ctx, p) for p in picks)
end

"All branch values of a branching target, in pattern order."
function load_branches(store::Store, name::Symbol)
    record = read_meta(store, name)::Record
    return Any[read_object(store, "$name/$id") for id in record.branches]
end

"Remove the objects and records of branches that are no longer in the pattern."
function prune_branches!(store::Store, name::Symbol, keep::Vector{String})
    for dir in ("objects", "meta")
        path = joinpath(store.root, dir, string(name))
        isdir(path) || continue
        for entry in readdir(path)
            first(split(entry, '.')) in keep || rm(joinpath(path, entry); force = true)
        end
    end
end

combined_hash(hashes::Vector{String}) = bytes2hex(SHA.sha256(join(hashes, "\n")::String))

function branch_dep_hashes(ctx::BuildContext, t::Target, b::Branch)
    function dep_hash(d)
        hashes = [p.element.hash for p in b.picks if p.name == d]
        isempty(hashes) && return ctx.value_hashes[d]
        return length(hashes) == 1 ? only(hashes) : canonical_hash(Tuple(hashes))
    end
    return Dict{Symbol, String}(d => dep_hash(d) for d in t.deps)
end

"""
    plan_branching!(ctx, t, cmd, code) -> Vector{Job}

One job per outdated branch of branching target `t`. Up-to-date branches
contribute their stored value hashes; the target is finished (see
[`finish_branching!`](@ref)) once its last job is committed, or right away if
there is none.
"""
function plan_branching!(ctx::BuildContext, t::Target, cmd, code)
    elements = pattern_branches(ctx, t)
    progress = BranchProgress(
        t,
        cmd,
        code,
        elements,
        fill("", length(elements)),
        Int[],
        Int[],
        read_meta(ctx.store, t.name),
        0,
        nothing,
    )
    forced = t.name in ctx.forced
    jobs = Job[]
    for (i, el) in enumerate(elements)
        key = "$(t.name)/$(el.id)"
        dep_hashes = branch_dep_hashes(ctx, t, el)
        seed = resolve_seed(ctx.pipeline, t, key)
        reason = outdated_reason(
            ctx.store,
            t,
            cmd,
            code,
            dep_hashes;
            seed = seed_string(seed),
            forced,
            root = ctx.root,
            key,
        )
        if reason === nothing
            progress.hashes[i] = stored_value_hash(ctx.store, key)
            continue
        end
        args, load_error = resolve_args() do
            Any[branch_arg(ctx, el, d) for d in t.deps]
        end
        push!(
            jobs,
            Job(
                t,
                key,
                i,
                args,
                load_error,
                seed,
                reason,
                cmd,
                code,
                dep_hashes,
                nothing,
                ctx.store,
                ctx.root,
            ),
        )
    end
    progress.pending = length(jobs)
    ctx.branching[t.name] = progress
    isempty(jobs) && finish_branching!(ctx, progress)
    return jobs
end

"Record one branch's outcome; returns whether its target is now finished."
function commit_branch!(ctx::BuildContext, r::JobResult; keep_going::Bool)
    job = r.job
    t = job.target
    if failed(r)
        record_failure!(ctx, t, r.exception; key = job.key, backtrace = r.backtrace)
        event!(ctx, job.key, :errored; r.seconds)
        log!(ctx, "✖ $(job.key): $(first(sprint(showerror, r.exception), 200))")
    else
        write_meta(ctx.store, job.key, job_record(r))
        event!(ctx, job.key, :built; r.seconds)
        log!(ctx, "✔ $(job.key) $(round(r.seconds; digits = 2))s")
    end
    # a sibling branch already failed the target and the build is stopping
    progress = get(ctx.branching, t.name, nothing)
    progress === nothing && return false
    progress.pending -= 1
    if failed(r)
        progress.failure === nothing && (progress.failure = r.exception)
        push!(progress.failed, job.branch)
        if stops_build(t, keep_going)
            push!(ctx.summary.errored, t.name)
            delete!(ctx.branching, t.name)
            throw(r.exception)
        end
    else
        progress.hashes[job.branch] = r.value_hash
        push!(progress.built, job.branch)
    end
    progress.pending > 0 && return false
    finish_branching!(ctx, progress)
    return true
end

"Commit a branching target as a whole once all its branches are done."
function finish_branching!(ctx::BuildContext, progress::BranchProgress)
    t = progress.target
    delete!(ctx.branching, t.name)
    ids = [el.id for el in progress.elements]
    built = [ids[i] for i in sort(progress.built)]
    isempty(built) || (ctx.summary.branches[t.name] = built)
    if progress.failure !== nothing && t.error !== :trim
        push!(ctx.summary.errored, t.name)
        event!(ctx, t.name, :errored)
        record_failure!(ctx, t, progress.failure)
        t.error === :null && null_value!(ctx, t)
        return nothing
    end
    # with error = :trim, failed branches are left out (and retried next time)
    kept = setdiff(eachindex(ids), progress.failed)
    trimmed = ids[sort(progress.failed)]
    isempty(trimmed) || (ctx.summary.trimmed[t.name] = trimmed)
    all_ids = ids
    ids = ids[kept]
    hashes = progress.hashes[kept]
    value_hash = combined_hash(hashes)
    deps = Dict{String, String}(string(d) => ctx.value_hashes[d] for d in t.deps)
    write_meta(
        ctx.store,
        t.name,
        Record(;
            command_hash = something(progress.cmd.hash, ""),
            code_hash = progress.code,
            hash_source = string(progress.cmd.kind),
            dep_hashes = deps,
            value_hash,
            format_fields(t)...,
            built_at = string(Dates.now(Dates.UTC)),
            seed = seed_string(resolve_seed(ctx.pipeline, t)),
            branches = ids,
            branch_hashes = hashes,
            trimmed,
            # a trimmed target stays outdated until every branch succeeds
            error = isempty(trimmed) ?
                "" :
                "branches failed and were trimmed: $(join(trimmed, ", "))",
        ),
    )
    prune_branches!(ctx.store, t.name, all_ids)
    ctx.value_hashes[t.name] = value_hash
    previous = progress.previous
    changed = !isempty(built) ||
        previous === nothing ||
        previous.branches != ids ||
        previous.value_hash != value_hash ||
        !isempty(previous.error)
    if changed
        push!(ctx.summary.built, t.name)
        event!(ctx, t.name, :built)
        log!(ctx, "✔ $(t.name): $(length(built)) of $(length(ids)) branches built")
    else
        push!(ctx.summary.skipped, t.name)
        event!(ctx, t.name, :skipped)
        log!(ctx, "· $(t.name): $(length(ids)) branches up to date")
    end
    return nothing
end

@testmodule BranchFixtures begin
    using Targets
    export grid_code

    "A pipeline with a pattern target `grid` (elements given by `elements`), `fits` over it, and a `summary`."
    grid_code(; elements = "[1, 2, 3]", fit = "g * 10 + offset", extra = "") = """
    $extra
    p = tar_pipeline(
        target(:offset, () -> 5),
        target(:grid, () -> $elements),
        target(:fits, (offset, grid) -> $(replace(fit, "g" => "grid")); pattern = :grid),
        target(:summary, fits -> sum(fits)),
    )
    """
end

@testitem "branching over a GroupedDataFrame runs once per group" setup = [
    SourceFixtures,
] begin
    using DataFrames
    code(rows::Vector{String}) = """
    using DataFrames
    p = tar_pipeline(
        target(:groups, () -> groupby(DataFrame(g = $(repr(rows)), x = 1:$(length(rows))), :g)),
        target(:totals, groups -> (groups.g[1], sum(groups.x)); pattern = :groups),
    )
    """
    mktempdir() do dir
        s = build_source(code(["a", "b", "a"]), dir)
        @test length(s.branches[:totals]) == 2
        @test only(read_values(dir, :totals)) == [("a", 4), ("b", 2)]
        s = build_source(code(["a", "b", "a", "c"]), dir)
        @test length(s.branches[:totals]) == 1 # only the new group
        @test only(read_values(dir, :totals))[3] == ("c", 4)
    end
end

@testitem "branch ids come from element hashes and survive reordering" begin
    using Targets: element_hashes, branch_ids, disambiguate
    h = element_hashes([:a, :b, :c])
    @test allunique(h)
    ids = branch_ids(h)
    @test all(==(8) ∘ length, ids)
    # an element keeps its id whatever its position or neighbours
    @test branch_ids(element_hashes([:c, :a, :x]))[[2, 1]] == ids[[1, 3]]
    # duplicates are told apart by occurrence
    d = element_hashes([:a, :a, :a])
    @test allunique(d) && d[1] == h[1]
    @test disambiguate(["x", "y", "x"])[[1, 2]] == ["x", "y"]
    # colliding short ids are extended
    @test branch_ids(["12345678aaaa", "12345678bbbb", "99999999cccc"]) ==
        ["12345678aaaa", "12345678bbbb", "99999999"]
end

@testitem "a branching target maps over its pattern and aggregates" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        code = grid_code()
        s = build_source(code, dir)
        @test s.built == [:offset, :grid, :fits, :summary]
        @test length(s.branches[:fits]) == 3
        @test tar_read(:fits; store = joinpath(dir, "_targets")) == [15, 25, 35]
        @test read_values(dir, :summary) == (75,)
        again = build_source(code, dir)
        @test isempty(again.built) && isempty(again.branches)
        @test again.skipped == [:offset, :grid, :fits, :summary]
    end
end

@testitem "adding, removing and reordering elements builds only what changed" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    using Targets: open_store, meta_keys
    mktempdir() do dir
        build_source(grid_code(), dir)
        store = open_store(joinpath(dir, "_targets"))
        before = filter(startswith("fits/"), meta_keys(store))
        @test length(before) == 3
        s = build_source(grid_code(; elements = "[1, 2, 3, 4]"), dir)
        @test s.built == [:grid, :fits, :summary]
        @test length(s.branches[:fits]) == 1 # one new branch
        @test read_values(dir, :summary) == (120,)
        s = build_source(grid_code(; elements = "[4, 3, 2, 1]"), dir) # reordered
        @test s.built == [:grid, :fits, :summary] # order is part of the aggregate...
        @test !haskey(s.branches, :fits) # ...but no branch is rebuilt
        s = build_source(grid_code(; elements = "[1, 3]"), dir) # shrunk
        @test !haskey(s.branches, :fits)
        @test length(filter(startswith("fits/"), meta_keys(store))) == 2 # pruned
        @test length(readdir(joinpath(dir, "_targets", "objects", "fits"))) == 2
        @test read_values(dir, :summary) == (50,)
    end
end

@testitem "editing one element, the code, or a shared argument rebuilds the right branches" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        build_source(grid_code(), dir)
        s = build_source(grid_code(; elements = "[1, 2, 7]"), dir) # one element changed
        @test length(s.branches[:fits]) == 1
        @test read_values(dir, :summary) == (15 + 25 + 75,)
        s = build_source(
            grid_code(; elements = "[1, 2, 7]", fit = "g * 10 + offset + 0"),
            dir,
        )
        @test length(s.branches[:fits]) == 3 # new code: every branch
        s = build_source(
            grid_code(;
                elements = "[1, 2, 7]",
                fit = "g * 10 + offset + 0",
                extra = "# note",
            ),
            dir,
        )
        @test isempty(s.built) # a comment changes nothing
    end
    mktempdir() do dir
        code(offset) = replace(grid_code(), "() -> 5" => "() -> $offset")
        build_source(code(5), dir)
        s = build_source(code(6), dir) # a whole (non-pattern) argument
        @test length(s.branches[:fits]) == 3
    end
end

@testitem "a deleted branch object rebuilds only that branch" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        build_source(grid_code(), dir)
        objects = joinpath(dir, "_targets", "objects", "fits")
        victim = first(sort(readdir(objects)))
        rm(joinpath(objects, victim))
        s = build_source(grid_code(), dir)
        @test s.branches[:fits] == [chopsuffix(victim, ".jld2")]
        @test s.built == [:fits] # same value: aggregate cut off
    end
end

@testitem "branching over branches maps 1:1 and rebuilds one chain" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        code(elements) = """
        p = tar_pipeline(
            target(:grid, () -> $elements),
            target(:fits, grid -> grid * 10; pattern = :grid),
            target(:preds, fits -> fits + 1; pattern = :fits),
            target(:all, preds -> sum(preds)),
        )
        """
        s = build_source(code("[1, 2, 3]"), dir)
        @test length(s.branches[:fits]) == length(s.branches[:preds]) == 3
        @test sort(s.branches[:fits]) ==
            sort(s.branches[:preds]) # preds reuses fits' branch ids
        @test read_values(dir, :all) == (63,)
        s = build_source(code("[1, 2, 9]"), dir)
        @test length(s.branches[:fits]) == 1
        @test length(s.branches[:preds]) == 1
        @test read_values(dir, :all) == (11 + 21 + 91,)
    end
end

@testitem "duplicate elements get their own branches" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        s = build_source(grid_code(; elements = "[2, 2, 2]"), dir)
        @test length(s.branches[:fits]) == 3
        @test tar_read(:fits; store = joinpath(dir, "_targets")) == [25, 25, 25]
    end
end

@testitem "pattern targets must return vectors, and errors are per branch" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        @test_throws "must return a vector" build_source(grid_code(; elements = "5"), dir)
    end
    mktempdir() do dir
        code(elements) = """
        p = tar_pipeline(
            target(:grid, () -> $elements),
            target(:fits, grid -> grid == 2 ? error("bad") : grid * 2; pattern = :grid),
            target(:after, fits -> sum(fits)),
        )
        """
        s = build_source(code("[1, 2, 3]"), dir; keep_going = true)
        @test s.errored == [:fits]
        @test s.blocked == [:after]
        @test length(s.branches[:fits]) == 2 # the other branches were built
        @test_throws ErrorException build_source(
            code("[1, 2, 3]"),
            dir,
        )                                        # the failure is retried
        s = build_source(code("[1, 5, 3]"), dir) # the failing element is gone
        @test s.built == [:grid, :fits, :after]
        @test length(s.branches[:fits]) == 1
        @test read_values(dir, :after) == (2 + 10 + 6,)
    end
end

@testitem "branching over a file target: one branch per file" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:inputs, () -> ["a.txt", "b.txt"]; format = :file),
            target(:sizes, inputs -> filesize(inputs); pattern = :inputs),
            target(:total, sizes -> sum(sizes)),
        )
        """
        write_files(dir, "a.txt" => "123", "b.txt" => "45")
        s = build_source(code, dir)
        @test length(s.branches[:sizes]) == 2
        @test read_values(dir, :total) == (5,)
        write_files(dir, "b.txt" => "4567")
        s = build_source(code, dir)
        @test length(s.branches[:sizes]) == 1
        @test read_values(dir, :total) == (7,)
    end
end

@testitem "static branching: generated targets, closures and an explicit combine" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(third) = """
        models = (:ols, :lasso, $third)
        fits = [target(Symbol(:fit_, i), () -> string(m)) for (i, m) in enumerate(models)]
        p = tar_pipeline(
            fits,
            target(:all_fits, (xs...) -> join(xs, ","); deps = [Symbol(:fit_, i) for i in 1:3]),
        )
        """
        @test build_source(code(":ridge"), dir).built == [:fit_1, :fit_2, :fit_3, :all_fits]
        @test read_values(dir, :all_fits) == ("ols,lasso,ridge",)
        s = build_source(
            code(":elasticnet"),
            dir,
        ) # same source text, different captured value
        @test s.built == [:fit_3, :all_fits]
        @test s.skipped == [:fit_1, :fit_2]
        @test read_values(dir, :all_fits) == ("ols,lasso,elasticnet",)
    end
end

@testitem "tar_outdated and tar_dot understand branching targets" setup = [
    SourceFixtures,
    BranchFixtures,
] begin
    mktempdir() do dir
        build_source(grid_code(), dir)
        @test isempty(outdated_source(grid_code(), dir))
        @test outdated_source(grid_code(; elements = "[1, 2, 4]"), dir) ==
            [
                (name = :grid, reason = :command_changed),
                (name = :fits, reason = :upstream_outdated),
                (name = :summary, reason = :upstream_outdated),
            ]
        m, _ = load_source(grid_code(); dir)
        p = Base.invokelatest(getproperty, m, :p)
        dot = string(tar_dot(p; store = joinpath(dir, "_targets"), root = dir))
        @test occursin("label=\"fits [3]\"", dot)
        @test !occursin("label=\"summary [", dot)
    end
end
