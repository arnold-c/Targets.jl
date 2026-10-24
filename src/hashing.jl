"""
    CommandHash(hash, kind)

Hash of a target's own code. `kind` records how it was obtained: `:source`
(from the parsed definition, stable across Julia versions), `:lowered` (from
lowered code, which is Julia-version dependent) or `:unknown` (`hash` is
`nothing`; the target must always be rebuilt).
"""
struct CommandHash
    hash::Union{Nothing, String}
    kind::Symbol
end

"Hash of a single method: its definition if it can be found, else its lowered code."
function method_hash(m::Method)
    exprs = method_source(m)
    exprs === nothing || return CommandHash(canonical_hash(exprs), :source)
    lowered = lowered_source(m)
    lowered === nothing || return CommandHash(canonical_hash(lowered), :lowered)
    return CommandHash(nothing, :unknown)
end

# A closure is an object whose fields are its captured variables. Captured
# functions are followed by recursive discovery, so only their type is recorded.
captured_value(x::Core.Box) = captured_value(x.contents)
captured_value(x::Function) = string(typeof(x))
captured_value(x) = x

function closure_captures(f)
    nfields(f) == 0 && return ()
    return Tuple(
        fieldname(typeof(f), i) => captured_value(getfield(f, i))
        for i in 1:nfields(f)
    )
end

# Whether a target stores files or an object. (Recorded as `:jld2` for objects so
# that hashes from before storage formats existed stay valid; the storage format
# itself is tracked separately, as `:format_changed`.)
target_kind(t::Target) = t.format === :file ? :file : :jld2

"""
    command_hash(t::Target)

Hash of the target's function (or of its macro-captured source) together with
the values its closure captured, so that loop-generated targets that share one
source text are still told apart.
"""
function command_hash(t::Target)
    own = t.source === nothing ?
        method_hash(single_method(t.f, t.name)) :
        CommandHash(canonical_hash(t.source), :source)
    own.hash === nothing && return own
    return CommandHash(
        canonical_hash((own.hash, closure_captures(t.f), target_kind(t), t.pattern)),
        own.kind,
    )
end

## Values and files

"""
    Targets.value_hash(x)

Extension point: return a string to hash `x` semantically (for example for a
type whose serialized bytes are not deterministic). The default, `nothing`,
means "hash the bytes of the stored object file".
"""
value_hash(::Any) = nothing

"Hex SHA-256 of the contents of `path`."
hash_file(path::AbstractString) = open(io -> bytes2hex(SHA.sha256(io)), path)

"Hash of a freshly written target value, using the user hook when present."
function object_hash(value, path::AbstractString)
    custom = value_hash(value)
    custom === nothing || return bytes2hex(SHA.sha256(string(custom)))
    return hash_file(path)
end

@testitem "command_hash ignores formatting and tracks edits to the function" setup = [
    SourceFixtures,
] begin
    using Targets: command_hash
    code(body, extra = "") = """
    $extra
    helper(x) = $body
    t = target(:a, () -> helper(1))
    """
    m1, _ = load_source(code("x + 1"))
    m2, _ = load_source(code("x +   1", "# a new comment\n\n")) # moved + reformatted
    m3, _ = load_source("t = target(:a, () -> helper(2))")
    h(m) = command_hash(m.t)
    @test h(m1).kind == :source
    @test h(m1) == h(m2)
    @test h(m1).hash != h(m3).hash
end

@testitem "command_hash separates lambdas on neighbouring lines of one pipeline call" setup = [
    SourceFixtures,
] begin
    using Targets: command_hash
    pipeline_code(second) = """
    p = tar_pipeline(
        target(:a, () -> 1),
        target(:b, a -> $second),
        target(:c, b -> b * 2),
    )
    """
    before, _ = load_source(pipeline_code("a + 1"))
    after, _ = load_source(pipeline_code("a + 2"))
    hashes(m) = [command_hash(t).hash for t in m.p.targets]
    hb, ha = hashes(before), hashes(after)
    @test ha[1] == hb[1]
    @test ha[2] != hb[2]
    @test ha[3] == hb[3]
    @test allunique(hb)
end

@testitem "command_hash is conservative for lambdas that cannot be told apart" setup = [
    SourceFixtures,
] begin
    using Targets: command_hash
    m, _ = load_source("pair = (target(:a, x -> x + 1), target(:b, x -> x + 2))")
    m2, _ = load_source("pair = (target(:a, x -> x + 1), target(:b, x -> x + 3))")
    a, b = command_hash.(m.pair)
    a2, b2 = command_hash.(m2.pair)
    @test a == b # same line, same arguments: hashed together
    @test a2 == b2
    @test a.hash != a2.hash # editing either rebuilds both
end

@testitem "command_hash includes closure captures" setup = [SourceFixtures] begin
    using Targets: command_hash
    m, _ = load_source(
        """
    fit(model, data) = (model, data)
    fits = [target(Symbol(:fit_, k), data -> fit(k, data)) for k in (:ols, :ridge)]
    again = [target(Symbol(:fit_, k), data -> fit(k, data)) for k in (:ols, :ridge)]
    """,
    )
    h = [command_hash(t).hash for t in m.fits]
    @test h[1] != h[2]
    @test h == [command_hash(t).hash for t in m.again]
end

@testitem "command_hash falls back to lowered code without source" begin
    using Targets: command_hash
    make(body) = target(:a, eval(Meta.parse("x -> $body")))
    a, a2, b = command_hash(make("x + 1")),
        command_hash(make("x + 1")),
        command_hash(make("x + 2"))
    @test a.kind == :lowered
    @test a == a2
    @test a.hash != b.hash
end

@testitem "command_hash uses macro-captured source when present" begin
    using Targets: command_hash, canonical_hash
    t = target(:a, () -> 1; source = :(f(1)))
    u = target(:a, () -> 2; source = :(f(1)))
    @test command_hash(t) == command_hash(u)
    @test command_hash(t).kind == :source
end

@testitem "value hashes use the object file unless a hook is defined" begin
    using Targets: Targets, hash_file, object_hash, open_store, write_object, object_path
    struct Wrapped
        x::Int
    end
    Targets.value_hash(w::Wrapped) = string(w.x)
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        write_object(s, :a, [1, 2, 3])
        write_object(s, :b, [1, 2, 3])
        write_object(s, :c, [1, 2, 4])
        h(k, v) = object_hash(v, object_path(s, k))
        @test h(:a, [1, 2, 3]) == hash_file(object_path(s, :a))
        @test h(:a, [1, 2, 3]) != h(:c, [1, 2, 4])
        @test h(:a, Wrapped(1)) == h(:b, Wrapped(1))
        @test h(:a, Wrapped(1)) != h(:a, Wrapped(2))
    end
end
