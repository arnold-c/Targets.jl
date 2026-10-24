## Dynamic branching
##
## A branching target (`pattern = :other`) runs once per element of the pattern
## target's vector. Each branch is stored and checked like a small target under
## the key "name/id", where the id comes from the element's hash rather than its
## position, so inserting or reordering elements leaves other branches alone.

const BRANCH_ID_LENGTH = 8

"Name of some target that uses `name` as its pattern, or `nothing`."
function pattern_use_of(p::Pipeline, name::Symbol)
    i = findfirst(t -> t.pattern === name, p.targets)
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

"Identity hashes of the elements of a pattern vector."
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

function pattern_target(ctx::BuildContext, t::Target)
    t.pattern === nothing && error("target `$(t.name)` has no pattern")
    return get_target(ctx.pipeline, t.pattern)
end

# Identity hashes of a file target's paths: the path together with its content hash.
file_element_hashes(record::Record) = disambiguate(
    String[canonical_hash((f, h)) for (f, h) in zip(record.files, record.file_hashes)]
)

"""
    pattern_elements(ctx, t)

The elements a branching target `t` maps over, as (branch id, identity hash) in
pattern order, read from the pattern target's record without loading its value.
Over another branching target the mapping is 1:1: each branch keeps the upstream
branch's id, and its hash is the upstream branch's value hash.
"""
function pattern_elements(ctx::BuildContext, t::Target)
    up = pattern_target(ctx, t)
    record = read_meta(ctx.store, up.name)::Record
    if up.pattern !== nothing
        return [
            PatternElement(id, h)
            for (id, h) in zip(record.branches, record.branch_hashes)
        ]
    end
    hashes = if up.format == :file
        record.file_scalar &&
            error(
                "target `$(up.name)` is the pattern of `$(t.name)`, so it must return a vector of paths",
            )
        file_element_hashes(record)
    elseif record.elements_recorded
        record.element_hashes
    else
        # built before it was a pattern: work the hashes out now, and keep them
        hs = element_hashes(get_value!(ctx, up.name))
        write_meta(
            ctx.store,
            up.name,
            update(record; element_hashes = hs, elements_recorded = true),
        )
        hs
    end
    return [PatternElement(id, h) for (id, h) in zip(branch_ids(hashes), hashes)]
end

"The value of element `i` of the pattern, loaded only when a branch has to be built."
function pattern_element_value(ctx::BuildContext, t::Target, i::Integer, el::PatternElement)
    up = pattern_target(ctx, t)
    up.pattern === nothing || return read_object(ctx.store, "$(up.name)/$(el.id)")
    return get_value!(ctx, up.name)[i]
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

function branch_dep_hashes(ctx::BuildContext, t::Target, el::PatternElement)
    return Dict{Symbol, String}(
        d => (d == t.pattern ? el.hash : ctx.value_hashes[d])
        for d in t.deps
    )
end

"""
    plan_branching!(ctx, t, cmd, code) -> Vector{Job}

One job per outdated branch of branching target `t`. Up-to-date branches
contribute their stored value hashes; the target is finished (see
[`finish_branching!`](@ref)) once its last job is committed, or right away if
there is none.
"""
function plan_branching!(ctx::BuildContext, t::Target, cmd, code)
    elements = pattern_elements(ctx, t)
    progress = BranchProgress(
        t,
        cmd,
        code,
        elements,
        fill("", length(elements)),
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
            element = pattern_element_value(ctx, t, i, el)
            Any[d == t.pattern ? element : get_value!(ctx, d) for d in t.deps]
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
        record_failure!(ctx, t, r.exception; key = job.key)
        log!(ctx, "✖ $(job.key): $(first(sprint(showerror, r.exception), 200))")
    else
        write_meta(ctx.store, job.key, job_record(r))
        log!(ctx, "✔ $(job.key) $(round(r.seconds; digits = 2))s")
    end
    # a sibling branch already failed the target and the build is stopping
    progress = get(ctx.branching, t.name, nothing)
    progress === nothing && return false
    progress.pending -= 1
    if failed(r)
        progress.failure === nothing && (progress.failure = r.exception)
        if !keep_going
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
    if progress.failure !== nothing
        push!(ctx.summary.errored, t.name)
        record_failure!(ctx, t, progress.failure)
        return nothing
    end
    hashes = progress.hashes
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
            format = record_format(t),
            built_at = string(Dates.now(Dates.UTC)),
            seed = seed_string(resolve_seed(ctx.pipeline, t)),
            branches = ids,
            branch_hashes = hashes,
        ),
    )
    prune_branches!(ctx.store, t.name, ids)
    ctx.value_hashes[t.name] = value_hash
    previous = progress.previous
    changed = !isempty(built) ||
        previous === nothing ||
        previous.branches != ids ||
        previous.value_hash != value_hash ||
        !isempty(previous.error)
    if changed
        push!(ctx.summary.built, t.name)
        log!(ctx, "✔ $(t.name): $(length(built)) of $(length(ids)) branches built")
    else
        push!(ctx.summary.skipped, t.name)
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
