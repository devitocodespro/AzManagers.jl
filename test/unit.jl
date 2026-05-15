using AzManagers, HTTP, JSON, Test

function synthetic_topology()
    sockets = [
        SocketTopology(0, collect(0:7)),
        SocketTopology(1, collect(8:15))]
    numa_nodes = [
        NumaTopology(0, collect(0:3), 0),
        NumaTopology(1, collect(4:7), 0),
        NumaTopology(2, collect(8:11), 1),
        NumaTopology(3, collect(12:15), 1)]

    MachineTopology(16, collect(0:15), sockets, numa_nodes, false)
end

function synthetic_lscpu()
    """
    # CPU,Core,Socket,Node
    0,0,0,0
    1,1,0,0
    2,2,0,1
    3,3,0,1
    4,0,0,0
    5,1,0,0
    6,2,0,1
    7,3,0,1
    """
end

@testset "unit: Azure URL helpers" begin
    expected_url = "https://management.azure.com/subscriptions/sub/" *
        "providers/Microsoft.Compute/locations/eastus/usages?api-version=2019-07-01"

    @test AzManagers.azure_compute_usages_url("sub", "eastus") == expected_url
end

@testset "unit: automatic worker placement" begin
    topology = synthetic_topology()

    one_worker = plan_worker_placements(topology, 1)
    @test length(one_worker) == 1
    @test one_worker[1].cpu_set == collect(0:15)
    @test one_worker[1].julia_threads == 16

    socket_workers = plan_worker_placements(topology, 2)
    @test getfield.(socket_workers, :socket) == [0, 1]
    @test getfield.(socket_workers, :cpu_set) == [collect(0:7), collect(8:15)]

    numa_workers = plan_worker_placements(topology, 4)
    @test getfield.(numa_workers, :numa_node) == [0, 1, 2, 3]
    @test all(worker -> worker.julia_threads == 4, numa_workers)

    split_workers = plan_worker_placements(topology, 8)
    @test length(split_workers) == 8
    @test getfield.(split_workers, :cpu_set)[1] == [0, 1]
    @test getfield.(split_workers, :cpu_set)[end] == [14, 15]

    @test_throws ArgumentError plan_worker_placements(topology, 17)
end

@testset "unit: lscpu topology parsing" begin
    topology = AzManagers.parse_lscpu_topology(synthetic_lscpu())

    @test topology.physical_cores == 4
    @test topology.logical_cpus == collect(0:3)
    @test topology.hyperthreading
    @test getfield.(topology.numa_nodes, :id) == [0, 1]
    @test getfield.(topology.numa_nodes, :cpu_set) ==
        [collect(0:1), collect(2:3)]
end

@testset "unit: worker_per_vm alias" begin
    @test AzManagers.resolve_worker_per_vm(4, nothing) == 4
    @test AzManagers.resolve_worker_per_vm(1, 4) == 4
    @test AzManagers.resolve_worker_per_vm(4, 4) == 4
    @test_throws ArgumentError AzManagers.resolve_worker_per_vm(2, 4)
end

@testset "unit: placement launch details" begin
    topology = synthetic_topology()
    placement = plan_worker_placements(topology, 4)[2]

    @test AzManagers.cpu_set_string([0, 1, 2, 4, 5, 8]) == "0-2,4-5,8"
    @test AzManagers.julia_threads_string(placement) == "4,1"
    @test AzManagers.numactl_arguments(placement) ==
        ["--physcpubind=4-7", "--membind=1"]

    env = AzManagers.placement_environment(placement)
    @test env["JULIA_NUM_THREADS"] == "4,1"
    @test env["OMP_NUM_THREADS"] == "4"
    @test env["OMP_PROC_BIND"] == "close"
    @test env["OMP_PLACES"] == "cores"

    metadata = AzManagers.worker_placement_metadata(topology, placement, 4)
    @test metadata["worker_per_vm"] == 4
    @test metadata["cpu_set"] == "4-7"
    @test metadata["pinning_backend"] == "numactl"
    @test AzManagers.placement_userdata(metadata) == metadata
    @test AzManagers.numactl_prefix(placement) ==
        "numactl --physcpubind=4-7 --membind=1 "
    @test AzManagers.worker_launch_command(
        "julia",
        ``,
        placement;
        use_numactl = true) ==
            `numactl --physcpubind=4-7 --membind=1 julia -t 4,1 --worker`
end

@testset "unit: shell environment rendering" begin
    rendered = AzManagers.build_envstring(
        Dict("FOO" => "bar baz", "QUOTE" => "a'b"))

    @test contains(rendered, "export FOO='bar baz'")
    @test contains(rendered, "export QUOTE='a'\"'\"'b'")
    @test_throws ArgumentError AzManagers.build_envstring(Dict("1BAD" => "value"))

    placement = plan_worker_placements(synthetic_topology(), 4)[1]
    placement_exports = AzManagers.placement_export_string(placement)
    @test contains(placement_exports, "export JULIA_NUM_THREADS='4,1'")
    @test contains(placement_exports, "export OMP_PROC_BIND='close'")
end

@testset "unit: VM template resource IDs" begin
    template = AzManagers.build_vmtemplate(
        "vm-name";
        subscriptionid = "sub",
        admin_username = "user",
        location = "eastus",
        resourcegroup = "rg",
        resourcegroup_vnet = "network-rg",
        imagegallery = "gallery",
        imagename = "image",
        vmsize = "Standard_D2s_v5")

    network_interfaces =
        template["value"]["properties"]["networkProfile"]["networkInterfaces"]
    nic_id = network_interfaces[1]["id"]

    @test startswith(nic_id, "/subscriptions/sub/")
    @test contains(nic_id, "/resourceGroups/network-rg/")
end

@testset "unit: detached wait error response" begin
    try
        AzManagers.DETACHED_JOBS["unit"] = Dict(
            "process" => "not-a-process",
            "codefile" => "unit-code.jl",
            "code" => "error(\"boom\")")

        request = HTTP.Request("POST", "/cofii/detached/job/unit/wait")
        response = AzManagers.detachedwait(request)
        body = JSON.parse(String(response.body))

        @test response.status == 400
        @test haskey(body, "error")
        @test contains(body["error"], "Code listing")
    finally
        delete!(AzManagers.DETACHED_JOBS, "unit")
    end
end
