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

function parse_cpu_list(value::AbstractString)
    cpus = Int[]
    for part in split(value, ',')
        cpu_range = split(strip(part), '-')
        if length(cpu_range) == 1
            push!(cpus, parse(Int, cpu_range[1]))
        elseif length(cpu_range) == 2
            append!(cpus, parse(Int, cpu_range[1]):parse(Int, cpu_range[2]))
        else
            throw(ArgumentError("invalid CPU list: $value"))
        end
    end
    sort(unique(cpus))
end

function parse_lscpu_json_topology(text::AbstractString)
    data = JSON.parse(text)
    fields = Dict{String,String}()
    for entry in get(data, "lscpu", [])
        key = replace(get(entry, "field", ""), r":$" => "")
        fields[key] = get(entry, "data", "")
    end

    sockets_count = parse(Int, fields["Socket(s)"])
    cores_per_socket = parse(Int, fields["Core(s) per socket"])
    threads_per_core = parse(Int, get(fields, "Thread(s) per core", "1"))
    physical_cores = sockets_count * cores_per_socket
    logical_cpus = if haskey(fields, "On-line CPU(s) list")
        parse_cpu_list(fields["On-line CPU(s) list"])
    else
        collect(0:(parse(Int, fields["CPU(s)"]) - 1))
    end

    physical_cpus = logical_cpus[1:physical_cores]
    sockets = SocketTopology[]
    for socket in 0:(sockets_count - 1)
        first_index = socket * cores_per_socket + 1
        last_index = first_index + cores_per_socket - 1
        push!(sockets, SocketTopology(socket, physical_cpus[first_index:last_index]))
    end

    numa_nodes = NumaTopology[]
    for (key, value) in sort(collect(fields); by=first)
        match_result = match(r"^NUMA node([0-9]+) CPU\(s\)$", key)
        match_result === nothing && continue

        node_id = parse(Int, match_result.captures[1])
        cpu_set = intersect(parse_cpu_list(value), physical_cpus)
        socket = domain_for_cpu_set(cpu_set, sockets)
        push!(numa_nodes, NumaTopology(node_id, cpu_set, socket))
    end

    if isempty(numa_nodes)
        numa_nodes = [
            NumaTopology(socket.id, socket.cpu_set, socket.id)
            for socket in sockets
        ]
    end

    MachineTopology(
        physical_cores,
        physical_cpus,
        sockets,
        numa_nodes,
        threads_per_core > 1 || length(logical_cpus) > physical_cores)
end

function parse_lscpu_topology(text::AbstractString)
    first_cpu_by_core = Dict{Tuple{Int,Int},Int}()
    socket_by_cpu = Dict{Int,Int}()
    numa_by_cpu = Dict{Int,Int}()
    all_cpus = Int[]

    for raw_line in split(text, '\n')
        line = strip(raw_line)
        (isempty(line) || startswith(line, "#")) && continue

        fields = split(line, ',')
        length(fields) >= 3 || continue

        cpu = parse(Int, fields[1])
        core = parse(Int, fields[2])
        socket = parse(Int, fields[3])
        numa_node = length(fields) >= 4 ? parse(Int, fields[4]) : socket

        push!(all_cpus, cpu)
        key = (socket, core)
        first_cpu_by_core[key] = min(get(first_cpu_by_core, key, cpu), cpu)
        socket_by_cpu[cpu] = socket
        numa_by_cpu[cpu] = numa_node
    end

    physical_cpus = sort(collect(values(first_cpu_by_core)))
    sockets = topology_domains(SocketTopology, physical_cpus, socket_by_cpu)
    numa_nodes = topology_domains(
        NumaTopology,
        physical_cpus,
        numa_by_cpu,
        socket_by_cpu)

    MachineTopology(
        length(physical_cpus),
        physical_cpus,
        sockets,
        numa_nodes,
        length(all_cpus) > length(physical_cpus))
end

function topology_domains(
        ::Type{SocketTopology},
        cpus::Vector{Int},
        socket_by_cpu::Dict{Int,Int})
    by_socket = Dict{Int,Vector{Int}}()
    for cpu in cpus
        socket = socket_by_cpu[cpu]
        push!(get!(by_socket, socket, Int[]), cpu)
    end

    [
        SocketTopology(socket, sort(cpu_set))
        for (socket, cpu_set) in sort(collect(by_socket); by=first)
    ]
end

function topology_domains(
        ::Type{NumaTopology},
        cpus::Vector{Int},
        numa_by_cpu::Dict{Int,Int},
        socket_by_cpu::Dict{Int,Int})
    by_numa = Dict{Int,Vector{Int}}()
    for cpu in cpus
        numa_node = numa_by_cpu[cpu]
        push!(get!(by_numa, numa_node, Int[]), cpu)
    end

    nodes = NumaTopology[]
    for (numa_node, cpu_set) in sort(collect(by_numa); by=first)
        sockets = unique(socket_by_cpu[cpu] for cpu in cpu_set)
        socket = length(sockets) == 1 ? first(sockets) : nothing
        push!(nodes, NumaTopology(numa_node, sort(cpu_set), socket))
    end
    nodes
end

function parse_numactl_topology(text::AbstractString)
    node_cpus = Vector{Pair{Int,Vector{Int}}}()
    for raw_line in split(text, '\n')
        line = strip(raw_line)
        match_result = match(r"^node ([0-9]+) cpus:\s*(.*)$", line)
        match_result === nothing && continue
        node_id = parse(Int, match_result.captures[1])
        cpu_text = strip(String(match_result.captures[2]))
        cpus = isempty(cpu_text) ? Int[] :
            sort(unique(parse.(Int, split(cpu_text))))
        push!(node_cpus, node_id => cpus)
    end

    isempty(node_cpus) &&
        throw(ArgumentError("no NUMA node cpus reported by numactl --hardware"))

    sort!(node_cpus; by=first)
    logical_cpus = sorted_unique_cpus([cpus for (_, cpus) in node_cpus])
    physical_cores = length(logical_cpus)

    sockets = [SocketTopology(id, cpus) for (id, cpus) in node_cpus]
    numa_nodes = [NumaTopology(id, cpus, id) for (id, cpus) in node_cpus]

    MachineTopology(physical_cores, logical_cpus, sockets, numa_nodes, false)
end

function detect_machine_topology()
    try
        return _hwloc_topology()
    catch err
        @debug "Hwloc topology probe unavailable" err
    end

    try
        return parse_lscpu_json_topology(read(`lscpu --json`, String))
    catch err
        @debug "lscpu --json topology probe failed" err
    end

    try
        return parse_numactl_topology(read(`numactl --hardware`, String))
    catch err
        @debug "numactl --hardware topology probe failed" err
    end

    output = try
        read(`lscpu -p=CPU,CORE,SOCKET,NODE`, String)
    catch
        read(`lscpu -p=CPU,CORE,SOCKET`, String)
    end
    parse_lscpu_topology(output)
end

"""
    _hwloc_topology()

Loaded by `HwlocExt` when `Hwloc.jl` is available; without the extension this
function has no methods and `detect_machine_topology` will skip it after
catching the `MethodError`.
"""
function _hwloc_topology end

function resolve_worker_per_vm(ppi::Int, worker_per_vm)
    if worker_per_vm === nothing
        return ppi
    end
    if ppi != 1 && ppi != worker_per_vm
        throw(ArgumentError("ppi and worker_per_vm cannot specify different values"))
    end
    worker_per_vm
end

function validate_worker_per_vm_options(worker_per_vm::Int, mpi_ranks_per_worker::Int)
    if worker_per_vm > 1 && mpi_ranks_per_worker > 0
        throw(ArgumentError(
            "worker_per_vm > 1 with mpi_ranks_per_worker > 0 is not supported yet"))
    end
    nothing
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
        worker_per_vm::Int;
        pinning_backend = "numactl")
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
        "pinning_backend" => pinning_backend)
end

const PLACEMENT_USERDATA_KEYS = Set([
    "localid",
    "worker_per_vm",
    "physical_cores",
    "julia_threads",
    "julia_interactive_threads",
    "omp_threads",
    "cpu_set",
    "numa_node",
    "socket",
    "pinning_backend"])

function placement_userdata(userdata::Dict)
    Dict(key => userdata[key] for key in PLACEMENT_USERDATA_KEYS if haskey(userdata, key))
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
    if rem(length(cpu_set), worker_per_vm) != 0
        @warn "CPU cores do not divide evenly across workers" cpu_count=length(cpu_set) worker_per_vm
    end

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

function numactl_prefix(placement::WorkerPlacement)
    isempty(placement.cpu_set) && return ""
    "numactl " * join(numactl_arguments(placement), " ") * " "
end

function worker_launch_command(
        exename,
        exeflags,
        placement::WorkerPlacement;
        use_numactl::Bool)
    threads = julia_threads_string(placement)
    if use_numactl
        return `numactl $(numactl_arguments(placement)) $exename $exeflags -t $threads --worker`
    end
    `$exename $exeflags -t $threads --worker`
end

function placement_environment(placement::WorkerPlacement)
    Dict(
        "JULIA_NUM_THREADS" => julia_threads_string(placement),
        "OMP_NUM_THREADS" => string(placement.omp_threads),
        "OMP_PROC_BIND" => "close",
        "OMP_PLACES" => "cores")
end

function placement_export_string(placement::WorkerPlacement)
    build_envstring(placement_environment(placement))
end

"""
    pin_julia_threads(cpu_set)

Best-effort pin of the current process' Julia threads to the given physical
CPU IDs. Returns `true` when an integration successfully pinned threads, and
`false` otherwise.

The base package only provides this no-op fallback so that callers can rely
on `numactl` for OS-level pinning. Loading `ThreadPinning.jl` activates the
`ThreadPinningExt` package extension, which replaces this method via
`Base.invokelatest` dispatch on `_pin_julia_threads_impl`.
"""
function pin_julia_threads(cpu_set::Vector{Int})
    try
        Base.invokelatest(_pin_julia_threads_impl, cpu_set)
    catch err
        @debug "thread pinning unavailable; relying on numactl pinning" err
        false
    end
end

_pin_julia_threads_impl(::Any) = false
