module TargetsCSVExt

# Loaded once CSV is: makes `format = :csv` (and `CSVFormat(...)`) available.

using CSV: CSV
using Targets: Targets, CSVFormat

Targets.storage_format(::Val{:csv}) = CSVFormat()

Targets.write_value(f::CSVFormat, path::AbstractString, value) = CSV.write(
    path,
    value;
    delim = f.delim,
)

# Reads use the recorded delimiter: CSV.jl detects one from the header, which a
# one-column table does not have. A row of a one-column table that holds
# `missing` is written as an empty line, which CSV.jl would otherwise skip.
# Large files are read into memory rather than memory-mapped: Windows cannot
# remove or replace a mapped file, so a read object would block its own rebuild.
Targets.read_value(f::CSVFormat, path::AbstractString) = CSV.File(
    path;
    delim = f.delim,
    ignoreemptyrows = false,
    buffer_in_memory = true,
)

end
