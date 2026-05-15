module HwlocExt

using AzManagers, Hwloc

function _node_os_index(node, fallback::Int)
    if hasproperty(node, :os_index)
        return Int(node.os_index)
    elseif hasproperty(node, :logical_index)
        return Int(node.logical_index)
    end
    fallback
end

function _walk_collect_pus!(cpus::Vector{Int}, node)
    if node.type_ == :PU
        push!(cpus, _node_os_index(node, length(cpus)))
    end
    for child in node.children
        _walk_collect_pus!(cpus, child)
    end
    cpus
end

function _collect_cpuset(object)
    cpus = Int[]
    _walk_collect_pus!(cpus, object)
    sort!(unique!(cpus))
end

function _walk_collect_type!(matches::Vector, node, target_type::Symbol)
    if node.type_ == target_type
        push!(matches, node)
    end
    for child in node.children
        _walk_collect_type!(matches, child, target_type)
    end
    matches
end

function _collect_descendants(root, target_type::Symbol)
    _walk_collect_type!(Any[], root, target_type)
end

function AzManagers._hwloc_topology()
    root = Hwloc.topology_load()

    package_objs = _collect_descendants(root, :Package)
    numa_objs = _collect_descendants(root, :NUMANode)
    pu_objs = _collect_descendants(root, :PU)
    core_objs = _collect_descendants(root, :Core)

    isempty(pu_objs) && throw(ErrorException("Hwloc returned no PU objects"))

    logical_cpus = sort(unique(_node_os_index(pu, idx - 1) for (idx, pu) in enumerate(pu_objs)))

    physical_core_count = max(length(core_objs), 1)
    pus_per_core = max(length(pu_objs) ÷ physical_core_count, 1)
    hyperthreading = pus_per_core > 1

    physical_cpus = Int[]
    for core in core_objs
        pus = _collect_cpuset(core)
        isempty(pus) || push!(physical_cpus, first(pus))
    end
    sort!(physical_cpus)
    isempty(physical_cpus) && (physical_cpus = logical_cpus)

    sockets = AzManagers.SocketTopology[]
    for (idx, pkg) in enumerate(package_objs)
        cpu_set = intersect(_collect_cpuset(pkg), physical_cpus)
        push!(sockets,
            AzManagers.SocketTopology(_node_os_index(pkg, idx - 1), cpu_set))
    end
    if isempty(sockets)
        push!(sockets, AzManagers.SocketTopology(0, physical_cpus))
    end

    numa_nodes = AzManagers.NumaTopology[]
    if isempty(numa_objs)
        for socket in sockets
            push!(numa_nodes,
                AzManagers.NumaTopology(socket.id, socket.cpu_set, socket.id))
        end
    else
        for (idx, numa) in enumerate(numa_objs)
            cpu_set = intersect(_collect_cpuset(numa), physical_cpus)
            socket_id = AzManagers.domain_for_cpu_set(cpu_set, sockets)
            push!(numa_nodes,
                AzManagers.NumaTopology(
                    _node_os_index(numa, idx - 1),
                    cpu_set,
                    socket_id))
        end
    end

    AzManagers.MachineTopology(
        length(physical_cpus),
        logical_cpus,
        sockets,
        numa_nodes,
        hyperthreading)
end

end
