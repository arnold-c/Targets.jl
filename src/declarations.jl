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
once the pipeline is assembled: `nothing` for the value from `scope`, the
position of a dependency, or a `GroupInput` for a `@map` template.
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

"""
The value of a reference to a `@map` template: a `NamedTuple` with one entry
per branch, keyed by its suffix. `parts` are dependency positions, or groups
for nested maps.
"""
struct GroupInput
    keys::Vector{Symbol}
    parts::Vector{Any}
end

input_value(i::Int, values, scope, name) = values[i]
input_value(g::GroupInput, values, scope, name) = NamedTuple{Tuple(g.keys)}(Tuple(
    input_value(p, values, scope, name)
    for p in g.parts
))
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

"""
Targets declared once for each element of a collection by [`@map`](@ref): one
branch of declarations per element, with the suffix its names get (in front
of them when `prefix`).
"""
struct MapDeclaration <: Declaration
    branches::Vector{Pair{String, Vector{Declaration}}}
    prefix::Bool
    line::LineNumberNode
end

"""
    map_declaration(template, values; names = nothing, prefix = false, line)

The [`MapDeclaration`](@ref Targets.MapDeclaration) that `@map(values) do v ... end`
builds: `template(v)` declares a branch for each element `v`, suffixed as in
[`tar_map`](@ref).
"""
function map_declaration(
    template,
    values;
    names = nothing,
    prefix::Bool = false,
    line::LineNumberNode = LineNumberNode(0, :none),
)
    elements = map_elements(values)
    suffixes = map_suffixes(values, elements, names)
    for s in suffixes
        example = prefix ? Symbol(s, :_name) : Symbol(:name_, s)
        Base.isidentifier(example) ||
            throw(ArgumentError(
                "$(location(line)): @map suffix `$s` gives names like `$example`, which are " *
                    "not valid target names; pass `names = ...`",
            ))
    end
    return MapDeclaration(
        [s => declarations(template(v)) for (v, s) in zip(elements, suffixes)],
        prefix,
        line,
    )
end

## Assembly

"""
A block of declarations and where it sits: `path` holds the `(suffix, prefix)`
of each enclosing `@map` branch, outermost first (`prefix` is true when the
suffix goes in front of the names). `branches` holds the levels of each `@map`
in the block, in order, and `found` memoizes [`local_target`](@ref Targets.local_target).
"""
struct Level
    declarations::Vector{Declaration}
    path::Vector{Tuple{String, Bool}}
    parent::Union{Nothing, Level}
    branches::Vector{Vector{Level}}
    found::Dict{Symbol, Any}
end

function Level(ds::Vector{Declaration}, path, parent)
    level = Level(ds, path, parent, Vector{Level}[], Dict{Symbol, Any}())
    for m in ds
        m isa MapDeclaration || continue
        push!(
            level.branches,
            [Level(b, [path; (suffix, m.prefix)], level) for (suffix, b) in m.branches],
        )
    end
    return level
end

"Every target name in the pipeline, for references that use a full name."
struct Assembly
    names::Set{Symbol}
end

"A reference to a `@map` template: the targets of each branch, keyed by suffix."
struct Group
    keys::Vector{Symbol}
    parts::Vector{Any}
end

"The names a declaration's targets have before the suffixes of enclosing maps."
template_names(d::PlainDeclaration) = [d.target.name]
template_names(d::TargetDeclaration) = [d.name]
template_names(::MapDeclaration) = Symbol[]

"The name a target declared as `name` gets at a level with `path`."
final_name(name::Symbol, path) = foldr(
    ((suffix, prefix), n) -> prefix ? Symbol(suffix, :_, n) : Symbol(n, :_, suffix),
    path;
    init = name,
)

function all_names!(names, level::Level)
    for d in level.declarations, n in template_names(d)
        push!(names, final_name(n, level.path))
    end
    foreach(bs -> foreach(b -> all_names!(names, b), bs), level.branches)
    return names
end

"The targets that `ds` declare, ordered as [`tar_map`](@ref) orders branches."
function assemble(ds::Vector{Declaration})
    root = Level(ds, Tuple{String, Bool}[], nothing)
    asm = Assembly(all_names!(Set{Symbol}(), root))
    return Target[t for (_, t) in level_targets(root, asm)]
end

"""
The targets declared at `level` and in its `@map`s, each with the name it has
within the level (before the suffixes of enclosing maps).
"""
function level_targets(level::Level, asm::Assembly)
    out = Pair{Symbol, Target}[]
    maps = Iterators.Stateful(level.branches)
    for d in level.declarations
        if d isa MapDeclaration
            append!(out, map_targets(d, popfirst!(maps), asm))
        else
            append!(out, declared_targets(d, level, asm))
        end
    end
    return out
end

"The targets `d` declares at `level`, each with its template name."
declared_targets(
    d::Union{PlainDeclaration, TargetDeclaration},
    level::Level,
    asm::Assembly,
) = [only(template_names(d)) => assemble(d, level, asm)]

# As `tar_map`: grouped by template (in order of first appearance), each
# target's `group` is its name before this map's suffix.
function map_targets(m::MapDeclaration, branches::Vector{Level}, asm::Assembly)
    pairs = Pair{Symbol, Pair{Symbol, Target}}[]
    for ((suffix, _), b) in zip(m.branches, branches), (n, t) in level_targets(b, asm)
        renamed = final_name(n, [(suffix, m.prefix)])
        push!(pairs, n => (renamed => with_fields(t; group = n)))
    end
    templates = unique(first.(pairs))
    return [last(p) for n in templates for p in pairs if first(p) == n]
end

"""
    resolve(level, name, asm)

The target or [`Group`](@ref Targets.Group) `name` refers to at `level`: the
innermost declaration of that name from `level` outwards, else a target with
that full name, else `nothing`.
"""
function resolve(level::Level, name::Symbol, asm::Assembly)
    found = local_target(level, name)
    found === nothing || return found
    level.parent === nothing || return resolve(level.parent, name, asm)
    return name in asm.names ? name : nothing
end

"""
What `name` means at `level` itself: the target declared there, the group of a
template in one of its `@map`s, or `nothing`.
"""
local_target(level::Level, name::Symbol) = get!(
    () -> find_local_target(level, name),
    level.found,
    name,
)

function find_local_target(level::Level, name::Symbol)
    found = Any[
        final_name(name, level.path)
        for d in level.declarations
        if name in template_names(d)
    ]
    for (m, bs) in zip(
            filter(d -> d isa MapDeclaration, level.declarations),
            level.branches,
        )
        g = map_group(m, bs, name)
        g === nothing || push!(found, g)
    end
    length(found) > 1 &&
        throw(PipelineError(
            "`$name` is ambiguous here: it is declared more than once in one block " *
                "(as a target or in a @map); rename one of them",
        ))
    return isempty(found) ? nothing : only(found)
end

function map_group(m::MapDeclaration, branches::Vector{Level}, name::Symbol)
    keys, parts = Symbol[], Any[]
    for ((suffix, _), b) in zip(m.branches, branches)
        found = local_target(b, name)
        found === nothing && continue
        push!(keys, Symbol(suffix))
        push!(parts, found)
    end
    return isempty(keys) ? nothing : Group(keys, parts)
end

# A plain target's dependencies (and pattern) name the innermost targets of
# those names, as with `tar_map`; other names are left alone.
function assemble(d::PlainDeclaration, level::Level, asm::Assembly)
    t = d.target
    isempty(level.path) && return t
    function rename(n)
        found = resolve(level, n, asm)
        return found isa Symbol ? found : n
    end
    return with_fields(
        t;
        name = final_name(t.name, level.path),
        deps = rename.(t.deps),
        pattern = map_names(rename, t.pattern),
    )
end

function assemble(d::TargetDeclaration, level::Level, asm::Assembly)
    command, deps = resolve_command(d, level, asm)
    pattern = map_names(n -> pattern_target(d, level, n, asm), d.pattern)
    return target(
        final_name(d.name, level.path),
        command;
        deps,
        pattern,
        source = d.source,
        d.options...,
    )
end

"""
The command of declaration `d` with its references resolved at `level`, and
the dependencies they name.
"""
function resolve_command(d, level::Level, asm::Assembly)
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
    return MacroCommand(c, inputs), deps
end

function add_dependency!(deps::Vector{Symbol}, name::Symbol)
    i = findfirst(==(name), deps)
    i === nothing || return i
    push!(deps, name)
    return length(deps)
end
add_dependency!(deps::Vector{Symbol}, g::Group) = GroupInput(
    g.keys,
    Any[add_dependency!(deps, p) for p in g.parts]
)

function pattern_target(d, level::Level, name::Symbol, asm::Assembly)
    found = resolve(level, name, asm)
    found isa Symbol && return found
    throw(PipelineError(
        "$(location(d.line)): target `$(d.name)` branches over `$name`, which is not a target" *
            hint_suffix(name, asm.names),
    ))
end

location(line::LineNumberNode) = "$(something(line.file, :none)):$(line.line)"

undefined_name(d, name::Symbol, asm::Assembly) = PipelineError(
    "$(location(d.line)): target `$(d.name)` uses `$name`, which is neither a target " *
        "nor defined where the target is declared" *
        hint_suffix(name, asm.names),
)

called_target(d, name::Symbol) = PipelineError(
    "$(location(d.line)): target `$(d.name)` calls `$name`, which is both a target and a " *
        "function; rename the target, or qualify the function (`SomeModule.$name`)",
)
