"""
    tar_read(name; store = default_store_path())

The stored value of target `name`.
"""
function tar_read(name::Symbol; store::Union{Store, AbstractString} = default_store_path())
    s = store isa Store ? store : Store(String(store))
    return read_object(s, name)
end
