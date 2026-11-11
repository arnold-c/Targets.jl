## Showing a build in the terminal
##
## `tar_make` reports through a `BuildDisplay`: the scheduler tells it when jobs
## are queued, start and finish, and when a target is done, and hands it the log
## lines to show. A `PlainDisplay` prints one line per event.

abstract type BuildDisplay end

"Prints every log line as it comes, including a line when a job starts."
struct PlainDisplay <: BuildDisplay
    io::IO
end

"Show a log line."
show_line(d::PlainDisplay, line::AbstractString) = println(d.io, line)

start_line(job::Job) = "▶ $(job.key) ($(job.reason))"

"`n` jobs were queued."
queued!(::BuildDisplay, n::Int) = nothing

"`job` started running."
started!(d::PlainDisplay, job::Job) = show_line(d, start_line(job))

"`job` finished running (its outcome is logged when it is committed)."
finished!(::BuildDisplay, ::Job) = nothing

"A target is done: built, up to date, errored or blocked."
target_done!(::BuildDisplay) = nothing
