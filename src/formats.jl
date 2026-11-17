## Storage formats
##
## How a target's value is written to and read from its object file. A format is
## a `StorageFormat` value; a target names one with a `Symbol` (`format = :jld2`)
## that `storage_format` resolves. File targets (`format = :file`) are a separate
## kind of target: they store paths, not objects, and have no `StorageFormat`.

"""
    StorageFormat

Supertype of storage formats. A format `F` defines

- `Targets.format_name(::F)::Symbol`, the name recorded in metadata,
- `Targets.extension(::F)::String`, the object file extension (without the dot),
- `Targets.write_value(::F, path, value)` and
- `Targets.read_value(::F, path)`,

and, to be selectable by name, `Targets.storage_format(::Val{name}) = F()`.
"""
abstract type StorageFormat end

"The format named `name`, e.g. `storage_format(Val(:jld2))`."
function storage_format end

"""
    JLD2Format()

The default format: any Julia value, through JLD2. User types must be defined in
a named module (not `_targets.jl`) to load again.
"""
struct JLD2Format <: StorageFormat end
storage_format(::Val{:jld2}) = JLD2Format()
format_name(::JLD2Format) = :jld2
extension(::JLD2Format) = "jld2"
write_value(::JLD2Format, path::AbstractString, value) = JLD2.jldsave(path; value)
read_value(::JLD2Format, path::AbstractString) = JLD2.load(path, "value")

"""
    JLSFormat()

Julia's Serialization: the fastest for arbitrary values, but a file can only be
read by the Julia version that wrote it, so these targets rebuild after a Julia
upgrade.
"""
struct JLSFormat <: StorageFormat end
storage_format(::Val{:jls}) = JLSFormat()
format_name(::JLSFormat) = :jls
extension(::JLSFormat) = "jls"
write_value(::JLSFormat, path::AbstractString, value) = Serialization.serialize(path, value)
read_value(::JLSFormat, path::AbstractString) = Serialization.deserialize(path)

"Whether objects in `format` can only be read by the Julia version that wrote them."
version_bound(::StorageFormat) = false
version_bound(::JLSFormat) = true

"What to suggest when an object in `format` fails to load."
load_hint(
    ::StorageFormat,
) = "If its type is defined in `_targets.jl`, move the type into a named module " *
    "(for example your project package) and load it with `using`."
load_hint(
    ::JLSFormat,
) = "Serialization files can only be read by the Julia version that wrote them; " *
    "rebuild the target with tar_make()."

const DEFAULT_FORMAT = JLD2Format()

## Formats implemented in package extensions. The types live here so that users
## can write `format = ArrowFormat(compress = :zstd)`; reading and writing are
## defined once the package is loaded.

"""
    ArrowFormat(; compress = nothing)

Arrow IPC files, for any Tables.jl table; `compress` may be `:lz4` or `:zstd`.
Needs `using Arrow`. Reading returns a memory-mapped `Arrow.Table`; use
`DataFrame(tar_read(:x))` or `copy` for a mutable table.
"""
Base.@kwdef struct ArrowFormat <: StorageFormat
    compress::Union{Nothing, Symbol} = nothing
end
format_name(::ArrowFormat) = :arrow
extension(::ArrowFormat) = "arrow"

"""
    ParquetFormat()

Parquet files, for any Tables.jl table. Needs `using Parquet2`. Reading returns
a `Parquet2.Dataset`; use `DataFrame(tar_read(:x))` for a table.
"""
struct ParquetFormat <: StorageFormat end
format_name(::ParquetFormat) = :parquet
extension(::ParquetFormat) = "parquet"

"""
    CSVFormat(; delim = ',')

CSV text, for any Tables.jl table; mainly for interchange (Arrow is faster).
Needs `using CSV`. Reading returns a `CSV.File` (the delimiter is detected).
"""
Base.@kwdef struct CSVFormat <: StorageFormat
    delim::Char = ','
end
format_name(::CSVFormat) = :csv
extension(::CSVFormat) = "csv"

# Packages that provide the formats Targets knows about but does not load itself.
const FORMAT_PACKAGES = Dict(:arrow => "Arrow", :parquet => "Parquet2", :csv => "CSV")

has_storage_format(name::Symbol) = hasmethod(storage_format, Tuple{Val{name}})

"Names of the storage formats currently available."
available_formats() = sort!([
    m.sig.parameters[2].parameters[1]
    for m in methods(storage_format)
    if m.sig.parameters[2] isa DataType && m.sig.parameters[2] <: Val
])

"""
    resolve_format(format)

The `StorageFormat` for a target's `format` option (a name or a format value),
with an error naming the formats available, or the package to load.
"""
function resolve_format(format::StorageFormat)
    hasmethod(write_value, Tuple{typeof(format), String, Any}) && return format
    name = format_name(format)
    throw(ArgumentError(
        "storage format `:$name` needs `using $(get(FORMAT_PACKAGES, name, "the package that defines it"))`",
    ))
end
function resolve_format(name::Symbol)
    has_storage_format(name) && return storage_format(Val(name))
    hint = haskey(FORMAT_PACKAGES, name) ?
        "`format = :$name` needs `using $(FORMAT_PACKAGES[name])`" :
        "available formats: :file, " * join((":$f" for f in available_formats()), ", ")
    throw(ArgumentError("unknown storage format `:$name`; $hint"))
end

"How target `t`'s format is recorded in its metadata."
record_format(t) = is_external(t) ?
    string(t.format) :
    string(format_name(resolve_format(t.format)))

"Record fields describing target `t`'s format: its name, and a hash of its options."
format_fields(t) = (
    format = record_format(t),
    format_hash = is_external(t) ? "" : canonical_hash(resolve_format(t.format)),
)

"""
    same_format(record, t)

Whether `record` was written in target `t`'s current format (including options).
Records from before format options were tracked compare by name only.
"""
function same_format(record, t)
    current = format_fields(t)
    isempty(record.format_hash) && return record.format == current.format
    return record.format_hash == current.format_hash
end

"The format recorded under `name` in a target's metadata."
recorded_format(name::AbstractString) = resolve_format(Symbol(name))

@testitem "formats resolve by name, with helpful errors" begin
    using Targets: resolve_format, JLD2Format, available_formats, ParquetFormat
    @test resolve_format(:jld2) === JLD2Format()
    @test resolve_format(JLD2Format()) === JLD2Format()
    @test :jld2 in available_formats()
    @test_throws "available formats" resolve_format(:nope)
    if Base.get_extension(Targets, :TargetsParquet2Ext) === nothing
        @test_throws "needs `using Parquet2`" resolve_format(:parquet)
        @test_throws "needs `using Parquet2`" resolve_format(ParquetFormat())
    end
end

@testitem "table formats round-trip and write identical bytes for identical tables" setup = [
    JETChecks,
] begin
    using Arrow, CSV, Parquet2, DataFrames
    using Targets:
        open_store,
        write_object,
        read_object,
        hash_file,
        ArrowFormat,
        ParquetFormat,
        CSVFormat
    df = DataFrame(a = [1, 2, 3], b = ["x", "y", "z"])
    formats = (
        ArrowFormat(),
        ArrowFormat(compress = :zstd),
        ParquetFormat(),
        CSVFormat(),
        CSVFormat(delim = ';'),
    )
    mktempdir() do dir
        s = open_store(joinpath(dir, "_targets"))
        for (i, format) in enumerate(formats)
            first_path = write_object(s, "first$i", df; format)
            sleep(1.1) # a writer that embeds a timestamp would now differ
            second_path = write_object(s, "second$i", df; format)
            @test hash_file(first_path) == hash_file(second_path)
            @test DataFrame(read_object(s, "first$i")) == df
            @test_call write_object(s, "first$i", df; format)
            @test_call read_object(s, "first$i")
        end
    end
end

@testitem "a target stored as a table format builds, reads and stays up to date" begin
    using Arrow, CSV, Parquet2, DataFrames
    for format in (:arrow, :parquet, :csv)
        p = tar_pipeline(
            target(:tbl, () -> DataFrame(a = 1:3, b = [0.5, 1.5, 2.5]); format),
            target(:total, tbl -> sum(DataFrame(tbl).a)),
        )
        mktempdir() do dir
            store = joinpath(dir, "_targets")
            build() = tar_make(p; store, root = dir, io = devnull)
            @test build().built == [:tbl, :total]
            @test DataFrame(tar_read(:tbl; store)) ==
                DataFrame(a = 1:3, b = [0.5, 1.5, 2.5])
            @test tar_read(:total; store) == 6
            @test isempty(build().built)
        end
    end
end

@testitem "the jls format round-trips, and is rebuilt on another Julia version" begin
    using Targets: open_store, read_meta, write_meta, update
    p = tar_pipeline(
        target(:x, () -> Dict(:a => [1, 2])),
        target(:y, x -> length(x); format = :jls),
    )
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        build() = tar_make(p; store, root = dir, io = devnull)
        @test build().built == [:x, :y]
        @test isfile(joinpath(store, "objects", "y.jls"))
        @test tar_read(:y; store) == 1
        s = open_store(store)
        write_meta(s, :y, update(read_meta(s, :y); julia_version = "1.0.0"))
        @test tar_outdated(p; store, root = dir) == [(name = :y, reason = :missing)]
        @test build().built == [:y]
    end
end

@testitem "changing a target's format rebuilds it and reads the new format" begin
    using Targets: StorageFormat, JLD2Format
    struct Tagged <: StorageFormat
        tag::Int
    end
    Targets.format_name(::Tagged) = :tagged
    Targets.extension(::Tagged) = "tagged"
    Targets.write_value(::Tagged, path, value) = Targets.write_value(
        JLD2Format(),
        path,
        value,
    )
    Targets.read_value(::Tagged, path) = Targets.read_value(JLD2Format(), path)
    Targets.storage_format(::Val{:tagged}) = Tagged(0)
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        p(format) = tar_pipeline(target(:x, () -> [1, 2]), target(:y, x -> sum(x); format))
        build(format) = tar_make(p(format); store, root = dir, io = devnull)
        @test build(:jld2).built == [:x, :y]
        @test tar_outdated(p(:jls); store, root = dir) ==
            [(name = :y, reason = :format_changed)]
        @test build(:jls).built == [:y]
        @test tar_read(:y; store) == 3
        @test readdir(joinpath(store, "objects")) == ["x.jld2", "y.jls"]
        @test build(Tagged(1)).built == [:y]
        @test build(Tagged(1)).built == []
        @test build(Tagged(2)).built == [:y] # options count
        @test tar_read(:y; store) == 3
    end
end
