const STORE_FORMAT_VERSION = 1

"""
    project_root()

Directory of the active `Project.toml`.
"""
function project_root()
    project = Base.active_project()
    project === nothing &&
        error("no active project: activate one or pass `store` explicitly")
    return dirname(project)
end

"""
    Store(root)

A `_targets/`-style directory holding one object and one metadata record per
target. Open one with [`open_store`](@ref).
"""
struct Store
    root::String
end

default_store_path() = joinpath(project_root(), "_targets")

"""
    open_store(root = default_store_path())

Create the store layout if needed, or validate an existing store's format version.
"""
function open_store(root::AbstractString = default_store_path())
    store = Store(String(root))
    info_path = joinpath(root, "store.toml")
    if isfile(info_path)
        version = get(TOML.parsefile(info_path), "format_version", nothing)
        version == STORE_FORMAT_VERSION ||
            error(
                "store at `$root` has format version $(repr(version)), but this version of Targets " *
                    "supports $STORE_FORMAT_VERSION; destroy and rebuild it, or use a matching Targets version",
            )
    else
        mkpath.(joinpath.(root, ("objects", "meta", "log")))
        atomic_open(info_path) do io
            TOML.print(
                io,
                Dict(
                    "format_version" => STORE_FORMAT_VERSION,
                    "julia_version" => string(VERSION),
                ),
            )
        end
        write(joinpath(root, ".gitignore"), "*\n")
    end
    return store
end

object_path(s::Store, key) = joinpath(s.root, "objects", string(key) * ".jld2")
meta_path(s::Store, key) = joinpath(s.root, "meta", string(key) * ".toml")
log_path(s::Store) = joinpath(s.root, "log", "progress.log")

"""
    atomic_write(f, path)

Call `f(tmp)` with a temporary path in the same directory, then rename it over
`path`. A failure leaves any previous file untouched and removes the temporary.
"""
function atomic_write(f, path::AbstractString)
    mkpath(dirname(path))
    tmp = path * ".tmp-" * string(rand(UInt32); base = 16)
    try
        f(tmp)
        mv(tmp, path; force = true)
    finally
        rm(tmp; force = true)
    end
    return path
end

"Like [`atomic_write`](@ref), but `f` receives an open `IO`."
atomic_open(f, path::AbstractString) = atomic_write(tmp -> open(f, tmp, "w"), path)

## Objects

"""
Write `value` as the JLD2 object for `key`. Atomic.
"""
write_object(s::Store, key, value) = atomic_write(
    tmp -> JLD2.jldsave(tmp; value),
    object_path(s, key),
)

has_object(s::Store, key) = isfile(object_path(s, key))

function read_object(s::Store, key)
    path = object_path(s, key)
    isfile(path) || error("no stored object for target `$key` at $path")
    try
        return JLD2.load(path, "value")
    catch e
        e isa InterruptException && rethrow()
        error(
            "could not load the stored object for `$key`: $(sprint(showerror, e))\n" *
                "If its type is defined in `_targets.jl`, move the type into a named module " *
                "(for example your project package) and load it with `using`.",
        )
    end
end

delete_object(s::Store, key) = rm(object_path(s, key); force = true)

## Metadata

"""
    Record

Everything remembered about a built target; see the plan for field meanings.
Stored as one TOML file per target, written after the object (the commit marker).
"""
Base.@kwdef struct Record
    command_hash::String = ""
    code_hash::String = ""
    hash_source::String = "source"
    dep_hashes::Dict{String, String} = Dict{String, String}()
    value_hash::String = ""
    format::String = "jld2"
    built_at::String = ""
    seconds::Float64 = 0.0
    error::String = ""
    julia_version::String = string(VERSION)
end

Base.:(==)(a::Record, b::Record) = all(
    getfield(a, f) == getfield(b, f)
    for f in fieldnames(Record)
)

"A copy of `r` with some fields replaced."
update(r::Record; changes...) = Record(; merge(
    NamedTuple(f => getfield(r, f) for f in fieldnames(Record)),
    NamedTuple(changes),
)...)

record_dict(r::Record) = Dict{String, Any}(
    string(f) => getfield(r, f)
    for f in fieldnames(Record)
)

function Record(d::AbstractDict)
    known = Set(string.(fieldnames(Record)))
    kwargs = (Symbol(k) => v for (k, v) in d if k in known)
    return Record(; kwargs...)
end

write_meta(s::Store, key, r::Record) = atomic_open(
    io -> TOML.print(io, record_dict(r)),
    meta_path(s, key),
)

function read_meta(s::Store, key)
    path = meta_path(s, key)
    isfile(path) || return nothing
    return Record(TOML.parsefile(path))
end

delete_meta(s::Store, key) = rm(meta_path(s, key); force = true)

"""
    meta_keys(store)

Keys of all stored records (`"model"`, or `"fits/1a2b3c4d"` for branches), sorted.
"""
function meta_keys(s::Store)
    dir = joinpath(s.root, "meta")
    isdir(dir) || return String[]
    keys = String[]
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".toml") || continue
        rel = relpath(joinpath(root, f), dir)
        push!(keys, replace(chopsuffix(rel, ".toml"), '\\' => '/'))
    end
    return sort!(keys)
end

"""
    tar_meta(; store = default_store_path())

All metadata records as a vector of `NamedTuple`s (a Tables.jl-compatible table).
"""
function tar_meta(; store::Union{Store, AbstractString} = default_store_path())
    s = store isa Store ? store : Store(String(store))
    return [meta_row(s, k) for k in meta_keys(s)]
end

function meta_row(s::Store, key)
    r = read_meta(s, key)::Record
    return (; name = key, (f => getfield(r, f) for f in fieldnames(Record))...)
end

@testitem "open_store creates a versioned layout and validates it" begin
    using Targets: open_store, STORE_FORMAT_VERSION
    using TOML
    mktempdir() do dir
        root = joinpath(dir, "_targets")
        s = open_store(root)
        @test isdir(joinpath(root, "objects")) &&
            isdir(joinpath(root, "meta")) &&
            isdir(joinpath(root, "log"))
        @test read(joinpath(root, ".gitignore"), String) == "*\n"
        @test TOML.parsefile(joinpath(root, "store.toml"))["format_version"] ==
            STORE_FORMAT_VERSION
        @test open_store(root).root == s.root # reopening is fine
        write(joinpath(root, "store.toml"), "format_version = 999\n")
        @test_throws "format version" open_store(root)
    end
end

@testitem "objects round-trip through JLD2" begin
    using Targets: open_store, write_object, read_object, has_object, delete_object
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        values = Dict(
            :nt => (a = 1, b = "two", c = [1.0, 2.0]),
            :dict => Dict("x" => 1, "y" => [1, 2]),
            :matrix => rand(3, 3),
            :nothing => nothing,
        )
        for (k, v) in values
            @test !has_object(s, k)
            write_object(s, k, v)
            @test has_object(s, k)
            @test read_object(s, k) == v
        end
        write_object(s, "fits/1a2b3c4d", 42) # branch-style key
        @test read_object(s, "fits/1a2b3c4d") == 42
        delete_object(s, :nt)
        @test !has_object(s, :nt)
        @test_throws "no stored object" read_object(s, :nt)
    end
end

@testitem "a failed write never corrupts or leaves temporaries" begin
    using Targets: open_store, write_object, read_object, atomic_open, object_path
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        write_object(s, :good, [1, 2, 3])
        # an unserializable-by-design failure part-way through a write
        path = joinpath(dir, "target.txt")
        write(path, "old")
        @test_throws ErrorException atomic_open(path) do io
            write(io, "partial")
            error("killed mid-write")
        end
        @test read(path, String) == "old"
        @test readdir(dir) == ["_targets", "target.txt"]
        @test read_object(s, :good) == [1, 2, 3]
        @test isempty(filter(contains(".tmp-"), readdir(dirname(object_path(s, :good)))))
    end
end

@testitem "metadata round-trips and tar_meta assembles a table" begin
    using Targets:
        open_store,
        write_meta,
        read_meta,
        delete_meta,
        Record,
        tar_meta,
        meta_keys
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        @test read_meta(s, :model) === nothing
        r = Record(
            command_hash = "abc",
            code_hash = "def",
            dep_hashes = Dict("clean" => "123"),
            value_hash = "456",
            seconds = 1.5,
        )
        write_meta(s, :model, r)
        write_meta(s, "fits/1a2b3c4d", Record(value_hash = "789"))
        @test read_meta(s, :model) == r
        @test meta_keys(s) == ["fits/1a2b3c4d", "model"]
        table = tar_meta(; store = s)
        @test map(row -> row.name, table) == ["fits/1a2b3c4d", "model"]
        @test table[2].command_hash == "abc"
        @test table[2].dep_hashes == Dict("clean" => "123")
        delete_meta(s, :model)
        @test meta_keys(s) == ["fits/1a2b3c4d"]
    end
end
