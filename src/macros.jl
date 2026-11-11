## Macro sugar
##
## `@targets` turns a block of `@target name = expression options...` lines into
## a `Fragment` of declarations, and `@pipeline` passes one to `tar_pipeline`.
## Each expression's free names are found with ExpressionExplorer (after
## expanding its macros), so names it binds itself (comprehension variables,
## lambda arguments, `let` and `do` bindings) are never dependencies. Names the
## block binds (assignments) are captured as usual; every other free name is
## resolved when the pipeline is assembled: a target, or else whatever the name
## means where the block was written.

"""
    @target name = expression [format = ...] [pattern = ...] [cue = ...] [seed = ...] ...

Declare a target inside [`@targets`](@ref) or [`@pipeline`](@ref). Its
dependencies are the targets `expression` refers to, wherever they are
declared; the options are the keyword arguments of [`target`](@ref). Elsewhere
it is an error.
"""
macro target(args...)
    error(
        "@target can only be used inside @targets or @pipeline; use `target(:name, f)` to " *
            "declare a target on its own",
    )
end

"""
    @quarto name = "path.qmd" [option = value ...]
    @quarto "path.qmd" [option = value ...]

Declare a [`tar_quarto`](@ref) report inside [`@targets`](@ref) or
[`@pipeline`](@ref); the second form names it after the file
(`reports/summary.qmd` is `summary`). Options are the keyword arguments of
`tar_quarto`. Elsewhere, call `tar_quarto`.
"""
macro quarto(args...)
    error(
        "@quarto can only be used inside @targets or @pipeline; use `tar_quarto(name, path)` " *
            "to declare a report on its own",
    )
end

"""
    @map(values; names = nothing, prefix = false) do value
        @target ...
        ...
    end

Inside [`@targets`](@ref) or [`@pipeline`](@ref), declare the block's targets
once for each element of `values`, as [`tar_map`](@ref) does: each name gets
the element's suffix (`fit_ols`), or, with `prefix = true`, starts with it
(`ols_fit`). `names` chooses the suffixes, as in `tar_map`. The block may use
`value`, assign variables and splice in fragments, like any `@targets` block,
and `@map`s nest.

Within a branch, a name refers to that branch's target. Outside the `@map`, a
template's name refers to all of its targets: its value is a `NamedTuple`
keyed by suffix (nested for nested `@map`s), so `collect(chain)` gives the
values in order.
"""
macro map(args...)
    error(
        "@map can only be used inside @targets or @pipeline, as `@map(values) do value ... end`; " *
            "use `tar_map` to map targets on their own",
    )
end

"""
    @rep name = expression batches = ... reps = ... [options...]

Inside [`@targets`](@ref) or [`@pipeline`](@ref), [`tar_rep`](@ref) of
`expression`: it is evaluated `batches * reps` times, as `batches` branches of
`reps` replications, each with its own seed. Declares `name_batch`,
`name_batches` and `name`, the vector of all replications, as `tar_rep` does;
the other options are [`target`](@ref)'s, for the branching target.
"""
macro rep(args...)
    error(
        "@rep can only be used inside @targets or @pipeline; use `tar_rep(name, f; batches, reps)` " *
            "to declare replications on their own",
    )
end

## Parsing a block

"`@target` (`kind` is `:target`) or `@rep` (`:rep`)."
struct TargetLine
    kind::Symbol
    name::Symbol
    body::Any
    options::Vector{Pair{Symbol, Any}}
    line::LineNumberNode
end

struct QuartoLine
    name::Symbol
    path::Any
    options::Vector{Pair{Symbol, Any}}
    line::LineNumberNode
end

"`name = value` (or a destructuring assignment) shared by the targets of a block."
struct AssignLine
    ex::Expr
    line::LineNumberNode
end

"Any other line: its value (targets or a fragment) joins the block."
struct SpliceLine
    ex::Any
    line::LineNumberNode
end

"`@map(values; options...) do arguments ... end`, with its parsed block."
struct MapLine
    values::Any
    options::Vector{Pair{Symbol, Any}}
    arguments::Expr
    body::Any
    line::LineNumberNode
end

"""
A parsed block: its lines, the names it binds (`locals`), and the names it
declares as targets (`targets`).
"""
struct Block
    items::Vector{Any}
    locals::Set{Symbol}
    targets::Set{Symbol}
end

location_prefix(line::LineNumberNode) = "$(something(line.file, :none)):$(line.line): "

function parse_quarto_line(ex, line::LineNumberNode)
    args = Any[a for a in ex.args[3:end] if !(a isa LineNumberNode)]
    head = isempty(args) ? nothing : args[1]
    name, path = if Meta.isexpr(head, :(=)) && head.args[1] isa Symbol
        head.args[1], head.args[2]
    elseif head isa AbstractString
        report_name(head), head
    else
        error(
            location_prefix(line) *
                "expected `@quarto name = \"path.qmd\"` or " *
                "`@quarto \"path.qmd\"`, got `$(ex)`",
        )
    end
    options = Pair{Symbol, Any}[]
    for opt in args[2:end]
        (Meta.isexpr(opt, :(=)) && opt.args[1] isa Symbol) ||
            error(
                location_prefix(line) *
                    "in `@quarto $name`, expected an option like " *
                    "`quarto_args = [\"--to\", \"pdf\"]`, got `$opt`",
            )
        push!(options, opt.args[1] => opt.args[2])
    end
    return QuartoLine(name, path, options, line)
end

const TARGET_OPTIONS = (
    :format,
    :pattern,
    :cue,
    :seed,
    :slots,
    :deployment,
    :error,
    :retries,
    :retry_delay,
)
const REP_OPTIONS = (:batches, :reps, filter(!=(:pattern), TARGET_OPTIONS)...)
const PIPELINE_OPTIONS = (:track, :seed)

function parse_target_line(ex, line::LineNumberNode; kind::Symbol = :target)
    args = Any[a for a in ex.args[3:end] if !(a isa LineNumberNode)]
    (!isempty(args) && Meta.isexpr(args[1], :(=)) && args[1].args[1] isa Symbol) ||
        error(location_prefix(line) * "expected `@$kind name = expression`, got `$(ex)`")
    name, body = args[1].args
    allowed = kind === :rep ? REP_OPTIONS : TARGET_OPTIONS
    options = Pair{Symbol, Any}[]
    for opt in args[2:end]
        (Meta.isexpr(opt, :(=)) && opt.args[1] in allowed) ||
            error(
                location_prefix(line) *
                    "in `@$kind $name`, expected an option like " *
                    "`format = :file`, `pattern = other` or `cue = :always`, got `$opt`",
            )
        push!(options, opt.args[1] => opt.args[2])
    end
    kind === :rep &&
        !issubset((:batches, :reps), first.(options)) &&
        error(location_prefix(line) * "`@rep $name` needs `batches = ...` and `reps = ...`")
    return TargetLine(kind, name, body, options, line)
end

is_macro_line(ex, name) = Meta.isexpr(ex, :macrocall) && ex.args[1] === Symbol(name)

# `f(x) = ...` defines a function, which belongs outside the block.
is_assignment(ex) = Meta.isexpr(ex, :(=)) && !Meta.isexpr(ex.args[1], (:call, :where))

const MAP_OPTIONS = (:names, :prefix)

function parse_map_line(ex, line::LineNumberNode)
    usage = "expected `@map(values; names = ..., prefix = ...) do value ... end`"
    Meta.isexpr(ex, :do) || error(location_prefix(line) * usage * ", got `$ex`")
    call, lambda = ex.args
    args = Any[a for a in call.args[3:end] if !(a isa LineNumberNode)]
    options = Pair{Symbol, Any}[]
    positional = Any[]
    for a in args
        if Meta.isexpr(a, :parameters)
            append!(options, (kw.args[1] => kw.args[2] for kw in a.args))
        elseif Meta.isexpr(a, (:(=), :kw))
            push!(options, a.args[1] => a.args[2])
        else
            push!(positional, a)
        end
    end
    length(positional) == 1 || error(location_prefix(line) * usage * ", got `$call`")
    for (k, _) in options
        k in MAP_OPTIONS ||
            error(
                location_prefix(line) *
                    "@map accepts the options `names` and `prefix`, got `$k`",
            )
    end
    arguments, body = lambda.args
    return MapLine(
        only(positional),
        options,
        arguments,
        parse_map_body(body, arguments),
        line,
    )
end

function parse_map_body(body, arguments::Expr)
    names = collect(
        ExpressionExplorer.compute_reactive_node(Expr(:(=), arguments, 0)).definitions,
    )
    return parse_block(body; arguments = names)
end

function parse_line(ex, line::LineNumberNode)
    is_macro_line(ex, "@target") && return parse_target_line(ex, line)
    is_macro_line(ex, "@rep") && return parse_target_line(ex, line; kind = :rep)
    is_macro_line(ex, "@quarto") && return parse_quarto_line(ex, line)
    (
        is_macro_line(ex, "@map") ||
            (Meta.isexpr(ex, :do) && is_macro_line(ex.args[1], "@map"))
    ) &&
        return parse_map_line(ex, line)
    is_assignment(ex) && return AssignLine(ex, line)
    Meta.isexpr(ex, :(=)) &&
        error(
            location_prefix(line) *
                "define functions outside @targets blocks, got `$(ex.args[1])`",
        )
    return SpliceLine(ex, line)
end

declared_names(t::TargetLine) = t.kind === :rep ?
    [Symbol(t.name, :_batch), Symbol(t.name, :_batches), t.name] :
    [t.name]
declared_names(q::QuartoLine) = [q.name]
# A @map's templates are names of the enclosing block too (each its group).
declared_names(m::MapLine) = collect(m.body.targets)
declared_names(_) = Symbol[]

function assigned_names(a::AssignLine)
    names = collect(ExpressionExplorer.compute_reactive_node(a.ex).definitions)
    isempty(names) &&
        error(
            location_prefix(a.line) *
                "an assignment in @targets must bind names, got `$(a.ex)`",
        )
    return names
end
assigned_names(_) = Symbol[]

function parse_block(block::Expr; arguments = Symbol[])
    items = Any[]
    line = LineNumberNode(0, :none)
    for ex in block.args
        if ex isa LineNumberNode
            line = ex
        else
            push!(items, parse_line(ex, line))
        end
    end
    locals = Set{Symbol}(arguments)
    foreach(item -> union!(locals, assigned_names(item)), items)
    targets = Set{Symbol}()
    for item in items, name in declared_names(item)
        name in locals &&
            error(
                location_prefix(item.line) *
                    "`$name` is both a variable of this block and " *
                    "a target; rename one of them",
            )
        push!(targets, name)
    end
    return Block(items, locals, targets)
end

## Free names of a target's expression

strip_globalrefs(::GlobalRef) = nothing
strip_globalrefs(ex::Expr) = Expr(ex.head, map(strip_globalrefs, ex.args)...)
strip_globalrefs(x) = x

# Macros are expanded where the block is written; what they generate from their
# own module (a `GlobalRef`) cannot be a target or a value of the block.
function expand_body(mod::Module, t::TargetLine)
    expanded = try
        macroexpand(mod, t.body)
    catch e
        e isa InterruptException && rethrow()
        error(
            location_prefix(t.line) *
                "in `@target $(t.name)`, cannot expand macros: " *
                sprint(showerror, e),
        )
    end
    return strip_globalrefs(expanded)
end

function appearance_order(ex, found = Symbol[])
    if ex isa Symbol
        ex in found || push!(found, ex)
    elseif ex isa Expr
        foreach(a -> appearance_order(a, found), ex.args)
    end
    return found
end

"Whether `name` is bound by an enclosing block (`:local`), declared there (`:target`) or neither (`:free`)."
function name_kind(name::Symbol, scopes::Vector{Block})
    for b in Iterators.reverse(scopes)
        name in b.locals && return :local
        name in b.targets && return :target
    end
    return :free
end

"""
The names `expanded` uses without binding them, in order of appearance, except
`own` (a target's own name always means what it means outside the pipeline,
so `@target summary = summary(fit)` works) and variables of enclosing blocks.
"""
function body_refs(expanded, own::Symbol, scopes::Vector{Block})
    found = ExpressionExplorer.compute_reactive_node(expanded).references
    return filter(appearance_order(expanded)) do s
        s in found && s !== own && Base.isidentifier(s) && name_kind(s, scopes) !== :local
    end
end

called_names(ex, found = Symbol[]) = found
function called_names(ex::Expr, found = Symbol[])
    ex.head == :quote && return found
    if ex.head == :call && ex.args[1] isa Symbol
        push!(found, ex.args[1])
    elseif ex.head == :. &&
            length(ex.args) == 2 &&
            ex.args[1] isa Symbol &&
            Meta.isexpr(ex.args[2], :tuple)
        push!(found, ex.args[1]) # `f.(x)`
    end
    foreach(a -> called_names(a, found), ex.args)
    return found
end

## Code generation

# A bare symbol names a target (`pattern = grid`); a quoted one already is a Symbol.
option_value(::Val{:pattern}, v) = pattern_expr(v)

# R-style pattern calls, `map(a, b)`, `cross(a, head(b, 2))`, ..., become combinators.
const PATTERN_CALLS = Dict(
    :map => :Map,
    :cross => :Cross,
    :head => :Head,
    :slice => :Slice,
    :sample => :Sample,
)
pattern_expr(v::Symbol) = QuoteNode(v)
pattern_expr(v) = v
function pattern_expr(v::Expr)
    (Meta.isexpr(v, :call) && haskey(PATTERN_CALLS, v.args[1])) || return v
    f = v.args[1]
    args = v.args[2:end]
    # map and cross combine patterns; the others take one pattern and plain arguments
    parts = f in (:map, :cross) ?
        map(pattern_expr, args) :
        [pattern_expr(args[1]); args[2:end]]
    return Expr(:call, GlobalRef(@__MODULE__, PATTERN_CALLS[f]), parts...)
end
option_value(_, v) = v

keywords(options) = Expr(
    :parameters,
    (Expr(:kw, k, option_value(Val(k), v)) for (k, v) in options)...
)
named_tuple(pairs) = Expr(
    :tuple,
    Expr(:parameters, (Expr(:kw, k, v) for (k, v) in pairs)...),
)
symbols(names) = Expr(:ref, GlobalRef(Core, :Symbol), map(QuoteNode, names)...)

function target_code(t::TargetLine, scopes::Vector{Block}, mod::Module)
    command, called, source = command_code(t, scopes, mod)
    option(k) = only(v for (key, v) in t.options if key == k)
    if t.kind === :rep
        options = [k => v for (k, v) in t.options if !(k in (:batches, :reps))]
        return Expr(
            :call,
            GlobalRef(@__MODULE__, :RepDeclaration),
            QuoteNode(t.name),
            command,
            called,
            QuoteNode(source),
            option(:batches),
            option(:reps),
            named_tuple(options),
            QuoteNode(t.line),
        )
    end
    pattern = [option_value(Val(k), v) for (k, v) in t.options if k == :pattern]
    options = [k => v for (k, v) in t.options if k != :pattern]
    return Expr(
        :call,
        GlobalRef(@__MODULE__, :TargetDeclaration),
        QuoteNode(t.name),
        command,
        called,
        QuoteNode(source),
        isempty(pattern) ? nothing : only(pattern),
        named_tuple(options),
        QuoteNode(t.line),
    )
end

"The `MacroCommand` of a target's expression, the names it calls, and the expression to hash."
function command_code(t::TargetLine, scopes::Vector{Block}, mod::Module)
    expanded = expand_body(mod, t)
    refs = body_refs(expanded, t.name, scopes)
    body = Expr(:->, Expr(:tuple, refs...), Expr(:block, t.line, t.body))
    undefined = GlobalRef(@__MODULE__, :UNDEFINED)
    scope = Expr(
        :->,
        Expr(:tuple),
        named_tuple(r => Expr(:if, Expr(:isdefined, r), r, undefined) for r in refs)
    )
    command = Expr(
        :call,
        GlobalRef(@__MODULE__, :MacroCommand),
        body,
        scope,
        symbols(refs),
        mod,
    )
    source = Base.remove_linenums!(deepcopy(
        t.body isa Expr ? t.body : Expr(:block, t.body),
    ))
    return command, symbols(intersect(called_names(expanded), refs)), source
end

# A report's dependencies come from its document, so it is declared as is.
function quarto_code(q::QuartoLine)
    report = Expr(
        :call,
        GlobalRef(@__MODULE__, :tar_quarto),
        keywords(q.options),
        QuoteNode(q.name),
        q.path,
    )
    return Expr(:call, GlobalRef(@__MODULE__, :PlainDeclaration), report)
end

push_code(acc, declaration) = Expr(:call, GlobalRef(Base, :push!), acc, declaration)

item_code(t::TargetLine, acc, scopes, mod) = push_code(acc, target_code(t, scopes, mod))
item_code(q::QuartoLine, acc, scopes, mod) = push_code(acc, quarto_code(q))
item_code(a::AssignLine, acc, scopes, mod) = a.ex
function item_code(m::MapLine, acc, scopes, mod)
    options = Any[Expr(:kw, k, v) for (k, v) in m.options]
    push!(options, Expr(:kw, :line, QuoteNode(m.line)))
    template = Expr(:->, m.arguments, block_code(m.body, scopes, mod))
    declaration = Expr(
        :call,
        GlobalRef(@__MODULE__, :map_declaration),
        Expr(:parameters, options...),
        template,
        m.values,
    )
    return push_code(acc, declaration)
end
item_code(s::SpliceLine, acc, scopes, mod) = Expr(
    :call,
    GlobalRef(Base, :append!),
    acc,
    Expr(:call, GlobalRef(@__MODULE__, :declarations), s.ex),
)

"Code that runs a block's lines in order and returns its declarations."
function block_code(b::Block, scopes::Vector{Block}, mod::Module)
    scopes = [scopes; b]
    acc = gensym(:declarations)
    code = Any[Expr(:(=), acc, Expr(:ref, GlobalRef(@__MODULE__, :Declaration)))]
    for item in b.items
        push!(code, item.line, item_code(item, acc, scopes, mod))
    end
    push!(code, acc)
    return Expr(:block, code...)
end

function fragment_code(block, mod::Module, caller::AbstractString)
    Meta.isexpr(block, :block) ||
        error("$caller expects a `begin ... end` block of @target lines, got `$block`")
    code = Expr(:let, Expr(:block), block_code(parse_block(block), Block[], mod))
    return Expr(:call, GlobalRef(@__MODULE__, :Fragment), code)
end

"""
    @targets begin
        @target name = expression [options...]
        @quarto name = "report.qmd" [options...]
        variable = value
        other_fragment
        ...
    end

A [`Fragment`](@ref) of targets, to pass to [`tar_pipeline`](@ref) (or to
splice into another block). Each `@target`'s dependencies are the targets its
expression refers to: names its expression binds itself (comprehension
variables, lambda arguments, `let` bindings, ...) and variables of the block
are not targets. A name that is neither a target nor defined where the block
is written is an error when the pipeline is assembled, so fragments in
different files can refer to each other's targets.

Besides `@target` and [`@quarto`](@ref) lines, a block may assign variables
that its targets share (`directory = "output"`), and contain expressions whose
value is a fragment, a target or a collection of them, such as a fragment
returned by a function. Each `@target`'s expression is what gets hashed, so
reformatting never rebuilds; the values it captures from the block (and any
local variables of an enclosing function) are hashed too.

A target's own name in its expression is never a dependency
(`@target summary = summary(fit)` calls the function `summary`). Calling a
function that has the same name as a target is an error, since the name means
the target.
"""
macro targets(block)
    return esc(fragment_code(block, __module__, "@targets"))
end

"""
    @pipeline [track = [...]] [seed = ...] begin
        @target name = expression [format = ...] [pattern = ...] [cue = ...] [seed = ...]
        @quarto name = "report.qmd" [options...]
        ...
    end

[`tar_pipeline`](@ref) of the [`@targets`](@ref) fragment the block declares,
with the given options.
"""
macro pipeline(args...)
    isempty(args) && error("@pipeline expects a `begin ... end` block of @target lines")
    options = Any[]
    for opt in args[1:(end - 1)]
        (Meta.isexpr(opt, :(=)) && opt.args[1] in PIPELINE_OPTIONS) ||
            error(
                "@pipeline accepts only `track = [...]` and `seed = ...` options before its block, got `$opt`",
            )
        push!(options, Expr(:kw, opt.args[1], opt.args[2]))
    end
    call = Expr(
        :call,
        GlobalRef(@__MODULE__, :tar_pipeline),
        Expr(:parameters, options...),
        fragment_code(args[end], __module__, "@pipeline"),
    )
    return esc(call)
end

@testmodule MacroFixtures begin
    using Targets
    export same_graph

    same_graph(p, q) = p.order == q.order &&
        [t.deps for t in p.targets] == [t.deps for t in q.targets] &&
        [t.name for t in p.targets] == [t.name for t in q.targets] &&
        p.graph.fadjlist == q.graph.fadjlist
end

@testitem "a macro pipeline matches the equivalent target() pipeline" setup = [
    MacroFixtures,
] begin
    fit(a, b) = a * b
    p = @pipeline begin
        @target raw = 10
        @target clean = raw + 1
        @target other = 5
        @target model = fit(clean, other) cue = :always
    end
    q = tar_pipeline(
        target(:raw, () -> 10),
        target(:clean, raw -> raw + 1),
        target(:other, () -> 5),
        target(:model, (clean, other) -> 1; cue = :always),
    )
    @test same_graph(p, q)
    @test p.order == [:raw, :clean, :other, :model]
    @test Targets.get_target(p, :model).cue == :always
    @test Targets.get_target(p, :model).deps == [:clean, :other]
    @test Targets.get_target(p, :clean).deps == [:raw]
end

@testitem "dependencies ignore field names, keywords and quoted code" setup = [
    MacroFixtures,
] begin
    f(x; alpha) = x
    g(x) = x
    p = @pipeline begin
        @target settings = (alpha = 1, depth = 2)
        @target alpha = 3
        @target model = settings.alpha + f(1; alpha = 2) + g(:alpha)
    end
    @test Targets.get_target(p, :model).deps == [:settings]
    @test Targets.get_target(p, :settings).deps == Symbol[]
end

@testitem "names an expression binds itself are not dependencies" begin
    summarize(x) = x
    p = @pipeline begin
        @target fit = 1
        @target data = 2
        @target fits = [1, 2]
        @target xs = [3, 4]
        @target local_names = (
            [summarize(fit) for fit in fits] .+ map(data -> data + 1, xs),
            let data = 5
                data
            end,
            map(xs) do fit
                fit * 2
            end,
        )
        @target block_local = begin
            data = 3
            data + 1
        end
    end
    @test Targets.get_target(p, :local_names).deps == [:fits, :xs]
    @test Targets.get_target(p, :block_local).deps == Symbol[]
end

@testitem "macros in an expression are expanded to find its dependencies" begin
    p = @pipeline begin
        @target x = [1, 2]
        @target y = @. x + 1
        @target z = @show(y)
    end
    @test Targets.get_target(p, :y).deps == [:x]
    @test Targets.get_target(p, :z).deps == [:y]
end

@testitem "a name that is neither a target nor defined is an error with its line" begin
    m = Module(:Typos)
    Core.eval(m, :(using Targets))
    @test_throws "uses `cleen`, which is neither a target nor defined" Core.eval(
        m,
        :(
            @pipeline begin
                @target clean = 1
                @target model = cleen + 1
            end
        ),
    )
    @test_throws "did you mean `clean`" Core.eval(
        m,
        :(
            @pipeline begin
                @target clean = 1
                @target model = cleen + 1
            end
        ),
    )
end

@testitem "a target's own name means the function; other targets shadow functions" begin
    total(xs) = sum(xs)
    p = @pipeline begin
        @target xs = [1, 2]
        @target total = total(xs)
    end
    @test Targets.get_target(p, :total).deps == [:xs]
    @test_throws "calls `total`, which is both a target and a function" @pipeline begin
        @target xs = [1, 2]
        @target total = 3
        @target doubled = total(xs) * 2
    end
end

@testitem "fragments refer to each other's targets and splice into blocks" setup = [
    MacroFixtures,
] begin
    inputs = @targets begin
        @target raw = 10
    end
    models = @targets begin
        @target model = raw * 2
    end
    p = tar_pipeline(models, inputs)
    @test Targets.get_target(p, :model).deps == [:raw]
    @test p.order == [:raw, :model]
    scale(k) = @targets begin
        @target scaled = model * k
    end
    q = @pipeline begin
        inputs
        models
        scale(3)
        target(:plain, scaled -> scaled + 1)
        @target summary = (scaled, plain)
    end
    @test [t.name for t in q.targets] == [:raw, :model, :scaled, :plain, :summary]
    @test Targets.get_target(q, :scaled).deps == [:model]
    @test Targets.get_target(q, :summary).deps == [:scaled, :plain]
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(q; store, root = dir, io = devnull)
        @test tar_read(:summary; store) == (60, 61)
    end
end

@testitem "variables of a block and of an enclosing function are captured and hashed" begin
    using Targets: command_hash
    scaled(k) = @targets begin
        offset = 1
        @target x = k + offset
    end
    command(k) = only(tar_pipeline(scaled(k)).targets)
    @test command(2).deps == Symbol[]
    @test command(2).f() == 3
    @test command_hash(command(2)) == command_hash(command(2))
    @test command_hash(command(2)).hash != command_hash(command(3)).hash
    m = Module(:Shadowing)
    Core.eval(m, :(using Targets))
    @test_throws "both a variable of this block and a target" Core.eval(
        m,
        :(
            @targets begin
                x = 1
                @target x = 2
            end
        ),
    )
end

@testitem "@target is only valid inside @targets, and blocks report bad lines" begin
    m = Module(:MacroErrors)
    Core.eval(m, :(using Targets))
    @test_throws "inside @targets or @pipeline" Core.eval(m, :(@target a = 1))
    @test_throws "expected `@target name = expression`" Core.eval(
        m,
        :(
            @pipeline begin
                @target 1 + 2
            end
        ),
    )
    @test_throws "accepts targets, @targets fragments" Core.eval(
        m,
        :(
            @pipeline begin
                5
            end
        ),
    )
    @test_throws "define functions outside" Core.eval(
        m,
        :(
            @pipeline begin
                f(x) = x
            end
        ),
    )
    @test_throws "expected an option" Core.eval(
        m,
        :(
            @pipeline begin
                @target a = 1 colour = :red
            end
        ),
    )
    @test_throws "begin ... end" Core.eval(m, :(@pipeline 5))
    @test_throws "begin ... end" Core.eval(m, :(@targets 5))
end

@testitem "macro pipelines build, and editing one line rebuilds only its descendants" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(clean; note = "") = """
        helper(x) = x * 2
        $note
        p = @pipeline begin
            @target raw = 10
            @target clean = $clean
            @target model = helper(clean)
            @target other = raw - 1
        end
        """
        @test build_source(code("raw + 1"), dir).built == [:raw, :clean, :model, :other]
        @test read_values(dir, :model) == (22,)
        @test isempty(
            build_source(code("raw  +  1"; note = "# moved down a line\n"), dir).built,
        )
        s = build_source(code("raw + 2"), dir)
        @test s.built == [:clean, :model]
        @test s.skipped == [:raw, :other]
    end
end

@testitem "macro targets follow the user code their expressions call" setup = [
    CodeFixtures,
] begin
    code(h2) = """
    h2(x) = $h2
    h1(x) = h2(x) * 2
    p = @pipeline begin
        @target a = h1(1)
    end
    t = only(p.targets)
    """
    base, _ = reach(code("x + 1"))
    @test reach(code("x + 1"))[1] == base
    @test reach(code("x + 2"))[1] != base
end

@testitem "macro pipelines support options and track" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        write_files(dir, "a.txt" => "123", "b.txt" => "45")
        code = """
        p = @pipeline track = [] begin
            @target inputs = ["a.txt", "b.txt"]  format = :file
            @target sizes = filesize(inputs)  pattern = inputs
            @target total = sum(sizes)
        end
        """
        s = build_source(code, dir)
        @test length(s.branches[:sizes]) == 2
        @test read_values(dir, :total) == (5,)
    end
    p = @pipeline seed = 3 begin
        @target a = 1 seed = 7
    end
    @test p.seed == 3 && p.targets[1].seed == 7
end

@testitem "errors in a macro target point at its line" setup = [SourceFixtures] begin
    mktempdir() do dir
        m, path = load_source(
            """
        p = @pipeline begin
            @target fine = 1
            @target bad = error("boom")
        end
        """;
            dir,
        )
        p = Base.invokelatest(getproperty, m, :p)
        f = Targets.get_target(p, :bad).f
        frames = try
            Base.invokelatest(f)
            Any[]
        catch
            stacktrace(catch_backtrace())
        end
        @test any(fr -> endswith(String(fr.file), "src.jl") && fr.line == 3, frames)
    end
end

@testitem "@quarto declares reports inside @pipeline" setup = [MacroFixtures] begin
    mktempdir() do dir
        report = joinpath(dir, "report.qmd")
        summary = joinpath(dir, "summary.qmd")
        write(report, "```{julia}\ntar_read(:n)\n```\n")
        write(summary, "`{julia} tar_read(:report)`\n")
        m = Module(:QuartoMacro)
        Core.eval(m, :(using Targets))
        p = Core.eval(
            m,
            :(
                @pipeline begin
                    @target n = 1
                    @quarto report = $report cue = :always
                    @quarto $summary
                    @target size = length(report)
                end
            ),
        )
        q = tar_pipeline(
            target(:n, () -> 1),
            tar_quarto(:report, report; cue = :always),
            tar_quarto(:summary, summary),
            target(:size, report -> length(report)),
        )
        @test same_graph(p, q)
        @test Targets.get_target(p, :report).cue == :always
        @test Targets.get_target(p, :summary).deps == [:report]
        @test Targets.get_target(p, :size).deps == [:report]
        @test_throws "inside @targets or @pipeline" Core.eval(m, :(@quarto r = $report))
        @test_throws "expected `@quarto name" Core.eval(
            m,
            :(
                @pipeline begin
                    @quarto 1 + 2
                end
            ),
        )
        @test_throws "expected an option" Core.eval(
            m,
            :(
                @pipeline begin
                    @quarto r = $report 5
                end
            ),
        )
    end
end

@testitem "@map matches tar_map: names, dependencies, order and groups" setup = [
    MacroFixtures,
] begin
    m = tar_map((:a, :b)) do k
        (
            target(:grid, () -> [1, 2]),
            target(:fit, (raw, grid) -> (k, raw, grid); pattern = :grid),
            target(:summary, fit -> fit),
        )
    end
    q = tar_pipeline(target(:raw, () -> 1), m, tar_combine(:all, (xs...) -> xs, m.summary))
    p = @pipeline begin
        @target raw = 1
        @map((:a, :b)) do k
            @target grid = [1, 2]
            @target fit = (k, raw, grid) pattern = grid
            @target summary = fit
        end
        @target all = Tuple(summary)
    end
    @test same_graph(p, q)
    @test p.groups == q.groups
    @test Targets.get_target(p, :fit_b).pattern == :grid_b
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        @test tar_read(:all; store) == ([(:a, 1, 1), (:a, 1, 2)], [(:b, 1, 1), (:b, 1, 2)])
    end
end

@testitem "nested @maps with prefixes, and groups as nested NamedTuples" begin
    p = @pipeline begin
        @target mcmc = (; iterations = 10)
        @map((seir = 1, staged = 2)) do model
            @map((real = :real, synthetic = :synthetic); prefix = true) do source
                @target data = (model, source)
                @target tuning = data
                @map(1:2) do k
                    @target chain = (tuning, k, mcmc.iterations)
                end
                @target fit = collect(chain)
            end
        end
        @target fits = fit
    end
    names = [t.name for t in p.targets]
    @test :real_chain_1_seir in names && :synthetic_fit_staged in names
    get(n) = Targets.get_target(p, n)
    @test get(:real_tuning_seir).deps == [:real_data_seir]
    @test get(:real_chain_1_seir).deps == [:real_tuning_seir, :mcmc]
    @test get(:real_fit_seir).deps == [:real_chain_1_seir, :real_chain_2_seir]
    @test get(:fits).deps ==
        [:real_fit_seir, :synthetic_fit_seir, :real_fit_staged, :synthetic_fit_staged]
    @test p.groups[:real_fit] == [:real_fit_seir, :real_fit_staged]
    @test p.groups[:real_chain_1] == [:real_chain_1_seir, :real_chain_1_staged]
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        fits = tar_read(:fits; store)
        @test keys(fits) == (:seir, :staged)
        @test keys(fits.seir) == (:real, :synthetic)
        @test fits.staged.synthetic == [((2, :synthetic), 1, 10), ((2, :synthetic), 2, 10)]
    end
end

@testitem "a fragment spliced into a @map refers to that branch's targets" begin
    mcmc_fit(; chains) = @targets begin
        @map(1:chains) do k
            @target chain = data + k
        end
        @target fit = sum(chain)
    end
    p = @pipeline begin
        @map((a = 10, b = 20)) do v
            (; scale) = (; scale = v)
            @target data = scale
            mcmc_fit(; chains = 2)
            target(:doubled, data -> 2data)
        end
    end
    @test Targets.get_target(p, :chain_1_a).deps == [:data_a]
    @test Targets.get_target(p, :doubled_b).deps == [:data_b]
    @test Targets.get_target(p, :fit_b).deps == [:chain_1_b, :chain_2_b]
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        @test tar_read(:fit_a; store) == 23
        @test tar_read(:fit_b; store) == 43
    end
end

@testitem "@map: changing one value rebuilds only its branch" setup = [SourceFixtures] begin
    mktempdir() do dir
        code(lasso) = """
        p = @pipeline begin
            @target raw = 10
            @map((ols = 1, lasso = $lasso)) do w
                @target fit = raw * w
                @target summary = fit + 1
            end
            @target all = sum(summary)
        end
        """
        @test build_source(code(2), dir).built ==
            [:raw, :fit_ols, :fit_lasso, :summary_ols, :summary_lasso, :all]
        @test read_values(dir, :all) == (32,)
        s = build_source(code(3), dir)
        @test s.built == [:fit_lasso, :summary_lasso, :all]
        @test read_values(dir, :all) == (42,)
    end
end

@testitem "@map reports bad usage" begin
    m = Module(:MapErrors)
    Core.eval(m, :(using Targets))
    @test_throws "inside @targets or @pipeline" Core.eval(
        m,
        :(
            @map(1:2) do k
                k
            end
        ),
    )
    @test_throws "expected `@map(values" Core.eval(
        m,
        :(
            @targets begin
                @map(1:2)
            end
        ),
    )
    @test_throws "options `names` and `prefix`" Core.eval(
        m,
        :(
            @targets begin
                @map(1:2; suffix = true) do k
                    @target x = k
                end
            end
        ),
    )
    @test_throws "pass `names = ...`" Core.eval(
        m,
        :(
            @targets begin
                @map(1:2; prefix = true) do k
                    @target x = k
                end
            end
        ),
    )
    @test_throws "is ambiguous" Core.eval(
        m,
        :(
            @pipeline begin
                @map((:a, :b)) do k
                    @target x = k
                end
                @map((:c, :d)) do k
                    @target x = k
                end
                @target y = x
            end
        ),
    )
end

@testitem "@rep matches tar_rep and tar_map_rep, with the same draws" setup = [
    MacroFixtures,
] begin
    p = @pipeline begin
        @target scale = 10
        @rep draws = scale * rand() batches = 2 reps = 3
        @target n = length(draws)
        @map((a = 1, b = 100)) do mu
            @rep sim = mu + scale batches = 2 reps = 2
        end
    end
    q = tar_pipeline(
        target(:scale, () -> 10),
        tar_rep(:draws, scale -> scale * rand(); batches = 2, reps = 3),
        target(:n, draws -> length(draws)),
        tar_map_rep(
            :sim,
            (mu, scale) -> mu + scale,
            (a = 1, b = 100);
            batches = 2,
            reps = 2,
        ),
    )
    @test same_graph(p, q)
    @test Targets.get_target(p, :sim_batches_b).deps == [:sim_batch_b, :scale]
    mktempdir() do dir
        function value_of(pipeline, name)
            store = joinpath(dir, string(objectid(pipeline)))
            tar_make(pipeline; store, root = dir, io = devnull)
            return tar_read(name; store)
        end
        draws = value_of(p, :draws)
        @test length(draws) == 6 && allunique(draws)
        @test draws == value_of(q, :draws)
        @test value_of(p, :sim_b) == fill(110, 4)
    end
    m = Module(:RepErrors)
    Core.eval(m, :(using Targets))
    @test_throws "needs `batches = ...` and `reps = ...`" Core.eval(
        m,
        :(
            @targets begin
                @rep x = rand() batches = 2
            end
        ),
    )
    @test_throws "inside @targets or @pipeline" Core.eval(m, :(@rep x = 1))
end
