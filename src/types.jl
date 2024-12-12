abstract type AbstractSaveFormat end
struct jld2 <: AbstractSaveFormat end
struct h5 <: AbstractSaveFormat end
struct parquet <: AbstractSaveFormat end
struct arrow <: AbstractSaveFormat end
struct csv <: AbstractSaveFormat end

