"""
    outdated_reason(store, t, cmd, code, dep_hashes; seed, forced = false,
                    root = nothing, key = t.name)

Why target `t` must be rebuilt, or `nothing` if it is up to date. The first rule
that applies wins, so the reason is meaningful in logs and in `tar_outdated()`.
`cmd` and `code` are the target's current command and code hashes, and
`dep_hashes` maps each upstream name to its current value hash, and `seed` is
the recorded form of the seed it would run with ([`seed_string`](@ref)).

`now` is the clock for `cue_age` (a parameter so tests can set it).

Reasons, in order: `:forced`, `:always`, `:condition`, `:no_source`, `:errored`
(the last build failed, whether or not an earlier value is stored), `:missing`,
`:expired`,
`:julia_version_changed`, `:command_changed`, `:seed_changed`, `:format_changed`,
`:code_changed`, `:deps_changed`,
`:upstream_changed`, `:file_changed`, `:url_changed`. File targets are re-checked on every call
(`root` locates their files). `key` is where the record lives: `t.name`, or
`"name/id"` for one branch of a branching target (a branching target as a whole
is outdated if any recorded branch object is missing): a missing file makes them `:missing`, and changed
contents `:file_changed`.
"""
function outdated_reason(
    store::Store,
    t::Target,
    cmd::CommandHash,
    code::AbstractString,
    dep_hashes::AbstractDict{Symbol, String};
    seed::AbstractString,
    forced::Bool = false,
    root::Union{Nothing, AbstractString} = nothing,
    key = t.name,
    now::Dates.DateTime = Dates.now(Dates.UTC),
)
    forced && return :forced
    t.cue == :always && return :always
    t.cue isa ForceCue && t.cue.condition && return :condition
    cmd.hash === nothing && return :no_source
    record = read_meta(store, key)
    stored = if t.format == :url
        record !== nothing
    elseif t.format == :file
        record !== nothing && files_exist(file_root(root), record)
    elseif t.pattern !== nothing && key == t.name
        # a branching target, not one branch
        record !== nothing && all(id -> has_object(store, "$(t.name)/$id"), record.branches)
    else
        has_object(store, key)
    end
    # objects in a format tied to the Julia version cannot be read after an upgrade
    if stored && !is_external(t) && version_bound(resolve_format(t.format))
        stored = something(record).julia_version == string(VERSION)
    end
    t.cue == :never && stored && return nothing
    record === nothing || isempty(record.error) || return :errored
    (record === nothing || !stored) && return :missing
    expired(t.cue, record.built_at, now) && return :expired
    record.hash_source == "lowered" &&
        record.julia_version != string(VERSION) &&
        return :julia_version_changed
    if checks(t.cue, :command)
        record.command_hash == cmd.hash || return :command_changed
        record.seed == seed || return :seed_changed
    end
    same_format(record, t) || return :format_changed
    checks(t.cue, :code) && record.code_hash != code && return :code_changed
    if checks(t.cue, :depend)
        Set(keys(record.dep_hashes)) == Set(string.(t.deps)) || return :deps_changed
        for d in t.deps
            record.dep_hashes[string(d)] == dep_hashes[d] || return :upstream_changed
        end
    end
    checks(t.cue, :file) || return nothing
    if t.format == :url
        url_state(record).value_hash == record.value_hash || return :url_changed
    elseif t.format == :file
        file_state(file_root(root), record).value_hash == record.value_hash ||
            return :file_changed
    end
    return nothing
end

"Value hash of an up-to-date target: from its record, or from its object if it has none. (For a file target the record's hash equals the files' current hash, or it would not be up to date.)"
function stored_value_hash(store::Store, key)
    record = read_meta(store, key)
    record === nothing || return record.value_hash
    return hash_file(something(find_object(store, key), object_path(store, key)))
end

"""
    tar_outdated(p::Pipeline; names = nothing, store = default_store_path(), root = nothing)

Targets that a build would have to rebuild, with the reason for each, as a vector
of `(; name, reason)` in build order. Conservative: without building, it cannot
know whether a rebuilt upstream will produce the same value, so every descendant
of an outdated target is reported as `:upstream_outdated` (a real build may still
skip some of them through early cutoff). `tar_outdated()` with no argument loads
`_targets.jl`.
"""
function tar_outdated(
    p::Pipeline;
    names = nothing,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
)
    s = as_store(store)
    rootdir = something(root, project_root())
    discovery = Discovery(user_roots(rootdir, p.track))
    outdated = Dict{Symbol, Symbol}()
    result = NamedTuple{(:name, :reason), Tuple{Symbol, Symbol}}[]
    for name in selected_order(p, names)
        t = get_target(p, name)
        reason = if any(d -> haskey(outdated, d), t.deps)
            :upstream_outdated
        else
            dep_hashes = Dict{Symbol, String}(d => stored_value_hash(s, d) for d in t.deps)
            outdated_reason(
                s,
                t,
                command_hash(t),
                code_hash(discovery, t),
                dep_hashes;
                seed = seed_string(resolve_seed(p, t)),
                root = rootdir,
            )
        end
        reason === nothing && continue
        outdated[name] = reason
        push!(result, (; name, reason))
    end
    return result
end

function tar_outdated(; script::AbstractString = default_script(), kwargs...)
    return tar_outdated(load_pipeline(script); kwargs...)
end

@testitem "outdated_reason reports the first applicable reason" begin
    using Targets:
        outdated_reason,
        open_store,
        write_object,
        write_meta,
        Record,
        CommandHash,
        command_hash,
        update,
        delete_object
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        t = target(:m, clean -> clean)
        cmd = CommandHash("c1", :source)
        deps = Dict(:clean => "h1")
        reason(; kw...) = outdated_reason(s, t, cmd, "k1", deps; seed = "", kw...)

        @test reason() == :missing # nothing stored
        write_object(s, :m, 1)
        @test reason() == :missing # object but no record
        good = Record(
            command_hash = "c1",
            code_hash = "k1",
            dep_hashes = Dict("clean" => "h1"),
            value_hash = "v",
        )
        write_meta(s, :m, good)
        @test reason() === nothing
        @test reason(; forced = true) == :forced

        write_meta(s, :m, update(good; error = "boom"))
        @test reason() == :errored
        delete_object(s, :m) # failed without ever storing a value
        @test reason() == :errored
        write_object(s, :m, 1)
        write_meta(s, :m, update(good; command_hash = "other"))
        @test reason() == :command_changed
        write_meta(s, :m, update(good; seed = "1"))
        @test reason() == :seed_changed
        write_meta(s, :m, update(good; code_hash = "other"))
        @test reason() == :code_changed
        write_meta(s, :m, update(good; dep_hashes = Dict("other" => "h1")))
        @test reason() == :deps_changed
        write_meta(s, :m, update(good; dep_hashes = Dict("clean" => "h2")))
        @test reason() == :upstream_changed
        write_meta(s, :m, update(good; hash_source = "lowered", julia_version = "0.0.1"))
        @test reason() == :julia_version_changed

        write_meta(s, :m, good)
        @test outdated_reason(
            s,
            t,
            CommandHash(nothing, :unknown),
            "k1",
            deps;
            seed = "",
        ) ==
            :no_source
        always = target(:m, clean -> 1; cue = :always)
        @test outdated_reason(s, always, cmd, "k1", deps; seed = "") == :always
        write_meta(s, :m, update(good; command_hash = "other"))
        never = target(:m, clean -> 1; cue = :never)
        @test outdated_reason(s, never, cmd, "k1", deps; seed = "") === nothing
    end
end
