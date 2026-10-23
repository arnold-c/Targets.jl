"""
    outdated_reason(store, t, cmd, dep_hashes; forced = false)

Why target `t` must be rebuilt, or `nothing` if it is up to date. The first rule
that applies wins, so the reason is meaningful in logs and in `tar_outdated()`.
`dep_hashes` maps each upstream name to its current value hash.

Reasons, in order: `:forced`, `:always`, `:no_source`, `:missing`, `:errored`,
`:julia_version_changed`, `:command_changed`, `:deps_changed`, `:upstream_changed`.
"""
function outdated_reason(
    store::Store,
    t::Target,
    cmd::CommandHash,
    dep_hashes::AbstractDict{Symbol, String};
    forced::Bool = false,
)
    forced && return :forced
    t.cue == :always && return :always
    cmd.hash === nothing && return :no_source
    object_exists = has_object(store, t.name)
    t.cue == :never && object_exists && return nothing
    record = read_meta(store, t.name)
    (record === nothing || !object_exists) && return :missing
    isempty(record.error) || return :errored
    record.hash_source == "lowered" &&
        record.julia_version != string(VERSION) &&
        return :julia_version_changed
    record.command_hash == cmd.hash || return :command_changed
    Set(keys(record.dep_hashes)) == Set(string.(t.deps)) || return :deps_changed
    for d in t.deps
        record.dep_hashes[string(d)] == dep_hashes[d] || return :upstream_changed
    end
    return nothing
end

"Value hash of an up-to-date target: from its record, or from its object if it has none."
function stored_value_hash(store::Store, name::Symbol)
    record = read_meta(store, name)
    record === nothing || return record.value_hash
    return hash_file(object_path(store, name))
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
        update
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        t = target(:m, clean -> clean)
        cmd = CommandHash("c1", :source)
        deps = Dict(:clean => "h1")
        reason(; kw...) = outdated_reason(s, t, cmd, deps; kw...)

        @test reason() == :missing # nothing stored
        write_object(s, :m, 1)
        @test reason() == :missing # object but no record
        good = Record(
            command_hash = "c1",
            dep_hashes = Dict("clean" => "h1"),
            value_hash = "v",
        )
        write_meta(s, :m, good)
        @test reason() === nothing
        @test reason(; forced = true) == :forced

        write_meta(s, :m, update(good; error = "boom"))
        @test reason() == :errored
        write_meta(s, :m, update(good; command_hash = "other"))
        @test reason() == :command_changed
        write_meta(s, :m, update(good; dep_hashes = Dict("other" => "h1")))
        @test reason() == :deps_changed
        write_meta(s, :m, update(good; dep_hashes = Dict("clean" => "h2")))
        @test reason() == :upstream_changed
        write_meta(s, :m, update(good; hash_source = "lowered", julia_version = "0.0.1"))
        @test reason() == :julia_version_changed

        write_meta(s, :m, good)
        @test outdated_reason(s, t, CommandHash(nothing, :unknown), deps) == :no_source
        @test outdated_reason(s, target(:m, clean -> 1; cue = :always), cmd, deps) ==
            :always
        write_meta(s, :m, update(good; command_hash = "other"))
        @test outdated_reason(s, target(:m, clean -> 1; cue = :never), cmd, deps) ===
            nothing
    end
end
