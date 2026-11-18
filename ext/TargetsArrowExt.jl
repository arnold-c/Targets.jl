module TargetsArrowExt

# Loaded once Arrow is: makes `format = :arrow` (and `ArrowFormat(...)`) available.

using Arrow: Arrow
using Targets: Targets, ArrowFormat

Targets.storage_format(::Val{:arrow}) = ArrowFormat()

function Targets.write_value(f::ArrowFormat, path::AbstractString, value)
    f.compress === nothing && return Arrow.write(path, value)
    return Arrow.write(path, value; compress = f.compress)
end

# Read into memory rather than memory-mapping: Windows cannot remove or replace
# a mapped file, so a read object would block its own rebuild.
Targets.read_value(::ArrowFormat, path::AbstractString) = Arrow.Table(read(path))

end
