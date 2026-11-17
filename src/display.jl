## Showing a build in the terminal
##
## `tar_make` reports through a `BuildDisplay`: the scheduler tells it when jobs
## are queued, start and finish, and when a target is done, and hands it the log
## lines to show. A `PlainDisplay` prints one line per event. In a terminal, a
## `LiveDisplay` keeps a footer under the log instead: a spinner line per running
## job and a counter, redrawn by a ticker task. Log lines are printed above the
## footer, so a job shows up once, as its `✔` or `✖` line, when it finishes.

abstract type BuildDisplay end

const PROGRESS_MODES = (:auto, :live, :lines)

function check_progress(progress::Symbol)
    progress in PROGRESS_MODES ||
        throw(ArgumentError(
            "progress must be one of $(join(repr.(PROGRESS_MODES), ", ")), got `$(repr(progress))`",
        ))
    return progress
end

is_terminal(io::IO) = io isa Base.TTY && get(ENV, "TERM", "") != "dumb"

"""
    open_display(progress, io, total) -> BuildDisplay

The display for a build of `total` targets: live with `progress = :live`, or
with `:auto` when `io` is a terminal; plain lines otherwise.
"""
function open_display(progress::Symbol, io::IO, total::Int)
    check_progress(progress)
    live = progress === :live || (progress === :auto && is_terminal(io))
    return live ? LiveDisplay(io, total) : PlainDisplay(io)
end

## Log lines

start_line(job::Job) = "▶ $(job.key) ($(job.reason))"

"The log line of a finished job: green when it was built, red when it failed."
done_line(r::JobResult) = failed(r) ?
    styled"{error:✖ $(r.job.key): $(first(sprint(showerror, r.exception), 200))}" :
    styled"{success:✔ $(r.job.key) $(round(r.seconds; digits = 2))s ($(r.job.reason))}"

## The display interface, and plain lines

"Prints every log line as it comes, including a line when a job starts."
struct PlainDisplay <: BuildDisplay
    io::IO
end

"Show a log line."
show_line(d::PlainDisplay, line::AbstractString) = println(d.io, line)

"`n` jobs were queued."
queued!(::BuildDisplay, n::Int) = nothing

"`job` started running."
started!(d::PlainDisplay, job::Job) = show_line(d, start_line(job))

"`job` finished running (its outcome is logged when it is committed)."
finished!(::BuildDisplay, ::Job) = nothing

"A target is done: built, up to date, errored or blocked."
target_done!(::BuildDisplay) = nothing

"Run `f` while `d` is showing the build."
showing(f, ::PlainDisplay) = f()

## The live footer

const SPINNER = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
const TICK_SECONDS = 0.1

const RunningJob = @NamedTuple{key::String, reason::Symbol, started::Float64}

"""
Keeps a footer of running jobs and a counter under the log, redrawn every
`TICK_SECONDS` by a ticker task. Everything is drawn under `lock`, by the
scheduler (log lines, jobs starting) and by the ticker (the spinner).
"""
mutable struct LiveDisplay <: BuildDisplay
    const io::IO
    const total::Int
    const started::Float64
    const lock::ReentrantLock
    const running::Vector{RunningJob}
    queued::Int
    done::Int
    drawn::Int # footer lines on screen
    closed::Bool
end
LiveDisplay(io::IO, total::Int; now::Float64 = time()) = LiveDisplay(
    io,
    total,
    now,
    ReentrantLock(),
    RunningJob[],
    0,
    0,
    0,
    false,
)

show_line(d::LiveDisplay, line::AbstractString) = lock(() -> redraw!(d, line), d.lock)

queued!(d::LiveDisplay, n::Int) = lock(() -> (d.queued += n; nothing), d.lock)

function started!(d::LiveDisplay, job::Job)
    lock(d.lock) do
        d.queued = max(d.queued - 1, 0)
        push!(d.running, (key = job.key, reason = job.reason, started = time()))
        redraw!(d)
    end
end

finished!(d::LiveDisplay, job::Job) = lock(
    () -> (filter!(j -> j.key != job.key, d.running); nothing),
    d.lock,
)

target_done!(d::LiveDisplay) = lock(() -> (d.done += 1; nothing), d.lock)

function showing(f, d::LiveDisplay)
    print(d.io, "\e[?25l") # hide the cursor while the footer is drawn
    Threads.@spawn :interactive tick!(d)
    try
        return with_display_logger(f, d)
    finally
        close!(d)
    end
end

"Redraw `d` until it is closed, so its spinners turn and its times count up."
function tick!(d::LiveDisplay)
    while true
        sleep(TICK_SECONDS)
        closed = lock(d.lock) do
            d.closed || redraw!(d)
            d.closed
        end
        closed && return nothing
    end
end

"Remove the footer for good: later lines print as plain lines."
function close!(d::LiveDisplay)
    lock(d.lock) do
        d.closed = true
        redraw!(d)
        print(d.io, "\e[?25h")
    end
    return nothing
end

"""
    redraw!(d, above = nothing; now = time())

Clear the footer, print the log line `above` (if any) where it was, and draw the
footer again below it, in one write. Call with `d.lock` held.
"""
function redraw!(d::LiveDisplay, above = nothing; now::Float64 = time())
    buffer = IOBuffer()
    io = IOContext(buffer, :color => get(d.io, :color, false))
    d.drawn > 0 && print(io, "\r\e[", d.drawn, "A\e[J")
    above === nothing || println(io, above)
    lines = d.closed ? String[] : footer_lines(d, now)
    foreach(line -> println(io, line), lines)
    write(d.io, take!(buffer))
    flush(d.io)
    d.drawn = length(lines)
    return nothing
end

"""
    footer_lines(d, now)

A spinner line per running job with its reason and time so far, then a counter.
Lines are cut to the terminal's width, so none wraps, and jobs that do not fit
its height are counted instead.
"""
function footer_lines(d::LiveDisplay, now::Float64)
    rows, cols = displaysize(d.io)
    spinner = SPINNER[mod1(round(Int, now / TICK_SECONDS), length(SPINNER))]
    room = max(rows - 2, 1)
    n = length(d.running)
    shown = n <= room ? n : room - 1
    lines = String[
        "$spinner $(j.key) ($(j.reason)) $(format_seconds(now - j.started))"
        for j in d.running[1:shown]
    ]
    n > shown && push!(lines, "  … and $(n - shown) more running")
    push!(
        lines,
        "$(d.done)/$(d.total) targets done · $n running · $(d.queued) queued · " *
            format_seconds(now - d.started),
    )
    return [fit_width(line, cols - 1) for line in lines]
end

fit_width(s::AbstractString, n::Int) = length(s) <= n ? s : first(s, max(n - 1, 0)) * "…"

function format_seconds(s::Real)
    s < 60 && return "$(round(s; digits = 1))s"
    minutes, seconds = divrem(round(Int, s), 60)
    minutes < 60 && return "$(minutes)m $(lpad(seconds, 2, '0'))s"
    hours, minutes = divrem(minutes, 60)
    return "$(hours)h $(lpad(minutes, 2, '0'))m"
end

## Log messages from targets, printed above the footer

"""
Formats log records like the console logger it replaces, and prints them
through a live display, so they appear above its footer instead of through it.
"""
struct LiveLogger <: Logging.AbstractLogger
    display::LiveDisplay
    console::Logging.ConsoleLogger # writes into `buffer`
    buffer::IOBuffer
end
function LiveLogger(d::LiveDisplay, parent::Logging.ConsoleLogger)
    buffer = IOBuffer()
    io = IOContext(
        buffer,
        :color => get(d.io, :color, false),
        :displaysize => displaysize(d.io),
    )
    console = Logging.ConsoleLogger(
        io,
        parent.min_level;
        meta_formatter = parent.meta_formatter,
        show_limited = parent.show_limited,
        right_justify = parent.right_justify,
    )
    return LiveLogger(d, console, buffer)
end

Logging.min_enabled_level(l::LiveLogger) = Logging.min_enabled_level(l.console)
Logging.shouldlog(l::LiveLogger, args...) = Logging.shouldlog(l.console, args...)
Logging.catch_exceptions(l::LiveLogger) = Logging.catch_exceptions(l.console)
function Logging.handle_message(l::LiveLogger, args...; kwargs...)
    lock(l.display.lock) do
        Logging.handle_message(l.console, args...; kwargs...)
        text = String(take!(l.buffer))
        isempty(text) || redraw!(l.display, chomp(text))
    end
    return nothing
end

"Run `f` with console log messages routed through `d` (other loggers are left alone)."
function with_display_logger(f, d::LiveDisplay)
    parent = ScopedValues.current_logger()
    parent isa Logging.ConsoleLogger || return f()
    return ScopedValues.with_logger(f, LiveLogger(d, parent))
end

@testitem "a live footer lists running jobs and counts the rest" begin
    using Targets: LiveDisplay, footer_lines, format_seconds
    d = LiveDisplay(IOBuffer(), 3; now = 100.0)
    push!(d.running, (key = "fit/a1", reason = :missing, started = 98.0))
    d.queued = 2
    d.done = 1
    lines = footer_lines(d, 104.0)
    @test endswith(lines[1], " fit/a1 (missing) 6.0s")
    @test lines[2] == "1/3 targets done · 1 running · 2 queued · 4.0s"
    # the spinner turns with time
    @test first(footer_lines(d, 104.0)[1]) != first(footer_lines(d, 104.1)[1])
    @test (format_seconds(75), format_seconds(3725)) == ("1m 15s", "1h 02m")
    # a small terminal: jobs that do not fit are counted, and no line wraps
    small = LiveDisplay(IOContext(IOBuffer(), :displaysize => (5, 30)), 9; now = 0.0)
    for i in 1:5
        push!(
            small.running,
            (key = "a_long_target_name_$i", reason = :missing, started = 0.0),
        )
    end
    lines = footer_lines(small, 1.0)
    @test length(lines) == 4
    @test lines[3] == "  … and 3 more running"
    @test all(l -> length(l) <= 29, lines)
end

@testitem "a live display prints log lines above its footer" begin
    using Targets: LiveDisplay, redraw!, close!
    io = IOBuffer()
    d = LiveDisplay(io, 1; now = 0.0)
    push!(d.running, (key = "a", reason = :missing, started = 0.0))
    redraw!(d; now = 1.0)
    @test d.drawn == 2
    take!(io)
    redraw!(d, "done"; now = 1.0)
    @test startswith(String(take!(io)), "\r\e[2A\e[Jdone\n")
    close!(d)
    @test String(take!(io)) == "\r\e[2A\e[J\e[?25h"
    redraw!(d, "after") # a closed display prints plain lines
    @test String(take!(io)) == "after\n"
end

@testitem "tar_make shows a finished job once, with its reason" setup = [
    SourceFixtures,
] begin
    using Logging
    code = """
    p = tar_pipeline(
        target(:a, () -> (@info "hello from a"; 1)),
        target(:b, a -> a + 1),
        target(:bad, () -> error("boom")),
    )
    """
    mktempdir() do dir
        io = IOBuffer()
        # log messages go through the footer instead of the console logger's stream
        with_logger(ConsoleLogger(devnull)) do
            build_source(code, dir; io, progress = :live, keep_going = true)
        end
        out = String(take!(io))
        @test occursin(r"✔ a [0-9.]+s \(missing\)", out)
        @test occursin("✖ bad: boom", out)
        @test occursin("hello from a", out)
        @test occursin("targets done", out) # the footer
        @test !occursin("▶", out)
        @test endswith(
            out,
            "\e[?25h" * "summary: 2 built, 0 up to date, 1 errored, 0 blocked\n",
        )
        # the log file keeps every line
        log = read(joinpath(dir, "_targets", "log", "progress.log"), String)
        @test occursin("▶ a (missing)", log) && occursin(r"✔ a [0-9.]+s \(missing\)", log)
        # plain lines, in colour where the stream has it
        io = IOContext(IOBuffer(), :color => true)
        build_source(code, dir; io, progress = :lines, keep_going = true, force = true)
        out = String(take!(io.io))
        @test occursin("▶ a (forced)", out)
        @test occursin(r"\e\[32m✔ a [0-9.]+s \(forced\)\e\[39m", out)
        @test occursin(r"\e\[[0-9]+m✖ bad: boom", out)
        @test_throws "progress must be one of" build_source(code, dir; progress = :fancy)
    end
end
