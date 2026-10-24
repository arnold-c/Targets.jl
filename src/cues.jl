## Cues: when a target counts as outdated
##
## `cue` is `:thorough` (every rule), `:always` or `:never`, or one of the cue
## values below.

"Supertype of cue values: [`cue_age`](@ref), [`cue_force`](@ref) and [`Cue`](@ref)."
abstract type CueRule end

struct AgeCue <: CueRule
    age::Dates.Period
end

"""
    cue_age(age::Dates.Period)

Rebuild the target (reason `:expired`) once its last build is older than `age`,
for scraped or remote data, e.g. `cue = cue_age(Day(7))`.
"""
cue_age(age::Dates.Period) = AgeCue(age)

struct ForceCue <: CueRule
    condition::Bool
end

"""
    cue_force(condition::Bool)

Rebuild the target (reason `:condition`) whenever `condition` is true; it is
evaluated when the pipeline is loaded.
"""
cue_force(condition::Bool) = ForceCue(condition)

"""
    Cue(; command = true, code = true, depend = true, file = true)

Thorough checking with some rules turned off: `command = false` ignores edits
to the target's own code (and its seed), `code = false` edits to the code it
calls, `depend = false` changes upstream, and `file = false` changes to its
files or URLs. For example, `Cue(code = false)` keeps an expensive simulation
from rebuilding after a refactor. Missing or failed targets are always rebuilt.
"""
Base.@kwdef struct Cue <: CueRule
    command::Bool = true
    code::Bool = true
    depend::Bool = true
    file::Bool = true
end

"Whether the cue of a target checks `rule` (`:command`, `:code`, `:depend` or `:file`)."
checks(cue, rule::Symbol) = cue isa Cue ? getfield(cue, rule) : true

"Whether a target built at `built_at` has expired under `cue` at time `now`."
function expired(cue, built_at::AbstractString, now::Dates.DateTime)
    cue isa AgeCue || return false
    built = tryparse(Dates.DateTime, built_at)
    return built === nothing || built + cue.age < now
end

@testitem "cues: age, condition and switched-off rules" begin
    using Targets:
        outdated_reason,
        open_store,
        write_object,
        write_meta,
        Record,
        CommandHash
    using Dates
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        built = DateTime(2024, 1, 1)
        good = Record(;
            command_hash = "c1",
            code_hash = "k1",
            dep_hashes = Dict("a" => "h1"),
            value_hash = "v",
            built_at = string(built),
        )
        write_object(s, :m, 1)
        write_meta(s, :m, good)
        reason(
            cue;
            cmd = "c1",
            code = "k1",
            up = "h1",
            now = built + Day(1),
        ) = outdated_reason(
            s,
            target(:m, a -> a; cue),
            CommandHash(cmd, :source),
            code,
            Dict(:a => up);
            seed = "",
            now,
        )
        @test reason(:thorough) === nothing
        @test reason(cue_age(Day(7))) === nothing
        @test reason(cue_age(Day(7)); now = built + Day(8)) == :expired
        @test reason(cue_force(true)) == :condition
        @test reason(cue_force(false)) === nothing
        @test reason(Cue(command = false); cmd = "c2") === nothing
        @test reason(Cue(command = false); code = "k2") == :code_changed
        @test reason(Cue(code = false); code = "k2") === nothing
        @test reason(Cue(depend = false); up = "h2") === nothing
        @test reason(:thorough; up = "h2") == :upstream_changed
    end
    @test_throws "cue must be" target(:x, () -> 1; cue = :sometimes)
end
