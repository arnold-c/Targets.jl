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

const DEFAULT_FORMAT = JLD2Format()

# Packages that provide the formats Targets knows about but does not load itself.
const FORMAT_PACKAGES = Dict{Symbol, String}()

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
resolve_format(format::StorageFormat) = format
function resolve_format(name::Symbol)
    has_storage_format(name) && return storage_format(Val(name))
    hint = haskey(FORMAT_PACKAGES, name) ?
        "`format = :$name` needs `using $(FORMAT_PACKAGES[name])`" :
        "available formats: :file, " * join((":$f" for f in available_formats()), ", ")
    throw(ArgumentError("unknown storage format `:$name`; $hint"))
end

"How target `t`'s format is recorded in its metadata."
record_format(t) = t.format === :file ?
    "file" :
    string(format_name(resolve_format(t.format)))

"The format recorded under `name` in a target's metadata."
recorded_format(name::AbstractString) = resolve_format(Symbol(name))

@testitem "formats resolve by name, with helpful errors" begin
    using Targets: resolve_format, JLD2Format, available_formats
    @test resolve_format(:jld2) === JLD2Format()
    @test resolve_format(JLD2Format()) === JLD2Format()
    @test :jld2 in available_formats()
    @test_throws "available formats" resolve_format(:nope)
end
