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

"""
    method_hash(m::Method)

Hash of a single method: its definition if it can be found, else its lowered
code, in which references to generated functions are replaced by what those
functions do (`stable_lowered`).
"""
method_hash(m::Method) = method_hash(m, Set{Method}())

function method_hash(m::Method, visiting::Set{Method})
    exprs = method_source(m)
    exprs === nothing || return CommandHash(canonical_hash(exprs), :source)
    lowered = lowered_source(m)
    lowered === nothing && return CommandHash(nothing, :unknown)
    push!(visiting, m)
    try
        return CommandHash(canonical_hash(stable_lowered(lowered, visiting)), :lowered)
    finally
        delete!(visiting, m)
    end
end

"""
    stable_lowered(x, visiting)

Lowered code `x` with every reference to a generated function (keyword body,
anonymous function, closure) replaced by its stable name and the hashes of its
methods. Their names carry module-wide counters (`stable_name`), so the
reference identifies the function by content instead. `visiting` holds the
methods being hashed, so that recursion stops at its own name.
"""
stable_lowered(x, visiting) = x
# Slot names include generated names too (a keyword body's `#self#` is `#f#12`).
stable_lowered(x::Symbol, visiting) = stable_name(x)
stable_lowered(x::Expr, visiting) = Expr(
    x.head,
    (stable_lowered(a, visiting) for a in x.args)...
)
stable_lowered(x::Tuple, visiting) = map(a -> stable_lowered(a, visiting), x)
stable_lowered(x::Core.ReturnNode, visiting) = isdefined(x, :val) ?
    Core.ReturnNode(stable_lowered(x.val, visiting)) :
    x
stable_lowered(x::Core.GotoIfNot, visiting) = Core.GotoIfNot(
    stable_lowered(x.cond, visiting),
    x.dest,
)
# Keep the element type, which is part of the encoding, unless a replacement needs `Any`.
function stable_lowered(x::AbstractVector, visiting)
    y = Any[stable_lowered(a, visiting) for a in x]
    return all(v -> v isa eltype(x), y) ? convert(Vector{eltype(x)}, y) : y
end
function stable_lowered(x::GlobalRef, visiting)
    name = stable_name(x.name)
    name === x.name && return x
    hashes = sort!([
        m in visiting ? "recursive" : something(method_hash(m, visiting).hash, "")
        for m in generated_methods(x)
    ])
    return (GlobalRef(x.mod, name), hashes)
end

"""
Methods of the generated function `ref` names: a keyword body or anonymous
function (a function object), or a closure type (its call methods). Empty if
the name is no longer defined.
"""
function generated_methods(ref::GlobalRef)
    latest_isdefined(ref.mod, ref.name) || return Method[]
    f = latest_getglobal(ref.mod, ref.name)
    f isa Function && return collect(methods(f))
    is_generated_function_type(f) || return Method[]
    matches = Base._methods_by_ftype(Tuple{f, Vararg{Any}}, -1, Base.get_world_counter())
    matches isa AbstractVector || return Method[]
    return Method[match.method for match in matches]
end

# A closure is an object whose fields are its captured variables. Named
# functions are followed by recursive discovery, so only their type is recorded;
# generated ones are recorded by what they do (see `write_closure`).
captured_value(x::Core.Box) = captured_value(x.contents)
captured_value(x::Function) = is_generated_function_type(typeof(x)) ?
    x :
    type_string(typeof(x))
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
target_kind(t::Target) = is_external(t) ? t.format : :jld2

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

@testitem "command_hash follows captured anonymous functions by content" setup = [
    SourceFixtures,
] begin
    using Targets: command_hash
    function hash_of(body; before = "")
        m, _ = load_source(
            """
        $before
        helper = x -> $body
        make(f) = target(:a, () -> f(1))
        t = make(helper)
        """,
        )
        return command_hash(Base.invokelatest(getproperty, m, :t))
    end
    @test hash_of("x + 1") != hash_of("x + 2")
    @test hash_of("x + 1") == hash_of("x + 1"; before = "unused = [y -> y for _ in 1:3]")
end

@testitem "lowered code identifies generated functions by content, not counter" begin
    using Targets: method_hash, stable_name
    @test stable_name(Symbol("#f#266")) == Symbol("#f#")
    @test stable_name(Symbol("##f#270")) == Symbol("##f#")
    @test stable_name(Symbol("#539#540")) == Symbol("##")
    @test stable_name(:f2) == :f2
    # Code evaluated without a file can only be hashed from lowered code, where
    # `f(x)` calls its keyword body `#f#N`.
    function hash_of(body; before = "")
        m = Module(:Lowered)
        Core.eval(m, Meta.parse("begin\n$before\nf(x; k = 1) = x + $body * k\nend"))
        f = Base.invokelatest(getproperty, m, :f)
        return method_hash(only(methods(f)))
    end
    @test hash_of("2").kind == :lowered
    @test hash_of("2") == hash_of("2"; before = "g(; a = 1) = a")
    @test hash_of("2") != hash_of("3") # the change is in the keyword body
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
