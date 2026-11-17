"""
Julia-version-independent encoding of expressions and plain data.

`Expr` printing and the `Serialization` format may change between Julia
releases, so everything that is persisted as a hash goes through this single
tagged, length-prefixed byte encoding instead. `LineNumberNode`s are ignored so
that moving code does not change its hash.
"""
canonical_bytes(x) = (io = IOBuffer(); write_canonical(io, x); take!(io))

"Hex SHA-256 of the canonical encoding of `x`."
canonical_hash(x) = bytes2hex(SHA.sha256(canonical_bytes(x)))

# Hex SHA-256 of a collection of already-computed hashes or strings, order-independent.
combine_hashes(hashes) = bytes2hex(SHA.sha256(
    join(sort!(collect(String, hashes)), "\n")::String,
))

# Types are written with their module path relative to Base, not to Main: how a
# type prints in Main depends on what the session happens to have loaded (for
# example a package exporting a name that clashes with one of ours), and the
# hash must be the same in every process.
# Generated names (see `stable_name`) are written without their counters.
type_string(T) = strip_counters(sprint(show, T; context = :module => Base))

# Julia numbers the functions it generates (keyword bodies `#f#12`, anonymous
# functions `#3#4`, closures `#f##0`) from a counter shared by the whole module,
# so their numbers change whenever code defined earlier in the module does, and
# differ between a fresh session and one where Revise re-evaluated code. A `#`
# never precedes a digit in other names that reach a hash.
strip_counters(s::AbstractString) = replace(s, r"(?<=#)\d+" => "")

"""
    stable_name(name::Symbol)

`name` without the module-wide counters of generated functions: `#f#12`
becomes `#f#` and `#3#4` becomes `##`. Other names are unchanged. What a
generated function does is hashed from its definition, not its name.
"""
stable_name(name::Symbol) = startswith(String(name), '#') ?
    Symbol(strip_counters(String(name))) :
    name

"Whether `T` is the type of a function Julia generated: an anonymous function or closure."
is_generated_function_type(T) = T isa DataType &&
    T <: Function &&
    startswith(String(nameof(T)), '#')

function write_tagged(io::IO, tag::Char, payload::AbstractString)
    write(io, UInt8(tag))
    write(io, string(ncodeunits(payload)), UInt8(':'), payload)
end

write_count(io::IO, tag::Char, n::Integer) = (write(io, UInt8(tag), string(n), UInt8(':')))

write_canonical(io::IO, ::Nothing) = write(io, UInt8('N'))
write_canonical(io::IO, ::Missing) = write(io, UInt8('m'))
write_canonical(io::IO, x::Bool) = write(io, UInt8('B'), x ? UInt8('1') : UInt8('0'))
write_canonical(io::IO, x::Integer) = write_tagged(
    io,
    'I',
    string(type_string(typeof(x)), ":", x),
)
write_canonical(io::IO, x::AbstractFloat) = write_tagged(
    io,
    'F',
    string(type_string(typeof(x)), ":", bitstring(x)),
)
write_canonical(io::IO, x::AbstractString) = write_tagged(io, 'S', String(x))
write_canonical(io::IO, x::Symbol) = write_tagged(io, 'Y', String(x))
write_canonical(io::IO, x::Char) = write_tagged(io, 'C', string(UInt32(x)))
write_canonical(io::IO, x::Module) = write_tagged(io, 'O', string(x))
write_canonical(io::IO, x::Type) = write_tagged(io, 'K', type_string(x))
write_canonical(io::IO, x::GlobalRef) = write_tagged(io, 'G', string(x.mod, ".", x.name))
write_canonical(io::IO, x::QuoteNode) = (
    write(io, UInt8('Q'));
    write_canonical(io, x.value)
)

function write_each(io::IO, tag::Char, xs, n::Integer = length(xs))
    write_count(io, tag, n)
    for x in xs
        write_canonical(io, x)
    end
end

write_canonical(io::IO, x::Tuple) = write_each(io, 'T', x)
write_canonical(io::IO, x::NamedTuple) = (
    write_each(io, 'M', keys(x));
    write_each(io, 'v', values(x))
)
write_canonical(io::IO, x::Pair) = write_each(io, 'P', (x.first, x.second))
write_canonical(io::IO, x::AbstractArray) = (
    write_tagged(io, 'A', string(type_string(eltype(x)), size(x)));
    write_each(io, 'a', x)
)

# Unordered collections are encoded in a canonical order of their element encodings.
function write_unordered(io::IO, tag::Char, encoded::Vector{Vector{UInt8}})
    write_count(io, tag, length(encoded))
    foreach(e -> write(io, e), sort!(encoded))
end

write_canonical(io::IO, x::AbstractDict) = write_unordered(
    io,
    'D',
    [canonical_bytes(k => v) for (k, v) in x],
)
write_canonical(io::IO, x::AbstractSet) = write_unordered(
    io,
    'H',
    [canonical_bytes(e) for e in x],
)

function write_canonical(io::IO, x::Expr)
    args = filter(a -> !(a isa LineNumberNode), x.args)
    write_tagged(io, 'E', String(x.head))
    write_each(io, 'e', args)
end
write_canonical(io::IO, ::LineNumberNode) = nothing

# Anonymous functions and closures by what they do (the hashes of their
# methods' definitions, see `method_hash`) and the values they capture, since
# their type names carry module-wide counters. Methods are sorted so that their
# order does not matter.
function write_closure(io::IO, f)
    write_tagged(io, 'L', type_string(typeof(f)))
    write_each(io, 'l', sort!([something(method_hash(m).hash, "") for m in methods(f)]))
    write_each(io, 'r', (getfield(f, i) for i in 1:nfields(f)), nfields(f))
end

# Plain immutable structs by type name and fields; anything else falls back to
# Serialization, which is not guaranteed stable across Julia versions.
function write_canonical(io::IO, x::T) where {T}
    if is_generated_function_type(T)
        write_closure(io, x)
    elseif x isa Function && Base.issingletontype(T)
        write_tagged(io, 'U', type_string(T))
    elseif isstructtype(T) && !ismutabletype(T)
        write_tagged(io, 'R', type_string(T))
        write_each(io, 'r', (getfield(x, i) for i in 1:nfields(x)), nfields(x))
    else
        @warn "hashing a value of type $T with Serialization, which is not stable across Julia versions" _id = Symbol(
            string(T),
        ) maxlog = 1
        buf = IOBuffer()
        Serialization.serialize(buf, x)
        write_tagged(io, 'Z', String(take!(buf)))
    end
end

@testitem "types are encoded independently of what Main has loaded" begin
    using Targets: type_string
    @test type_string(Targets.Cross) == "Targets.Cross" # even after `using Targets`
    @test type_string(Int) == "Int64"
    @test type_string(Vector{Union{Symbol, Targets.Pattern}}) ==
        "Vector{Union{Symbol, Targets.Pattern}}"
end

@testitem "canonical hash distinguishes values and ignores ordering of unordered collections" setup = [
    JETChecks,
] begin
    using Targets: canonical_hash
    @test canonical_hash(1) != canonical_hash(1.0)
    @test canonical_hash(1) != canonical_hash(Int32(1))
    @test canonical_hash("a") != canonical_hash(:a)
    @test canonical_hash((1, 2)) != canonical_hash([1, 2])
    @test canonical_hash([1, 2]) != canonical_hash([2, 1])
    @test canonical_hash([1 2; 3 4]) != canonical_hash([1 3; 2 4])
    @test canonical_hash(Dict(:a => 1, :b => 2)) == canonical_hash(Dict(:b => 2, :a => 1))
    @test canonical_hash(Set([1, 2, 3])) == canonical_hash(Set([3, 2, 1]))
    @test canonical_hash((a = 1, b = 2)) != canonical_hash((b = 1, a = 2))
    @test canonical_hash(["ab", "c"]) != canonical_hash(["a", "bc"]) # length-prefixed
    @test canonical_hash(1 // 2) == canonical_hash(1 // 2)
    @test canonical_hash(nothing) != canonical_hash(missing)
    @test_call canonical_hash((
        1,
        1.0,
        "a",
        :a,
        'c',
        [1 2; 3 4],
        Dict(:a => 1),
        Set([1]),
        (a = 1,),
        1 // 2,
        nothing,
        missing,
        :(f(x)),
    ))
end

@testitem "canonical hash of expressions ignores line numbers and formatting" begin
    using Targets: canonical_hash
    a = Meta.parse("function f(x)\n    # comment\n    x + 1\nend")
    b = Meta.parse("function f(x) x+1 end")
    c = Meta.parse("function f(x)\n    x + 2\nend")
    @test canonical_hash(a) == canonical_hash(b)
    @test canonical_hash(a) != canonical_hash(c)
    @test canonical_hash(:(f(x))) != canonical_hash(:(g(x)))
    @test canonical_hash(:(a.b)) == canonical_hash(Meta.parse("a.b"))
end

@testitem "canonical hash is stable: golden values" begin
    using Targets: canonical_hash
    # If these change, hashes persisted by older versions or other Julia
    # versions would no longer match and users would see spurious rebuilds.
    @test canonical_hash(Meta.parse("function f(x)\n x + 1\nend")) ==
        "59872c26ddfbd709d0b17a2f716d7ca0e513e51314b42e1ab2d43705c1329445"
    @test canonical_hash((a = 1, b = "two", c = [1.0, 2.0], d = Dict(:k => 'v'))) ==
        "3093e8c336749dd9afbbaa2a5afd94f104aad5e094c775c71108e4f862a170d8"
end

@testitem "canonical hash is identical across processes" begin
    using Targets: canonical_hash
    expr = "canonical_hash((x = [1, 2, 3], y = Dict(:a => 'b'), z = :(f(g(1)))))"
    here = canonical_hash((x = [1, 2, 3], y = Dict(:a => 'b'), z = :(f(g(1)))))
    project = dirname(Base.active_project())
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e "using Targets; print($(string("Targets.", expr)))"`
    @test read(cmd, String) == here
end
