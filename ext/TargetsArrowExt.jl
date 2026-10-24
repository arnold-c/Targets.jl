module TargetsArrowExt

# Loaded once Arrow is: makes `format = :arrow` (and `ArrowFormat(...)`) available.

using Arrow: Arrow
using Targets: Targets, ArrowFormat

Targets.storage_format(::Val{:arrow}) = ArrowFormat()

function Targets.write_value(f::ArrowFormat, path::AbstractString, value)
    f.compress === nothing && return Arrow.write(path, value)
    return Arrow.write(path, value; compress = f.compress)
end

Targets.read_value(::ArrowFormat, path::AbstractString) = Arrow.Table(path)

end
