#%%
using DrWatson
@quickactivate "Targets"

#%%
using JLD2: JLD2
using JuliaFormatter: JuliaFormatter
using Dates: Dates

using Targets

#%%
test_function(x::T) where {T<:AbstractString} = length(x)
test_function(x::T) where {T<:Integer} = x^2
test_function(x::T, y::T) where {T<:Integer} = x + y

#%%
abstract type AbstractSaveFormat end

struct jld2 <: AbstractSaveFormat end
struct h5 <: AbstractSaveFormat end
struct parquet <: AbstractSaveFormat end
struct arrow <: AbstractSaveFormat end
struct csv <: AbstractSaveFormat end

#%%
# macro tar_target(output_name, input, output_format=jld2)
#     # Basic validations
#     if !isa(input, Expr)
#         error("input is of type: $(typeof(input)). It must be an expression")
#     end
#     if !isa(output_name, String)
#         error("output is of type: $(typeof(output_name)). It must be a string")
#     end
#     # accepted_formats = ["jld2", "h5", "parquet", "arrow", "csv"]
#     accepted_formats = ["jld2", "h5"]
#     output_format_string = string(output_format)
#     if !in(output_format_string, accepted_formats)
#         error("output must end with one of the following: $(accepted_formats)")
#     end
#
#     # create output filepath
#     function_name = input.args[1]
#     filedir = joinpath(dirname(project_base()), "_targets", "objects", "$(function_name)")
#     for (i, arg) in pairs(input.args[2:end])
#         filedir = joinpath(filedir, "arg$(i)_$(typeof(arg))")
#     end
#     filename = output_name * "." * output_format_string
#     filepath = joinpath(filedir, filename)
#     println("filepath: $filepath")
#
#
#     quote
#         output = $(esc(input))
#         println("output: $(output)")
#     end
#
#     # save output using format - use multiple dispatch to wrap different save functions
#     tar_save(filepath, input, getfield(__module__, output_format))
#
#     # get current datetime in standard format
#     last_run_datetime = Dates.now(Dates.UTC)
#
#     # update last run timestamp in metadata
#     # update_last_run!(output_name, last_run_datetime)
#
#     return nothing
# end
#
# function tar_save(filepath::T, output, ::Type{jld2}) where {T<:AbstractString}
#     println("output: $(esc(output))")
#     println("jld2 saved")
#     # JLD2.save_object(filepath, output)
# end
#
# function update_last_run!(output_name, last_run_datetime)
#     metadata_filepath = joinpath(dirname(project_base()), "_targets", "metadata.jld2")
#     # check if metadata exists
#     if !isfile(metadata_filepath)
#         # create metadata file
#         open(metadata_filepath, "w") do io
#             println(io, "const $(output_name)_last_run = $last_run_datetime")
#         end
#     end
# end
#
# @tar_target("onearg", test_function(2))
# @tar_target("onearg", test_function(2), jld2)
# @tar_target("onearg", test_function(2), h5)
# @tar_target("onearg", test_function(2), parquet)
# @tar_target("twowargs", test_function(2, 4))
# @tar_target("string", test_function("Test of a string"))
# @tar_target(1, 2)


#%%
macro tar_target(output_name, input_function)
    tar_target(output_name, input_function.args[1], input_function.args[2:end]...)
end

macro tar_target(output_name, input_function, output_format)
    tar_target(output_name, input_function.args[1], input_function.args[2:end]...; output_format=getfield(__module__, output_format))
end

function tar_target(output_name::T1, input_function::T2, vargs...; output_format::Type{T3}=jld2) where {T1<:AbstractString,T2<:Symbol,T3<:AbstractSaveFormat}
    try
        function_name = getfield(@__MODULE__, input_function)
    catch e
        if isa(e, UndefVarError)
            error("Input `$input_function` is not a valid function name")
        end
        error("Error: $e")
    end
    tar_target(output_name, function_name, vargs...; output_format=output_format)
end

function tar_target(output_name::T1, input_function::T2, vargs...; output_format::Type{T3}=jld2) where {T1<:AbstractString,T2<:Function,T3<:AbstractSaveFormat}
    # basic validations
    # accepted_formats = ["jld2", "h5", "parquet", "arrow", "csv"]
    accepted_formats = ["jld2"]
    output_format_string = string(output_format)
    if !in(output_format_string, accepted_formats)
        error("output must end with one of the following: $(accepted_formats)")
    end

    # check if modified since last run
    ## hash input function name with

    # check if 

    # create output filepath
    function_name = nameof(input_function)
    filedir = joinpath(dirname(project_base()), "_targets", "objects", "$(function_name)")
    for (i, arg) in pairs(vargs)
        filedir = joinpath(filedir, "arg$(i)_$(typeof(arg))")
    end
    filename = output_name * "." * output_format_string
    filepath = joinpath(filedir, filename)
    println("filepath: $filepath")

    output = input_function(vargs...)
    @show output

    # save output using format - use multiple dispatch to wrap different save functions
    tar_save(filepath, input_function, getfield(__module__, output_format))

    # get current datetime in standard format
    last_run_datetime = Dates.now(Dates.UTC)

    # update last run timestamp in metadata
    # update_last_run!(output_name, last_run_datetime)
end

tar_target("onearg", test_function, 2)
# tar_target("twoarg", test_function, 2, 3)
@tar_target("twoarg_macro", test_function(2, 3))
# @tar_target("twoarg_macro", test_function(2, 3), jld2)
# @tar_target("twoarg_macro", test_function(2, 3), tsv)

#%%
@code_typed test_function(2)

#%%
a_function(x) = x * x
@code_typed a_function(2)

