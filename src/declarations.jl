## Declarations
##
## `tar_pipeline` assembles its arguments into targets. Each argument is a
## declaration: a target built by `target()` (or a helper built on it, such as
## `tar_map`), used as is, or a fragment of declarations built by `@targets`.

abstract type Declaration end

"A target built by [`target`](@ref) or a helper built on it, used as is."
struct PlainDeclaration <: Declaration
    target::Target
end

"""
    Fragment

Declarations built by [`@targets`](@ref), assembled into targets by
[`tar_pipeline`](@ref) or spliced into another `@targets` block.
"""
struct Fragment
    declarations::Vector{Declaration}
end

"The declarations in `x`: a target, a fragment or a (nested) collection of them."
declarations(d::Declaration) = Declaration[d]
declarations(t::Target) = Declaration[PlainDeclaration(t)]
declarations(f::Fragment) = f.declarations
declarations(xs::Union{AbstractVector, Tuple}) = reduce(
    vcat,
    (declarations(x) for x in xs);
    init = Declaration[],
)
declarations(xs::NamedTuple) = declarations(Tuple(xs))
declarations(x) = throw(ArgumentError(
    "tar_pipeline() accepts targets, @targets fragments or collections of them, got `$(typeof(x))`",
))

"The targets that `ds` declare, in declaration order."
assemble(ds::Vector{Declaration}) = Target[assemble(d) for d in ds]
assemble(d::PlainDeclaration) = d.target
