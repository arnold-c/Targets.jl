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
# A row of a one-column table that holds `missing` is written as an empty line,
# which CSV.jl would otherwise skip.
Targets.read_value(::CSVFormat, path::AbstractString) = CSV.File(
    path;
    ignoreemptyrows = false,
)

end
