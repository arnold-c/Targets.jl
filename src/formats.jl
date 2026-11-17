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

and, to be selectable by name, `Targets.storage_format(::Val{name}) = F()`. A
format with options that reading needs also defines

- `Targets.format_options(::F)::Dict{String, Any}`, the options that differ from
  the defaults, as TOML values, recorded in metadata, and
- `Targets.with_options(::F, options)`, the format with recorded `options`.
"""
abstract type StorageFormat end

"""
    format_options(format)::Dict{String, Any}

The options of `format` that differ from those of the format its name gives,
as TOML values. They are recorded in metadata, and `with_options` restores them
to read the object. Formats without options record none.
"""
format_options(::StorageFormat) = Dict{String, Any}()

"""
    with_options(format, options)

`format`, as its name gives it, with the `options` that `format_options`
recorded.
"""
with_options(format::StorageFormat, options) = format

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
format_options(f::ArrowFormat) = f == ArrowFormat() ?
    Dict{String, Any}() :
    Dict{String, Any}("compress" => string(f.compress))
with_options(::ArrowFormat, options) = haskey(options, "compress") ?
    ArrowFormat(; compress = Symbol(options["compress"])) :
    ArrowFormat()

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
Needs `using CSV`. Reading returns a `CSV.File`, read with the delimiter the
object was written with.
"""
Base.@kwdef struct CSVFormat <: StorageFormat
    delim::Char = ','
end
format_name(::CSVFormat) = :csv
extension(::CSVFormat) = "csv"
format_options(f::CSVFormat) = f == CSVFormat() ?
    Dict{String, Any}() :
    Dict{String, Any}("delim" => string(f.delim))
with_options(::CSVFormat, options) = haskey(options, "delim") ?
    CSVFormat(; delim = only(options["delim"])) :
    CSVFormat()

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

"Record fields describing format `f`: its name, a hash of it, and its options."
format_fields(f::StorageFormat) = (
    format = string(format_name(f)),
    format_hash = canonical_hash(f),
    format_options = format_options(f),
)
"Record fields describing target `t`'s format."
format_fields(t) = is_external(t) ?
    (format = string(t.format), format_hash = "", format_options = Dict{String, Any}()) :
    format_fields(resolve_format(t.format))

"""
    same_format(record, t)

Whether `record` was written in target `t`'s current format (including options).
Records from before format options were tracked compare by name only; those from
before they were recorded, by hash, and lack the options of a format that has
any, so the target is rebuilt to record them.
"""
function same_format(record, t)
    current = format_fields(t)
    isempty(record.format_hash) && return record.format == current.format
    return record.format_hash == current.format_hash &&
        record.format_options == current.format_options
end

"The format `record` was written in, with its recorded options."
recorded_format(record) = with_options(
    resolve_format(Symbol(record.format)),
    record.format_options,
)

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

@testitem "CSV keeps the missing values of a one-column table" begin
    using CSV, DataFrames
    using Targets: open_store, write_object, read_object, CSVFormat
    s = open_store(joinpath(mktempdir(), "_targets"))
    for column in ([1, missing, 1], [-3, -3, missing], [missing])
        df = DataFrame(c1 = column) # each missing is written as an empty line
        write_object(s, "t", df; format = CSVFormat())
        @test isequal(DataFrame(read_object(s, "t")), df)
    end
end

@testitem "table formats round-trip and write identical bytes for identical tables" setup = [
    JETChecks,
    ObjectFixtures,
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
            first_path = store_object(s, "first$i", df, format)
            sleep(1.1) # a writer that embeds a timestamp would now differ
            second_path = store_object(s, "second$i", df, format)
            @test hash_file(first_path) == hash_file(second_path)
            @test DataFrame(read_object(s, "first$i")) == df
            @test_call write_object(s, "first$i", df; format)
            @test_call read_object(s, "first$i")
        end
    end
end

@testitem "property: jld2 and jls read back every plain value" setup = [Properties] begin
    using Targets: open_store, write_object, read_object, canonical_hash, storage_format
    s = open_store(joinpath(mktempdir(), "_targets"))
    # an equal canonical hash means the same types and values throughout
    report = @check config = check_config(;
        max_examples = 300,
    ) rng = property_rng() function values_round_trip(
        x = plain_values(),
        format = Data.SampledFrom([:jld2, :jls]),
    )
        write_object(s, "x", x; format = storage_format(Val(format)))
        return canonical_hash(read_object(s, "x")) == canonical_hash(x)
    end
    @test check_result(report).holds
end

@testitem "property: table formats read back every table" setup = [
    Properties,
    ObjectFixtures,
] begin
    using Arrow, CSV, Parquet2, DataFrames
    using Targets: open_store, read_object, ArrowFormat, ParquetFormat, CSVFormat

    # CSV cannot tell a string such as "1" or "true" from a number or a Bool, so
    # strings for it start with a letter that no other value does.
    strings(csv) = csv ?
        map(s -> "x" * s, Data.Text(Data.SampledFrom(collect("ab ,;\"")); max_len = 3)) :
        Data.Text(Data.Characters(; valid = true); max_len = 3)
    function columns(n, csv)
        of(gen) = Data.Vectors(gen; min_size = n, max_size = n)
        return Data.OneOf(
            of(Data.Integers(-3, 3)),
            of(Data.SampledFrom([0.0, -0.0, 1.5, Inf, NaN])),
            of(Data.Booleans()),
            of(strings(csv)),
            of(Data.OneOf(Data.Integers(-3, 3), Data.Just(missing))),
        )
    end
    tables(csv) = Data.bind(Data.Integers(0, 4)) do n
        map(Data.Vectors(columns(n, csv); min_size = 1, max_size = 3)) do cols
            DataFrame([Symbol(:c, i) => c for (i, c) in enumerate(cols)])
        end
    end

    s = open_store(joinpath(mktempdir(), "_targets"))
    function round_trips(df, format)
        store_object(s, "t", df, format)
        return isequal(DataFrame(read_object(s, "t")), df)
    end
    binary = [ArrowFormat(), ArrowFormat(compress = :zstd), ParquetFormat()]
    report = @check config = check_config(;
        max_examples = 150,
    ) rng = property_rng() function binary_tables_round_trip(
        df = tables(false),
        format = Data.SampledFrom(binary),
    )
        round_trips(df, format)
    end
    @test check_result(report).holds
    report = @check config = check_config(;
        max_examples = 150,
    ) rng = property_rng() function csv_tables_round_trip(
        df = tables(true),
        format = Data.SampledFrom([CSVFormat(), CSVFormat(delim = ';')]),
    )
        round_trips(df, format)
    end
    @test check_result(report).holds
end

@testitem "objects are read with the format options they were written with" begin
    using CSV, DataFrames
    using Targets: open_store, read_meta, write_meta, update
    # one column, so the header has no delimiter to detect
    p = tar_pipeline(
        target(:semi, () -> DataFrame(c1 = ["x", "x,"]); format = CSVFormat(delim = ';')),
        target(:plain, () -> DataFrame(c1 = ["x", "x;"]); format = :csv),
    )
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        build() = tar_make(p; store, root = dir, io = devnull)
        @test build().built == [:semi, :plain]
        @test DataFrame(tar_read(:semi; store)).c1 == ["x", "x,"]
        @test DataFrame(tar_read(:plain; store)).c1 == ["x", "x;"]
        s = open_store(store)
        # only options that differ from the format's defaults are recorded
        @test read_meta(s, :semi).format_options == Dict("delim" => ";")
        @test isempty(read_meta(s, :plain).format_options)
        # a record from before options were recorded is rebuilt to record them
        for name in (:semi, :plain)
            write_meta(
                s,
                name,
                update(read_meta(s, name); format_options = Dict{String, Any}()),
            )
        end
        @test tar_outdated(p; store, root = dir) ==
            [(name = :semi, reason = :format_changed)]
        @test build().built == [:semi]
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
