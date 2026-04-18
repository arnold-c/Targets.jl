#%%
using DrWatson
@quickactivate "Targets"

using Targets
using DataFrames
using JLD2
using UnPack
using Graphs
using MetaGraphsNext
using GLMakie
using GraphMakie

function theme_adjustments()
    return Theme(;
        fontsize=16,
        Axis=(;
            xlabelsize=20,
            ylabelsize=20,
            xlabelfont=:bold,
            ylabelfont=:bold,
        ),
        Colorbar=(;
            labelsize=20,
            labelfont=:bold,
        ),
    )
end
custom_theme = merge(theme_adjustments(), theme_minimal())

set_theme!(
    custom_theme;
    fontsize=16,
    linewidth=2,
)

# Laptop monitor
# update_theme!(; size = (1220, 640))
# update_theme!(; size = (2100, 1200)) # Home monitor
update_theme!(; size=(950, 550)) # Work monitor
# CairoMakie.activate!(; type = "png", px_per_unit = 1.0)
GLMakie.activate!(; float=true)


#%%
test_function(x::T) where {T<:AbstractString} = length(x)
test_function(x::T) where {T<:Integer} = x^3
test_function(x::T, y::T) where {T<:Integer} = x + y

#%%
hash_fn_method(
    test_function,
    2,
    3;
    hex_output=true
)

#%%
@assert @hash_fn_method(test_function(2)) == hash_fn_method(test_function, 2)
@assert @hash_fn_method(test_function(2, 3)) == hash_fn_method(test_function, 2, 3)

#%%
# hash_df = DataFrames.DataFrame(
#     "output_hashes" => String[],
#     "fn_hashes" => String[],
#     "args_hashes" => String[],
# )
#
# jldsave(joinpath(project_base(), "_meta", "hash_df"); hash_df)

@unpack hash_df = JLD2.load(joinpath(project_base(), "_meta", "hash_df"))

tar_target("test", test_function, 2)

hash_df

#%%
tar_target("test", test_function, 2)
tar_read("test")

tar_target("test3", test_function, 3)
tar_read("test")
tar_read("test3")

#%%
list = @tar_list(
    tar_target("test", test_function, 2),
    tar_target("test3", test_function, 3)
)

(
    tar_target("test", test_function, 2),
    tar_target("test3", test_function, 3)
)


#%%
tar_make(list)

tar_target("test_dep", test_function, "")

#%%
@tar_target("test", test_function(2))

#%%
generic_hash(Any[2])

Meta.@dump test_function(2)

#%%
targraph = MetaGraph(
    SimpleDiGraph();
    label_type=String,
    vertex_data_type=Any,
    edge_data_type=Any,
    graph_data="Targets Graph"
)

targraph["testing"] = 2
targraph["testing2"] = 2
targraph["testing3"] = 3
targraph["testing4"] = 3
targraph["testing", "testing2"] = "edge1"
targraph["testing", "testing3"] = "edge2"

collect(labels(targraph))
collect(edge_labels(targraph))

graphplot(
    targraph;
    ilabels=collect(labels(targraph)),
    # elabels = collect(edge_labels(targraph))
    arrow_shift=:end
)
