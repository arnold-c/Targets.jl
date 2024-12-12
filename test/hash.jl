#%%
using DrWatson
@quickactivate "Targets"

using Targets
using DataFrames
using JLD2

#%%
test_function(x::T) where {T<:AbstractString} = length(x)
test_function(x::T) where {T<:Integer} = x^2
test_function(x::T, y::T) where {T<:Integer} = x + y

#%%
hash_fn_method(
    test_function,
    2,
    3;
    hex_output=true
)

#%%
@hash_fn_method(test_function(2))

#%%
@assert @hash_fn_method(test_function(2)) == hash_fn_method(test_function, 2)

#%%
hash_df = DataFrames.DataFrame(
    "output_hashes" => String[],
    "fn_hashes" => String[],
    "args_hashes" => String[],
)

jldsave(joinpath(project_base(), "_meta", "hash_df"); hash_df)

JLD2.load(joinpath(project_base(), "_meta", "hash_df"), "hash_df")

tar_target("test", test_function, 2)


#%%
tar_target("test", test_function, 2)
tar_read("test")

tar_target("test", test_function, 3)
tar_read("test")
