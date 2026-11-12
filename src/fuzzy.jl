## A fuzzy finder for the terminal (used by `tar_picker`)

"""
    word_start(chars, i)

Whether `chars[i]` starts a word: it is the first character, follows a character
that is not a letter or digit, is a capital after a lower-case letter, or a digit
after a letter.
"""
function word_start(chars::Vector{Char}, i::Int)
    i == 1 && return true
    prev, c = chars[i - 1], chars[i]
    return !(isletter(prev) || isdigit(prev)) ||
        (islowercase(prev) && isuppercase(c)) ||
        (isdigit(c) && isletter(prev))
end

"Greedy positions of `term` in `lower` from `start`, or `nothing`."
function match_from(term::Vector{Char}, lower::Vector{Char}, start::Int)
    positions = Int[]
    i = start
    for c in term
        i = findnext(==(c), lower, i)
        i === nothing && return nothing
        push!(positions, i)
        i += 1
    end
    return positions
end

"Score of matching `positions` in `chars`: word starts and runs score, gaps cost."
function term_score(positions::Vector{Int}, chars::Vector{Char})
    score = 0
    for (k, i) in enumerate(positions)
        score += 1 + 3 * word_start(chars, i) + 4 * (k > 1 && positions[k - 1] == i - 1)
    end
    gaps = last(positions) - first(positions) + 1 - length(positions)
    return score - gaps
end

"Best `(score, positions)` of `term` in `chars` (`lower` is them in lower case), or `nothing`."
function term_match(term::Vector{Char}, chars::Vector{Char}, lower::Vector{Char})
    best = nothing
    for start in findall(==(first(term)), lower)
        positions = match_from(term, lower, start)
        positions === nothing && break # a later start cannot match either
        score = term_score(positions, chars)
        (best === nothing || score > first(best)) && (best = (score, positions))
    end
    return best
end

"""
    fuzzy_match(query, candidate)

How well `query` matches `candidate`, as `(score, positions)`, or `nothing` if it
does not. Each space-separated term of `query` must appear in `candidate` in order
but not necessarily together, ignoring case (`fm` matches `fit_model`). Matches at
word starts and runs of consecutive characters score higher, gaps lower.
`positions` are the matched character indices, for highlighting.
"""
function fuzzy_match(query::AbstractString, candidate::AbstractString)
    chars = collect(String(candidate)) # plain `Char`s, even for annotated strings
    lower = lowercase.(chars)
    score = 0
    positions = Int[]
    for term in split(query)
        m = term_match(lowercase.(collect(term)), chars, lower)
        m === nothing && return nothing
        score += first(m)
        append!(positions, last(m))
    end
    return (score, sort!(unique!(positions)))
end

"""
    fuzzy_filter(query, items)

The items matching `query`, best first (ties: shorter, then earlier), as
`(index, positions)` pairs. An empty query keeps every item, in order.
"""
function fuzzy_filter(query::AbstractString, items::Vector{String})
    isempty(strip(query)) && return [(i, Int[]) for i in eachindex(items)]
    scored = [
        (i, m)
        for (i, item) in enumerate(items)
        for m in (fuzzy_match(query, item),)
        if m !== nothing
    ]
    sort!(scored; by = ((i, m),) -> (-first(m), length(items[i]), i))
    return [(i, last(m)) for (i, m) in scored]
end

"""
    Finder

The state of a fuzzy finder over `items`: the `query` typed so far, the
`matches` it gives (see [`fuzzy_filter`](@ref)), the `cursor` (an index into
`matches`), the first shown match minus one (`offset`, so `height` rows around
the cursor are shown), and which items are `selected` when `multiple`.
"""
mutable struct Finder
    const items::Vector{String}
    const multiple::Bool
    const height::Int
    query::String
    matches::Vector{Tuple{Int, Vector{Int}}}
    cursor::Int
    offset::Int
    const selected::BitVector
end

Finder(items::Vector{String}; multiple::Bool = false, height::Int = length(items)) = Finder(
    items,
    multiple,
    height,
    "",
    fuzzy_filter("", items),
    1,
    0,
    falses(length(items)),
)

"The item under the cursor, or `nothing` when nothing matches."
current(f::Finder) = isempty(f.matches) ? nothing : first(f.matches[f.cursor])

function set_query!(f::Finder, query::AbstractString)
    f.query = query
    f.matches = fuzzy_filter(query, f.items)
    f.cursor = 1
    f.offset = 0
    return nothing
end

function move!(f::Finder, by::Int)
    isempty(f.matches) && return nothing
    f.cursor = clamp(f.cursor + by, 1, length(f.matches))
    f.offset = clamp(f.offset, f.cursor - f.height, f.cursor - 1)
    return nothing
end

function toggle!(f::Finder)
    i = current(f)
    i === nothing || (f.selected[i] = !f.selected[i])
    return nothing
end

"Select every match, or unselect them all if they all are."
function toggle_matches!(f::Finder)
    shown = first.(f.matches)
    f.selected[shown] .= !all(f.selected[shown])
    return nothing
end

"Accept, picking the item under the cursor if nothing is selected; do nothing if nothing matches."
function accept!(f::Finder)
    i = current(f)
    f.multiple && any(f.selected) && return :accept
    i === nothing && return :continue
    f.multiple && (f.selected[i] = true)
    return :accept
end

"The picked item indices, in item order (only the cursor's unless `multiple`)."
picked(f::Finder) = f.multiple ? findall(f.selected) : [something(current(f))]

"""
    handle_key!(f::Finder, key)

Update `f` for a key from [`read_key`](@ref), returning `:accept`, `:cancel` or
`:continue`.
"""
function handle_key!(f::Finder, key::Union{Char, Symbol})
    if key isa Char
        set_query!(f, f.query * key)
    elseif key === :backspace
        isempty(f.query) || set_query!(f, chop(f.query))
    elseif key === :clear
        set_query!(f, "")
    elseif key in (:up, :down, :pageup, :pagedown)
        step = key in (:up, :down) ? 1 : f.height
        move!(f, key in (:up, :pageup) ? -step : step)
    elseif f.multiple && key in (:tab, :backtab)
        toggle!(f)
        move!(f, key === :tab ? 1 : -1)
    elseif f.multiple && key === :toggle_all
        toggle_matches!(f)
    elseif key === :enter
        return accept!(f)
    elseif key === :cancel
        return :cancel
    end
    return :continue
end

const CONTROL_KEYS = Dict(
    '\r' => :enter,
    '\n' => :enter,
    '\t' => :tab,
    '\x7f' => :backspace,
    '\b' => :backspace,
    '\x03' => :cancel,     # ctrl-c
    '\x04' => :cancel,     # ctrl-d
    '\x07' => :cancel,     # ctrl-g
    '\x15' => :clear,      # ctrl-u
    '\x01' => :toggle_all, # ctrl-a
    '\x10' => :up,         # ctrl-p
    '\x0e' => :down,       # ctrl-n
)

const ESCAPE_KEYS = Dict(
    "A" => :up,
    "B" => :down,
    "Z" => :backtab, # shift-tab
    "5~" => :pageup,
    "6~" => :pagedown,
)

"""
    read_key(io)

Read one key press from a terminal in raw mode: a printable `Char`, or a `Symbol`
such as `:enter`, `:up` or `:cancel` (`:none` for keys without a meaning here).
The end of the input cancels.
"""
function read_key(io::IO)
    eof(io) && return :cancel
    c = read(io, Char)
    c == '\e' && return read_escape(io)
    haskey(CONTROL_KEYS, c) && return CONTROL_KEYS[c]
    return isprint(c) ? c : :none
end

# A terminal sends a key's escape sequence in one write, so a lone escape is Esc.
function read_escape(io::IO)
    bytesavailable(io) == 0 && return :cancel
    read(io, Char) in ('[', 'O') || return :none # alt+key
    sequence = Char[]
    while !eof(io)
        c = read(io, Char)
        push!(sequence, c)
        '@' <= c <= '~' && break # the final character of a sequence
    end
    return get(ESCAPE_KEYS, String(sequence), :none)
end

"`chars` cut to `room` characters, ending in `…` if cut."
clip(chars::Vector{Char}, room::Int) = length(chars) <= room ?
    chars :
    [chars[1:max(room - 1, 0)]; '…']

function finder_hint(f::Finder)
    count = "$(length(f.matches))/$(length(f.items))"
    f.multiple || return "  $count  enter: choose · esc: cancel"
    return "  $count ($(Base.count(f.selected)) selected)  " *
        "tab: select · ctrl-a: all · enter: done · esc: cancel"
end

function render_row(io::IO, f::Finder, k::Int, width::Int)
    i, positions = f.matches[k]
    here = k == f.cursor
    printstyled(io, here ? "> " : "  "; color = :magenta, bold = true)
    f.multiple && printstyled(io, f.selected[i] ? "* " : "  "; color = :green, bold = true)
    for (j, c) in enumerate(clip(collect(f.items[i]), width - (f.multiple ? 5 : 3)))
        matched = j in positions
        printstyled(io, c; bold = here || matched, color = matched ? :yellow : :normal)
    end
end

"""
    render(io, f::Finder, prompt, width)

Print the finder: the prompt and query, a line with counts and keys, and the
shown matches, each line at most `width - 1` wide so none wraps. Returns the
number of lines printed.
"""
function render(io::IO, f::Finder, prompt::AbstractString, width::Int)
    printstyled(io, prompt; bold = true)
    print(io, String(clip(collect(f.query), width - textwidth(prompt) - 1)), "\n")
    printstyled(io, String(clip(collect(finder_hint(f)), width - 1)); color = :light_black)
    shown = (f.offset + 1):min(f.offset + f.height, length(f.matches))
    for k in shown
        print(io, "\n")
        render_row(io, f, k, width)
    end
    return 2 + length(shown)
end

"Redraw the finder from its first line and leave the cursor after the query."
function draw(io::IO, f::Finder, prompt::AbstractString, width::Int)
    buffer = IOBuffer()
    out = IOContext(buffer, io)
    print(out, "\r\e[J")
    lines = render(out, f, prompt, width)
    column = min(textwidth(prompt) + textwidth(f.query), width - 1)
    print(out, "\e[", lines - 1, "A\r")
    column > 0 && print(out, "\e[", column, "C")
    write(io, take!(buffer))
    flush(io)
    return nothing
end

# What REPL.Terminals.raw! does, without loading REPL.
set_raw_mode(tty::Base.TTY, raw::Bool) = ccall(
    :jl_tty_set_mode,
    Int32,
    (Ptr{Cvoid}, Int32),
    tty.handle,
    raw,
) !=
    -1

"Run `f()` with `input` in raw mode if it is a terminal, so keys arrive one at a time, unechoed."
function with_raw_mode(f, input::IO)
    input isa Base.TTY || return f()
    set_raw_mode(input, true) || error("could not switch the terminal to raw mode")
    try
        return f()
    finally
        set_raw_mode(input, false)
    end
end

"""
    fuzzy_pick(items; multiple = false, prompt = "> ", input = stdin, io = stdout)

Let the user choose among `items` (strings) in a fuzzy finder in the terminal:
typing narrows the list to the items matching the query (see
[`fuzzy_match`](@ref)), best first. Up and down (or ctrl-p and ctrl-n) move,
enter chooses, and Esc or ctrl-c cancels. With `multiple`, tab (shift-tab)
selects the item under the cursor and moves down (up), ctrl-a selects every
match, and enter without a selection chooses the item under the cursor.

Returns the sorted indices of the chosen items (one unless `multiple`), or
`nothing` if cancelled. The finder is erased afterwards.
"""
function fuzzy_pick(
    items::AbstractVector{<:AbstractString};
    multiple::Bool = false,
    prompt::AbstractString = "> ",
    input::IO = stdin,
    io::IO = stdout,
)
    input === stdin &&
        !(input isa Base.TTY) &&
        error("picking needs an interactive terminal, but stdin is not one")
    rows, width = displaysize(io)
    height = clamp(rows - 3, 1, max(length(items), 1))
    f = Finder(String.(items); multiple, height)
    return with_raw_mode(input) do
        try
            while true
                draw(io, f, prompt, width)
                outcome = handle_key!(f, read_key(input))
                outcome === :continue && continue
                return outcome === :accept ? picked(f) : nothing
            end
        finally
            print(io, "\r\e[J")
            flush(io)
        end
    end
end

@testitem "fuzzy_match matches subsequences, preferring word starts and runs" begin
    using Targets: fuzzy_match, fuzzy_filter
    @test fuzzy_match("fm", "fit_model") == (8 - 3, [1, 5])
    @test fuzzy_match("FM", "fit_model") == fuzzy_match("fm", "fit_model")
    @test fuzzy_match("mf", "fit_model") === nothing
    @test fuzzy_match("", "fit_model") == (0, Int[])
    # every term must match, anywhere
    @test last(fuzzy_match("mod fit", "fit_model")) == [1, 2, 3, 5, 6, 7]
    @test fuzzy_match("mod xyz", "fit_model") === nothing
    # the best start is found, not just the first
    @test last(fuzzy_match("model", "my_old_model")) == 8:12
    # camel case and digits start words
    @test last(fuzzy_match("fm", "fitModel")) == [1, 4]
    @test last(fuzzy_match("f2", "fit2_x2")) == [1, 4]

    items = ["my_old_model", "form", "model", "fit_model", "modelling"]
    @test first.(fuzzy_filter("model", items)) == [3, 4, 5, 1]
    @test first.(fuzzy_filter("fm", items)) == [4, 2]
    @test first.(fuzzy_filter(" ", items)) == 1:5
end

@testitem "read_key decodes terminal keys" begin
    using Targets: read_key
    io = IOBuffer("aé\r\t\e[A\e[B\eOA\e[Z\e[5~\e[6~\e[3~\x7f\x15\x01\x03\x10\x0e\ex\e")
    keys = Any[]
    while !eof(io)
        push!(keys, read_key(io))
    end
    @test keys ==
        [
            'a',
            'é',
            :enter,
            :tab,
            :up,
            :down,
            :up,
            :backtab,
            :pageup,
            :pagedown,
            :none,
            :backspace,
            :clear,
            :toggle_all,
            :cancel,
            :up,
            :down,
            :none,
            :cancel,
        ]
    @test read_key(io) === :cancel # end of input
end

@testitem "fuzzy_pick picks by typing" begin
    using Targets: fuzzy_pick
    items = ["fit_model", "fit_data", "plot_model", "summary"]
    pick(keys; multiple = true) = fuzzy_pick(
        items;
        multiple,
        input = IOBuffer(keys),
        io = IOBuffer(),
    )
    @test pick("model\x01\r") == [1, 3]         # ctrl-a selects all matches
    @test pick("sum\r") == [4]                  # enter picks the cursor without a selection
    @test pick("fit\t\t\r") == [1, 2]           # tab selects and moves down
    @test pick("fit\e[B\t\r") == [1]            # fit_data (shorter) comes first
    @test pick("sx\x7fum\r") == [4]             # backspace
    @test pick("x\x15plot\r") == [3]            # ctrl-u clears
    @test pick("\t\e[Z\r") == [1, 2]            # shift-tab selects and moves up
    @test pick("model\x01\x01\x15sum\r") == [4] # ctrl-a again unselects
    @test pick("zzz\r") === nothing             # nothing to pick, then the input ends
    @test pick("fit\x03") === nothing
    @test pick("plot\r"; multiple = false) == [3]
    @test pick("\e[B\e[B\r"; multiple = false) == [3]
    @test pick("\e[A\r"; multiple = false) == [1]    # the cursor stops at the top
    @test pick("model\t\r"; multiple = false) == [1] # no selection in single mode
end

@testitem "the finder shows the query, counts and matches" begin
    using Targets: Finder, handle_key!, render
    f = Finder(
        ["fit_model", "fit_data", "plot_model", "summary"];
        multiple = true,
        height = 1,
    )
    foreach(c -> handle_key!(f, c), "fit")
    handle_key!(f, :tab)
    text = sprint(io -> render(io, f, "Targets> ", 80))
    @test text ==
        "Targets> fit\n" *
            "  2/4 (1 selected)  tab: select · ctrl-a: all · enter: done · esc: cancel\n" *
            ">   fit_model" # scrolled to the cursor, height 1
    @test f.offset == 1
    @test sprint(io -> render(io, Finder(["a_long_name"]), "> ", 10)) ==
        "> \n  1/1  e…\n> a_long…"
end
