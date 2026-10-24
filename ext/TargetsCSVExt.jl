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

# Reads detect the delimiter: the recorded format name does not carry the options.
Targets.read_value(::CSVFormat, path::AbstractString) = CSV.File(path)

end
