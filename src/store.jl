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

"A `Store` for a store or a path to one (without creating anything)."
as_store(store::Store) = store
as_store(store::AbstractString) = Store(abspath(String(store)))

"""
    default_store_path()

The store used when none is given. In a Quarto notebook, the store named by
the document's `targets-store` metadata: the store of the `tar_make` that is
rendering it, else a `targets-store:` key in its front matter (relative to the
document). Otherwise the `store` preference of Targets (relative to the project
root), else `_targets` in the project root.
"""
default_store_path() = something(
    notebook_store(),
    preferred_store(),
    joinpath(project_root(), "_targets"),
)

"The `store` preference of Targets (e.g. in `LocalPreferences.toml`), relative to the project root, or `nothing`."
function preferred_store()
    path = Preferences.load_preference(@__MODULE__, "store", nothing)
    path === nothing && return nothing
    path isa AbstractString ||
        error("the `store` preference of Targets must be a path, got `$(repr(path))`")
    return normpath(joinpath(project_root(), expanduser(path)))
end

"""
    open_store(root = default_store_path())

Create the store layout if needed, or validate an existing store's format version.
"""
function open_store(root::AbstractString = default_store_path())
    store = Store(abspath(String(root)))
    root = store.root
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

read_store_info(s::Store) = TOML.parsefile(joinpath(s.root, "store.toml"))

write_store_info(s::Store, info::AbstractDict) = atomic_open(
    io -> TOML.print(io, info),
    joinpath(s.root, "store.toml"),
)

"""
    record_groups!(s, groups)

Save the pipeline's [`tar_map`](@ref) groups in `store.toml`, so helpers that
see only the store (`tar_invalidate`, `tar_delete`) can expand group names.
"""
function record_groups!(s::Store, groups::AbstractDict{Symbol, Vector{Symbol}})
    info = read_store_info(s)
    stored = Dict{String, Any}(string(k) => string.(v) for (k, v) in groups)
    get(info, "groups", Dict{String, Any}()) == stored && return nothing
    info["groups"] = stored
    write_store_info(s, info)
    return nothing
end

"The groups recorded by the last `tar_make` (none if the store does not exist yet)."
function stored_groups(s::Store)
    isfile(joinpath(s.root, "store.toml")) || return Dict{Symbol, Vector{Symbol}}()
    return Dict{Symbol, Vector{Symbol}}(
        Symbol(k) => Symbol.(v)
        for (k, v) in get(read_store_info(s), "groups", Dict())
    )
end

"""
The file for `key` (plus `suffix`) under the store's `dir`. A branch key such as
`fits/1a2b3c4d` names a file in a subdirectory; its parts are joined so that the
path uses one separator throughout (on Windows, a path with a `/` differs from
the same path that `joinpath` and `readdir` spell with `\\`).
"""
key_path(s::Store, dir::AbstractString, key, suffix = "") = joinpath(
    s.root,
    dir,
    split(string(key, suffix), '/')...,
)

"Where the object of `key` is stored in `format`."
object_path(s::Store, key, format::StorageFormat = DEFAULT_FORMAT) = key_path(
    s,
    "objects",
    key,
    "." * extension(format),
)

"Object files stored for `key`, in any format (normally at most one)."
function object_files(s::Store, key)
    base = key_path(s, "objects", key)
    dir = dirname(base)
    isdir(dir) || return String[]
    prefix = basename(base) * "."
    return [
        joinpath(dir, f)
        for f in readdir(dir)
        if startswith(f, prefix) && !occursin(".tmp-", f) && isfile(joinpath(dir, f))
    ]
end

"The object file of `key`, or `nothing`."
find_object(s::Store, key) = (
    files = object_files(s, key);
    isempty(files) ? nothing : first(files)
)
meta_path(s::Store, key) = key_path(s, "meta", key, ".toml")
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
    write_object(s, key, value; format = JLD2Format())

Write `value` as the object for `key` in `format`. Atomic. Objects of `key`
in other formats are removed afterwards.
"""
function write_object(s::Store, key, value; format::StorageFormat = DEFAULT_FORMAT)
    path = object_path(s, key, format)
    atomic_write(tmp -> write_value(format, tmp, value), path)
    foreach(f -> f == path || rm(f; force = true), object_files(s, key))
    return path
end

has_object(s::Store, key) = find_object(s, key) !== nothing

"""
    read_object(s, key)

The stored object of `key`, read in the format recorded in its metadata (or,
without metadata, the format its file extension names).
"""
function read_object(s::Store, key)
    path = find_object(s, key)
    path === nothing &&
        error("no stored object for target `$key` at $(object_path(s, key))")
    format = object_format(s, key, path)
    try
        return read_value(format, path)
    catch e
        e isa InterruptException && rethrow()
        error(
            "could not load the stored object for `$key`: $(sprint(showerror, e))\n" *
                load_hint(format),
        )
    end
end

function object_format(s::Store, key, path::AbstractString)
    record = read_meta(s, key)
    (record === nothing || record.format in ("file", "url")) ||
        return recorded_format(record.format)
    ext = last(split(basename(path), '.'))
    for name in available_formats()
        format = storage_format(Val(name))
        extension(format) == ext && return format
    end
    error("no storage format is available for the object $path")
end

delete_object(s::Store, key) = foreach(f -> rm(f; force = true), object_files(s, key))

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
    # A hash of the storage format and its options (see formats.jl).
    format_hash::String = ""
    # The seed the target ran with (see seeds.jl), empty if it was not seeded.
    seed::String = ""
    # File targets keep no object: the paths they returned, whether it was a single
    # path, and per-path stat signatures and content hashes (see files.jl).
    files::Vector{String} = String[]
    file_scalar::Bool = true
    file_signatures::Vector{String} = String[]
    file_hashes::Vector{String} = String[]
    # A branching target lists its branches (ids and value hashes, in pattern order);
    # a target that is some target's pattern lists the identity hashes of its elements.
    branches::Vector{String} = String[]
    branch_hashes::Vector{String} = String[]
    element_hashes::Vector{String} = String[]
    elements_recorded::Bool = false
    # Ids of failed branches left out of an `error = :trim` target's value.
    trimmed::Vector{String} = String[]
    # The user's stack frames of the last failure, innermost first.
    traceback::Vector{String} = String[]
    # Warnings logged while the target last ran.
    warnings::Vector{String} = String[]
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
    s = as_store(store)
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
