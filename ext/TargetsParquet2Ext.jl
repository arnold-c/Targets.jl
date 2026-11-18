module TargetsParquet2Ext

# Loaded once Parquet2 is: makes `format = :parquet` available.

using Parquet2: Parquet2
using Targets: Targets, ParquetFormat

Targets.storage_format(::Val{:parquet}) = ParquetFormat()

Targets.write_value(::ParquetFormat, path::AbstractString, value) = Parquet2.writefile(
    path,
    value,
)

# Read into memory rather than memory-mapping: Windows cannot remove or replace
# a mapped file, so a read object would block its own rebuild.
Targets.read_value(::ParquetFormat, path::AbstractString) = Parquet2.Dataset(
    path;
    use_mmap = false,
)

end
