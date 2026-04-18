function tar_make(target_list::T1) where {T1<:Tuple}
    map(generic_hash, target_list)
end
