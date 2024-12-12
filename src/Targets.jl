module Targets

using SHA: SHA
using Serialization: Serialization
using JLD2: JLD2
using DataFrames: DataFrames

include("helpers.jl")
export project_base

include("types.jl")
export AbstractSaveFormat, jld2

include("hash_methods.jl")
export @hash_fn_method,
hash_fn_method,
generic_hash

include("tar_target.jl")
export tar_target

include("hash_df_funcs.jl")
export load_hash_df,
filter_hash_df_get_rownum,
delete_outdated_hashes!,
update_hash_DF!

include("tar_read.jl")
export tar_read

@static if false
	include("../test/hash.jl")
end

end
