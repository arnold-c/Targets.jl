# Outline

Create a graph:
- Each target is a node (vertex) with edges defining dependencies to other targets
- tar_make of a single target filters the graph to produce a vertex induced subgraph of all nodes connected to the target
    - Calculate distance (steps) from target
    - Go to furthest point in (sub)graph and check if outdated
        - Outdated if fn typed hash or vargs hash changed
        - If not outdated, go to next furthest target in (sub)graph
        - Repeat until reach target
    - Compute DFS post order topological sort then reverse to determine order of computations

If tar_make called on multiple targets, if they are all connected in a single graph, follow procedure above.
If multiple connected components produced, follow procedure for each component.
DFS can help find all components.


TODO:
- Data files (watch)
- tar_load to create global object with target name
- tar_outdated
    - Would need full graph then check?
- tar_map
- tar_combine
    - Requires dynamic branching
- Propagate target name changes? Hash output and check?
- tar_visnetwork
- tar_glimpse
    - Should be able to accept a single target and visualize a subgraph
- tar_make
    - Should be able to select whether to run in global environment or separate process
- tar_invalidate
- A mechanism to timestamp and archive previously run targets
