module TargetsDataFramesExt

# Loaded once DataFrames is: a pattern target may return a GroupedDataFrame, and
# a branching target then runs once per group.

using DataFrames: DataFrame, GroupedDataFrame
using Targets: Targets

# Each branch receives a copy of its group, so stored branch values do not alias
# (or drag along) the whole parent table.
Targets.branch_elements(g::GroupedDataFrame) = [DataFrame(sub) for sub in g]

# A group is identified by its key and its contents, so editing one group
# rebuilds one branch, and adding a group builds one new branch.
function Targets.element_hashes(g::GroupedDataFrame)
    hashes = map(collect(pairs(g))) do (key, sub)
        content = Tuple(names(sub) .=> (collect(c) for c in eachcol(sub)))
        Targets.canonical_hash((NamedTuple(key), content))
    end
    return Targets.disambiguate(String[hashes...])
end

end
