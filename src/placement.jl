struct SocketTopology
    id::Int
    cpu_set::Vector{Int}
end

struct NumaTopology
    id::Int
    cpu_set::Vector{Int}
    socket::Union{Int,Nothing}
end

struct MachineTopology
    physical_cores::Int
    logical_cpus::Vector{Int}
    sockets::Vector{SocketTopology}
    numa_nodes::Vector{NumaTopology}
    hyperthreading::Bool
end

struct WorkerPlacement
    localid::Int
    cpu_set::Vector{Int}
    numa_node::Union{Int,Nothing}
    socket::Union{Int,Nothing}
    julia_threads::Int
    julia_interactive_threads::Int
    omp_threads::Int
end

function cpu_set_string(cpu_set::Vector{Int})
    isempty(cpu_set) && return ""

    ranges = String[]
    first_cpu = last_cpu = first(cpu_set)
    for cpu in cpu_set[2:end]
        if cpu == last_cpu + 1
            last_cpu = cpu
        else
            push!(ranges, first_cpu == last_cpu ? string(first_cpu) : "$first_cpu-$last_cpu")
            first_cpu = last_cpu = cpu
        end
    end
    push!(ranges, first_cpu == last_cpu ? string(first_cpu) : "$first_cpu-$last_cpu")
    join(ranges, ",")
end

function julia_threads_string(placement::WorkerPlacement)
    if placement.julia_interactive_threads > 0
        return "$(placement.julia_threads),$(placement.julia_interactive_threads)"
    end
    string(placement.julia_threads)
end

function worker_placement_metadata(
        topology::MachineTopology,
        placement::WorkerPlacement,
        worker_per_vm::Int)
    Dict(
        "localid" => placement.localid,
        "worker_per_vm" => worker_per_vm,
        "physical_cores" => topology.physical_cores,
        "julia_threads" => placement.julia_threads,
        "julia_interactive_threads" => placement.julia_interactive_threads,
        "omp_threads" => placement.omp_threads,
        "cpu_set" => cpu_set_string(placement.cpu_set),
        "numa_node" => placement.numa_node,
        "socket" => placement.socket,
        "pinning_backend" => "numactl")
end

function sorted_unique_cpus(cpu_sets)
    sort!(collect(union((Set(cpu_set) for cpu_set in cpu_sets)...)))
end

function split_evenly(cpu_set::Vector{Int}, count::Int)
    count > 0 || throw(ArgumentError("count must be positive"))
    length(cpu_set) >= count || throw(ArgumentError("count cannot exceed CPU count"))

    base_size = div(length(cpu_set), count)
    remainder = rem(length(cpu_set), count)
    chunks = Vector{Int}[]
    first_index = 1

    for index in 1:count
        chunk_size = base_size + (index <= remainder ? 1 : 0)
        last_index = first_index + chunk_size - 1
        push!(chunks, cpu_set[first_index:last_index])
        first_index = last_index + 1
    end

    chunks
end

function domain_for_cpu_set(cpu_set::Vector{Int}, domains)
    cpu_values = Set(cpu_set)
    for domain in domains
        if issubset(cpu_values, Set(domain.cpu_set))
            return domain.id
        end
    end
    nothing
end

function spread_domain_indices(ndomains::Int, count::Int)
    [floor(Int, (index - 1) * ndomains / count) + 1 for index in 1:count]
end

function placement_from_cpu_set(
        localid::Int,
        topology::MachineTopology,
        cpu_set::Vector{Int})
    sorted_cpu_set = sort(cpu_set)
    thread_count = length(sorted_cpu_set)
    interactive_threads = VERSION >= v"1.9" ? 1 : 0
    numa_node = domain_for_cpu_set(sorted_cpu_set, topology.numa_nodes)
    socket = domain_for_cpu_set(sorted_cpu_set, topology.sockets)

    WorkerPlacement(
        localid,
        sorted_cpu_set,
        numa_node,
        socket,
        thread_count,
        interactive_threads,
        thread_count)
end

function plan_worker_placements(topology::MachineTopology, worker_per_vm::Int)
    worker_per_vm > 0 || throw(ArgumentError("worker_per_vm must be positive"))
    if worker_per_vm > topology.physical_cores
        throw(ArgumentError("worker_per_vm cannot exceed physical cores"))
    end

    if worker_per_vm == 1
        cpu_set = sorted_unique_cpus([topology.logical_cpus])
        return [placement_from_cpu_set(1, topology, cpu_set)]
    end

    if worker_per_vm == length(topology.sockets) && !isempty(topology.sockets)
        return [
            placement_from_cpu_set(index, topology, topology.sockets[index].cpu_set)
            for index in 1:worker_per_vm
        ]
    end

    if worker_per_vm <= length(topology.numa_nodes) && !isempty(topology.numa_nodes)
        node_indices = worker_per_vm == length(topology.numa_nodes) ?
            collect(1:worker_per_vm) :
            spread_domain_indices(length(topology.numa_nodes), worker_per_vm)

        return [
            placement_from_cpu_set(index, topology, topology.numa_nodes[node_index].cpu_set)
            for (index, node_index) in enumerate(node_indices)
        ]
    end

    cpu_set = if !isempty(topology.numa_nodes)
        sorted_unique_cpus([node.cpu_set for node in topology.numa_nodes])
    else
        sorted_unique_cpus([topology.logical_cpus])
    end
    chunks = split_evenly(cpu_set, worker_per_vm)

    [
        placement_from_cpu_set(index, topology, chunk)
        for (index, chunk) in enumerate(chunks)
    ]
end

function numactl_arguments(placement::WorkerPlacement)
    args = ["--physcpubind=$(cpu_set_string(placement.cpu_set))"]
    if placement.numa_node !== nothing
        push!(args, "--membind=$(placement.numa_node)")
    end
    args
end

function placement_environment(placement::WorkerPlacement)
    Dict(
        "JULIA_NUM_THREADS" => julia_threads_string(placement),
        "OMP_NUM_THREADS" => string(placement.omp_threads),
        "OMP_PROC_BIND" => "close",
        "OMP_PLACES" => "cores")
end
