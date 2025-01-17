"""
    ABCDParams

A structure holding parameters for ABCD graph generator. Fields:
* w::Vector{Int32}:             a sorted in descending order list of vertex degrees
* s::Vector{Int32}:             a sorted in descending order list of cluster sizes
* μ::Union{Float64, Nothing}: mixing parameter
* ξ::Union{Float64, Nothing}: background graph fraction
* isCL::Bool:                 if `true` a Chung-Lu model is used, otherwise configuration model
* islocal::Bool:              if `true` mixing parameter restriction is cluster local, otherwise
                              it is only global

Exactly one of ξ and μ must be passed as `Float64`. Also if `ξ` is passed then
`islocal` must be `false`.

The base ABCD graph is generated when ξ is passed and `isCL` is set to `false`.
"""
struct ABCDParams
    w::Vector{Int32}
    s::Vector{Int32}
    μ::Union{Float64, Nothing}
    ξ::Union{Float64, Nothing}
    isCL::Bool
    islocal::Bool

    function ABCDParams(w, s, μ, ξ, isCL, islocal)
        length(w) == sum(s) || throw(ArgumentError("inconsistent data"))
        if !isnothing(μ)
            0 ≤ μ ≤ 1 || throw(ArgumentError("inconsistent data on μ"))
        end
        if !isnothing(ξ)
            0 ≤ ξ ≤ 1 || throw(ArgumentError("inconsistent data ξ"))
            if islocal
                throw(ArgumentError("when ξ is provided local model is not allowed"))
            end
        end
        if isnothing(μ) && isnothing(ξ)
            throw(ArgumentError("inconsistent data: either μ or ξ must be provided"))
        end

        if !(isnothing(μ) || isnothing(ξ))
            throw(ArgumentError("inconsistent data: only μ or ξ may be provided"))
        end

        new(sort(w, rev=true),
            sort(s, rev=true),
            μ, ξ, isCL, islocal)
    end
end

function randround(x)
    d = floor(Int32, x)
    d + (rand() < x - d)
end

function populate_clusters(params::ABCDParams)
    w, s = params.w, params.s
    if isnothing(params.ξ)
        mul = 1.0 - params.μ
    else
        n = length(w)
        ϕ = 1.0 - sum((sl/n)^2 for sl in s)
        mul = 1.0 - params.ξ*ϕ
    end
    @assert length(w) == sum(s)
    @assert 0 ≤ mul ≤ 1
    @assert issorted(w, rev=true)
    @assert issorted(s, rev=true)

    slots = copy(s)
    clusters = Int32[]
    j = 0
    for (i, vw) in enumerate(w)
        while j + 1 ≤ length(s) && mul * vw + 1 ≤ s[j + 1]
            j += 1
        end
        j == 0 && throw(ArgumentError("could not find a large enough cluster for vertex of weight $vw"))
        wts = Weights(view(slots, 1:j))
        wts.sum == 0 && throw(ArgumentError("could not find an empty slot for vertex of weight $vw"))
        loc = sample(1:j, wts)
        push!(clusters, loc)
        slots[loc] -= 1
    end
    clusters
end

function CL_model(clusters, params)
    @assert params.isCL
    w, s, μ = params.w, params.s, params.μ
    cluster_weight = zeros(Int32, length(s))
    for i in axes(w, 1)
        cluster_weight[clusters[i]] += w[i]
    end
    total_weight = sum(cluster_weight)
    @assert total_weight == sum(w)
    if params.islocal
        ξl = @. μ / (1.0 - cluster_weight / total_weight)
        maximum(ξl) >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
    else
        if isnothing(params.ξ)
            ξg = μ / (1.0 - sum(x -> x^2, cluster_weight) / total_weight^2)
            ξg >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
        else
            ξg = params.ξ
        end
    end

    wf = float.(w)
    edges = Set{Tuple{Int32, Int32}}()
    mutex = ReentrantLock()
    @threads for tid in 1:nthreads()
        local thr_edges = Set{Tuple{Int32, Int32}}[]
        for i in tid:nthreads():length(s)
            local local_edges = Set{Tuple{Int32, Int32}}()
            local idxᵢ = findall(==(i), clusters)
            @debug "tid:$(tid) start CL_model for i:$(i) size:$(length(idxᵢ))"
            local wᵢ = wf[idxᵢ]
            local ξ = params.islocal ? ξl[i] : ξg
            local m = randround((1-ξ) * sum(wᵢ) / 2)
            local ww = Weights(wᵢ)
            while length(local_edges) < m
                local a = sample(idxᵢ, ww, m - length(local_edges))
                local b = sample(idxᵢ, ww, m - length(local_edges))
                for (p, q) in zip(a, b)
                    p != q && push!(local_edges, minmax(p, q))
                end
            end
            push!(thr_edges, local_edges)
            @debug "tid:$(tid) end CL_model for i:$(i) size:$(length(idxᵢ))"
        end
        @debug "tid:$(tid) synch CL_model"
        lock(mutex)
        union!(edges, thr_edges...)
        unlock(mutex)
        @debug "tid:$(tid) end CL_model"
    end
    wwt = if params.islocal
        Weights([ξl[clusters[i]]*x for (i,x) in enumerate(wf)])
    else
        Weights(ξg * wf)
    end
    while 2*length(edges) < total_weight
        a = sample(axes(w, 1), wwt, randround(total_weight / 2) - length(edges))
        b = sample(axes(w, 1), wwt, randround(total_weight / 2) - length(edges))
        for (p, q) in zip(a, b)
            p != q && push!(edges, minmax(p, q))
        end
    end
    edges
end

function config_model(clusters, params)
    @assert !params.isCL
    w, s, μ = params.w, params.s, params.μ

    cluster_weight = zeros(Int32, length(s))
    for i in axes(w, 1)
        cluster_weight[clusters[i]] += w[i]
    end
    total_weight = sum(cluster_weight)
    @assert total_weight == sum(w)
    if params.islocal
        ξl = @. μ / (1.0 - cluster_weight / total_weight)
        maximum(ξl) >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
        w_internal_raw = [w[i] * (1 - ξl[clusters[i]]) for i in axes(w, 1)]
    else
        if isnothing(params. ξ)
            ξg = μ / (1.0 - sum(x -> x^2, cluster_weight) / total_weight^2)
            ξg >= 1 && throw(ArgumentError("μ is too large to generate a graph"))
        else
            ξg = params.ξ
        end
        w_internal_raw = [w[i] * (1 - ξg) for i in axes(w, 1)]
    end

    clusterlist = [Int32[] for i in axes(s, 1)]
    for i in axes(clusters, 1)
        push!(clusterlist[clusters[i]], i)
    end
    # order by cluster size
    # idx = sortperm([length(cluster) for cluster in clusterlist], rev=true)
    # clusterlist = clusterlist[idx]

    edges::Vector{Set{Tuple{Int32, Int32}}} = []
    unresolved_collisions, length_global_recycle = 0, 0
    w_internal = Vector{Int32}(undef, length(w_internal_raw))
    mutex = ReentrantLock()
    @threads for tid in 1:nthreads()
      local thr_clusters::Vector{Vector{Int32}} = []
      local thr_weights::Vector{Vector{Int32}} = []

      for c in tid:nthreads():length(s)
        local cluster = clusterlist[c]
        local w_cluster = Vector{Int32}(undef, length(cluster))
        local maxw_idx = argmax(view(w_internal_raw, cluster))
        local wsum = 0
        for i in axes(cluster, 1)
            if i != maxw_idx
                neww = randround(w_internal_raw[cluster[i]])
                w_cluster[i] = neww
                wsum += neww
            end
        end
        local maxw = floor(Int32, w_internal_raw[cluster[maxw_idx]])
        w_cluster[maxw_idx] = maxw + (isodd(wsum) ? iseven(maxw) : isodd(maxw))

        push!(thr_clusters, cluster)
        push!(thr_weights, w_cluster)
      end
      @debug "tid $(tid) getting 1st lock"
      lock(mutex)
      @debug "tid $(tid) got 1st lock"
      foreach((cluster,w_cluster)->w_internal[cluster]=w_cluster, thr_clusters, thr_weights)
      @debug "tid $(tid) releasing 1st lock"
      unlock(mutex)
    end

    global_edges = Set{Tuple{Int32, Int32}}()
    recycle = Tuple{Int32,Int32}[]
    w_global = w - w_internal
    stubs::Vector{Int32} = Vector{Int32}(undef, sum(w_global))

    ch = Channel{Int}(1+length(s))
    foreach(cid->put!(ch, cid), 0:length(s))
    close(ch)

    @threads for tid in 1:nthreads()
        local thr_edges   = Set{Tuple{Int32, Int32}}[]
        local thr_recycle = Vector{Tuple{Int32,Int32}}[]

        for cid in ch
            local local_recycle = Tuple{Int32,Int32}[]
            if cid == 0 # global/background graph
                sizehint!(global_edges, length(stubs)>>1)
                # populate stubs
                local v::Vector{Int} = similar(w_global, Int, length(w_global)+1)
                v[1] = 0; cumsum!(view(v, 2:length(v)), w_global)
                foreach(i->stubs[v[i]+1:v[i+1]].=i, axes(w_global,1));
                @assert sum(w) == length(stubs) + sum(w_internal)
                shuffle!(stubs)

                for i in 1:2:length(stubs)
                    e = minmax(stubs[i], stubs[i+1])
                    if (e[1] == e[2]) || (e in global_edges)
                        push!(local_recycle, e)
                    else
                        push!(global_edges, e)
                    end
                end
                length_global_recycle = length(local_recycle)
                if length_global_recycle > 0
                    @warn "global collisions: $(length_global_recycle) fraction: $(2 * length_global_recycle / total_weight)"
                    @debug "dups1 are $(local_recycle)"
                end
            else # community graphs
                local cluster = clusterlist[cid]
                local w_cluster = w_internal[cluster]

                @debug "tid $(tid) cluster $(length(cluster)) w_cluster $(sum(w_cluster))"
                local local_stubs::Vector{Int32} = Vector{Int32}(undef, sum(w_cluster))
                # populate stubs
                local v = similar(w_cluster, Int, length(w_cluster)+1)
                v[1] = 0; cumsum!(view(v, 2:length(v)), w_cluster)
                foreach((i,j)->local_stubs[v[i]+1:v[i+1]].=j, axes(cluster,1), cluster);
                @assert sum(w_cluster) == length(local_stubs)

                shuffle!(local_stubs)
                local local_edges = Set{Tuple{Int32, Int32}}()
                sizehint!(local_edges, length(local_stubs)>>1)
                for i in 1:2:length(local_stubs)
                    e = minmax(local_stubs[i], local_stubs[i+1])
                    if (e[1] == e[2]) || (e in local_edges)
                        push!(local_recycle, e)
                    else
                        push!(local_edges, e)
                    end
                end
                local last_recycle = length(local_recycle)
                local recycle_counter = last_recycle
                while !isempty(local_recycle)
                    recycle_counter -= 1
                    if recycle_counter < 0
                        if length(local_recycle) < last_recycle
                            last_recycle = length(local_recycle)
                            recycle_counter = last_recycle
                        else
                            break
                        end
                    end
                    local p1 = popfirst!(local_recycle)
                    local from_recycle = 2 * length(local_recycle) / length(local_stubs)
                    local success = false
                    for _ in 1:2:length(local_stubs)
                        local p2 = if rand() < from_recycle
                            used_recycle = true
                            recycle_idx = rand(axes(local_recycle, 1))
                            local_recycle[recycle_idx]
                        else
                            used_recycle = false
                            rand(local_edges)
                        end
                        if rand() < 0.5
                            local newp1 = minmax(p1[1], p2[1])
                            local newp2 = minmax(p1[2], p2[2])
                        else
                            local newp1 = minmax(p1[1], p2[2])
                            local newp2 = minmax(p1[2], p2[1])
                        end
                        if newp1 == newp2
                            good_choice = false
                        elseif (newp1[1] == newp1[2]) || (newp1 in local_edges)
                            good_choice = false
                        elseif (newp2[1] == newp2[2]) || (newp2 in local_edges)
                            good_choice = false
                        else
                            good_choice = true
                        end
                        if good_choice
                            if used_recycle
                                local_recycle[recycle_idx], local_recycle[end] = local_recycle[end], local_recycle[recycle_idx]
                                pop!(local_recycle)
                            else
                                pop!(local_edges, p2)
                            end
                            success = true
                            push!(local_edges, newp1)
                            push!(local_edges, newp2)
                            break
                        end
                    end
                    success || push!(local_recycle, p1)
                end
                push!(thr_edges, local_edges)
            end
            push!(thr_recycle, local_recycle)
        end
        @debug "tid $(tid) getting 2nd lock"
        lock(mutex)
        @debug "tid $(tid) got 2nd lock"
        append!(edges, thr_edges)
        append!(recycle, thr_recycle...)
        @debug "tid $(tid) releasing 2nd lock"
        unlock(mutex)
    end

    unresolved_collisions = length(recycle) - length_global_recycle
    if unresolved_collisions > 0
        @warn "Unresolved cluster collisions: $(unresolved_collisions) fraction: $(2 * unresolved_collisions / total_weight)"
    end

    @debug "GLOBAL resolving dups"
    @debug "intersect $(length(global_edges)) global_edges with $(typeof(edges)) $([length(e) for e in edges])"
    dups = [Set{Tuple{Int32, Int32}}() for _ in axes(edges, 1)]
    @threads for i in axes(edges, 1)
        if length(global_edges) > length(edges[i])
            dups[i] = intersect(global_edges, edges[i])
        else
            dups[i] = intersect(edges[i], global_edges)
        end
    end
    append!(recycle, dups...)
    setdiff!(global_edges, dups...)
    dups = Nothing
    @debug "dups2 are $(recycle)"
    last_recycle = length(recycle)
    recycle_counter = last_recycle
    while !isempty(recycle)
        recycle_counter -= 1
        if recycle_counter < 0
            if length(recycle) < last_recycle
                last_recycle = length(recycle)
                recycle_counter = last_recycle
            else
                break
            end
        end
        p1 = pop!(recycle)
        from_recycle = 2 * length(recycle) / length(stubs)
        p2 = if rand() < from_recycle
            i = rand(axes(recycle, 1))
            recycle[i], recycle[end] = recycle[end], recycle[i]
            pop!(recycle)
        else
            x = rand(global_edges)
            pop!(global_edges, x)
        end
        if rand() < 0.5
            newp1 = minmax(p1[1], p2[1])
            newp2 = minmax(p1[2], p2[2])
        else
            newp1 = minmax(p1[1], p2[2])
            newp2 = minmax(p1[2], p2[1])
        end
        for newp in (newp1, newp2)
            if (newp[1] == newp[2]) || (newp in global_edges) || any(cluster->newp in cluster, edges)
                push!(recycle, newp)
            else
                push!(global_edges, newp)
            end
        end
    end
    push!(edges, global_edges)
    if isempty(recycle)
        @debug "$(length(global_edges)) global_edges $(length(stubs)) stubs"
        @assert length(global_edges) == length(stubs)/2 + unresolved_collisions
    else
        @debug "dups3 are $(recycle)"
        last_recycle = length(recycle)
        recycle_counter = last_recycle
        cw = Weights([length(c) for c in edges])
        while !isempty(recycle)
            recycle_counter -= 1
            if recycle_counter < 0
                if length(recycle) < last_recycle
                    last_recycle = length(recycle)
                    recycle_counter = last_recycle
                else
                    break
                end
            end
            p1 = pop!(recycle)
            local cluster = sample(edges, cw)
            x = rand(cluster)
            p2 = pop!(cluster, x)
            if rand() < 0.5
                newp1 = minmax(p1[1], p2[1])
                newp2 = minmax(p1[2], p2[2])
            else
                newp1 = minmax(p1[1], p2[2])
                newp2 = minmax(p1[2], p2[1])
            end
            for newp in (newp1, newp2)
                if (newp[1] == newp[2]) || any(c->newp in c, edges)
                    push!(recycle, newp)
                else
                    push!(global_edges, newp)
                end
            end
        end
        if !isempty(recycle)
            unresolved_collisions = length(recycle)
            @warn "Very hard graph! Failed to generate $(unresolved_collisions) edges; fraction: $(2 * unresolved_collisions / total_weight)"
        end
    end
    return ChainedVector([edgeset.dict.keys[edgeset.dict.slots.==0x1] for edgeset in edges])
end

"""
    gen_graph(params::ABCDParams)

Generate ABCD graph following parameters specified in `params`.

Return a named tuple containing a set of edges of the graph and a list of cluster
assignments of the vertices.
The ordering of vertices and clusters is in descending order (as in `params`).
"""
function gen_graph(params::ABCDParams)
    clusters = populate_clusters(params)
    edges = params.isCL ? CL_model(clusters, params) : config_model(clusters, params)
    (edges=edges, clusters=clusters)
end
