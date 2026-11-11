## Declarations
##
## `tar_pipeline` assembles its arguments into targets. Each argument is a
## declaration: a target built by `target()` (or a helper built on it, such as
## `tar_map`), used as is, or a fragment of declarations built by `@targets`.
## A `@target` declaration knows which names its expression uses, but not yet
## what they mean: assembly decides, for each, whether it names a target (a
## dependency) or a value defined where the block was written.

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

## The function of a `@target`

"What a name means where a `@targets` block refers to it, when nothing is defined there."
struct Undefined end
const UNDEFINED = Undefined()

"""
    MacroCommand

The function of a target declared with [`@target`](@ref). `body` takes the
values of `refs`, the names its expression uses that the block does not bind
itself, and `scope` returns what each of those names means where the block was
written (`UNDEFINED` when nothing). `inputs` says where each value comes from,
once the pipeline is assembled: `nothing` for the value from `scope`, or the
position of a dependency.
"""
struct MacroCommand{B, S}
    body::B
    scope::S
    refs::Vector{Symbol}
    mod::Module
    inputs::Vector{Any}
end
MacroCommand(body, scope, refs::Vector{Symbol}, mod::Module) = MacroCommand(
    body,
    scope,
    refs,
    mod,
    Any[],
)
MacroCommand(c::MacroCommand, inputs::Vector{Any}) = MacroCommand(
    c.body,
    c.scope,
    c.refs,
    c.mod,
    inputs,
)

function (c::MacroCommand)(values...)
    scope = Base.invokelatest(c.scope)
    args = map((name, input) -> input_value(input, values, scope, name), c.refs, c.inputs)
    return Base.invokelatest(c.body, args...)
end

input_value(i::Int, values, scope, name) = values[i]
function input_value(::Nothing, values, scope, name)
    v = getfield(scope, name)
    v isa Undefined && throw(UndefVarError(name))
    return v
end

"The values the names in `c.refs` have where its block was written."
scope_values(c::MacroCommand) = Base.invokelatest(c.scope)

"""
A target declared with [`@target`](@ref). `called` lists the names its
expression calls as functions, `source` is the expression, line numbers
removed, and `options` the other keyword arguments of [`target`](@ref).
"""
struct TargetDeclaration <: Declaration
    name::Symbol
    command::MacroCommand
    called::Vector{Symbol}
    source::Expr
    pattern::Union{Nothing, Symbol, Pattern}
    options::NamedTuple
    line::LineNumberNode
end

## Assembly

"""
A block of declarations and where it sits: `path` holds the `(suffix, prefix)`
of each enclosing `@map` branch, outermost first (`prefix` is true when the
suffix goes in front of the names).
"""
struct Level
    declarations::Vector{Declaration}
    path::Vector{Tuple{String, Bool}}
    parent::Union{Nothing, Level}
end

"Every target name in the pipeline, for references that use a full name."
struct Assembly
    names::Set{Symbol}
end

template_name(d::PlainDeclaration) = d.target.name
template_name(d::TargetDeclaration) = d.name

"The name a target declared as `name` gets at a level with `path`."
final_name(name::Symbol, path) = foldr(
    ((suffix, prefix), n) -> prefix ? Symbol(suffix, :_, n) : Symbol(n, :_, suffix),
    path;
    init = name,
)

final_names(level::Level) = Symbol[
    final_name(template_name(d), level.path)
    for d in level.declarations
]

"The targets that `ds` declare, in declaration order."
function assemble(ds::Vector{Declaration})
    root = Level(ds, Tuple{String, Bool}[], nothing)
    asm = Assembly(Set(final_names(root)))
    return Target[assemble(d, root, asm) for d in ds]
end

"""
    resolve(level, name, asm)

The target `name` refers to at `level`: the innermost declaration of that name
from `level` outwards, else a target with that full name, else `nothing`.
"""
function resolve(level::Level, name::Symbol, asm::Assembly)
    found = local_target(level, name)
    found === nothing || return found
    level.parent === nothing || return resolve(level.parent, name, asm)
    return name in asm.names ? name : nothing
end

function local_target(level::Level, name::Symbol)
    for d in level.declarations
        template_name(d) == name && return final_name(name, level.path)
    end
    return nothing
end

# A plain target's dependencies (and pattern) name targets of its own level when
# there are any, as with `tar_map`; other names are left alone.
function assemble(d::PlainDeclaration, level::Level, asm::Assembly)
    t = d.target
    isempty(level.path) && return t
    rename(n) = something(local_target(level, n), n)
    return with_fields(
        t;
        name = final_name(t.name, level.path),
        deps = rename.(t.deps),
        pattern = map_names(rename, t.pattern),
    )
end

function assemble(d::TargetDeclaration, level::Level, asm::Assembly)
    c = d.command
    scope = scope_values(c)
    deps = Symbol[]
    inputs = Any[]
    for name in c.refs
        found = resolve(level, name, asm)
        if found === nothing
            getfield(scope, name) isa Undefined && throw(undefined_name(d, name, asm))
            push!(inputs, nothing)
        else
            (name in d.called && getfield(scope, name) isa Function) &&
                throw(called_target(d, name))
            push!(inputs, add_dependency!(deps, found))
        end
    end
    pattern = map_names(n -> pattern_target(d, level, n, asm), d.pattern)
    return target(
        final_name(d.name, level.path),
        MacroCommand(c, inputs);
        deps,
        pattern,
        source = d.source,
        d.options...,
    )
end

function add_dependency!(deps::Vector{Symbol}, name::Symbol)
    i = findfirst(==(name), deps)
    i === nothing || return i
    push!(deps, name)
    return length(deps)
end

function pattern_target(d::TargetDeclaration, level::Level, name::Symbol, asm::Assembly)
    found = resolve(level, name, asm)
    found isa Symbol && return found
    throw(PipelineError(
        "$(location(d.line)): target `$(d.name)` branches over `$name`, which is not a target" *
            hint_suffix(name, asm.names),
    ))
end

location(line::LineNumberNode) = "$(something(line.file, :none)):$(line.line)"

undefined_name(d::TargetDeclaration, name::Symbol, asm::Assembly) = PipelineError(
    "$(location(d.line)): target `$(d.name)` uses `$name`, which is neither a target " *
        "nor defined where the target is declared" *
        hint_suffix(name, asm.names),
)

called_target(d::TargetDeclaration, name::Symbol) = PipelineError(
    "$(location(d.line)): target `$(d.name)` calls `$name`, which is both a target and a " *
        "function; rename the target, or qualify the function (`SomeModule.$name`)",
)
