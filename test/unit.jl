using AzManagers, HTTP, JSON, Pkg, Test

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

function synthetic_lscpu_json()
    JSON.json(Dict("lscpu" => [
        Dict("field" => "CPU(s):", "data" => "16"),
        Dict("field" => "On-line CPU(s) list:", "data" => "0-15"),
        Dict("field" => "Thread(s) per core:", "data" => "2"),
        Dict("field" => "Core(s) per socket:", "data" => "4"),
        Dict("field" => "Socket(s):", "data" => "2"),
        Dict("field" => "NUMA node0 CPU(s):", "data" => "0-3,8-11"),
        Dict("field" => "NUMA node1 CPU(s):", "data" => "4-7,12-15")]))
end

function uneven_topology()
    sockets = [SocketTopology(0, collect(0:9))]
    numa_nodes = [NumaTopology(0, collect(0:9), 0)]

    MachineTopology(10, collect(0:9), sockets, numa_nodes, false)
end

@testset "unit: Azure URL helpers" begin
    expected_url = "https://management.azure.com/subscriptions/sub/" *
        "providers/Microsoft.Compute/locations/eastus/usages?api-version=2019-07-01"

    @test AzManagers.azure_compute_usages_url("sub", "eastus") == expected_url
end

@testset "unit: Azure API helpers" begin
    response = HTTP.Response(
        429,
        ["x-ms-ratelimit-remaining-resource" => "quota"],
        "")
    error = HTTP.StatusError(429, "GET", "/target", response)

    @test AzManagers.isretryable(error)
    @test AzManagers.status(error) == 429
    @test AzManagers.remaining_resource(response) == "quota"
    @test !AzManagers.isretryable(ArgumentError("no retry"))
end

@testset "unit: mocked Azure pagination" begin
    nextlink_responses = Dict(
        "page-2" => HTTP.Response(
            200,
            JSON.json(Dict("value" => [2], "nextLink" => "page-3"))),
        "page-3" => HTTP.Response(
            200,
            JSON.json(Dict("value" => [3]))))
    nextlink_requests = String[]
    nextlink_request = function (url)
        push!(nextlink_requests, url)
        nextlink_responses[url]
    end

    values, last_response = AzManagers.collect_nextlink_pages!(
        nextlink_request,
        [1],
        "page-2")

    @test values == [1, 2, 3]
    @test nextlink_requests == ["page-2", "page-3"]
    @test JSON.parse(String(last_response.body))["value"] == [3]

    resourcegraph_responses = [
        HTTP.Response(
            200,
            JSON.json(Dict("data" => ["vm-1"], "\$skipToken" => "next"))),
        HTTP.Response(
            200,
            JSON.json(Dict("data" => ["vm-2"])))]
    resourcegraph_bodies = Dict[]
    resourcegraph_request = function (body)
        push!(resourcegraph_bodies, copy(body))
        popfirst!(resourcegraph_responses)
    end

    data, _ = AzManagers.collect_resourcegraph_pages(
        resourcegraph_request,
        Dict("query" => "Resources"))

    @test data == ["vm-1", "vm-2"]
    @test !haskey(resourcegraph_bodies[1], "\$skipToken")
    @test resourcegraph_bodies[2]["\$skipToken"] == "next"
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

    @test_logs (:warn, "CPU cores do not divide evenly across workers") begin
        uneven_workers = plan_worker_placements(uneven_topology(), 4)
        @test length.(getfield.(uneven_workers, :cpu_set)) == [3, 3, 2, 2]
    end

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

    json_topology = AzManagers.parse_lscpu_json_topology(synthetic_lscpu_json())
    @test json_topology.physical_cores == 8
    @test json_topology.hyperthreading
    @test getfield.(json_topology.sockets, :cpu_set) ==
        [collect(0:3), collect(4:7)]
    @test getfield.(json_topology.numa_nodes, :cpu_set) ==
        [collect(0:3), collect(4:7)]
end

@testset "unit: worker_per_vm alias" begin
    @test AzManagers.resolve_worker_per_vm(4, nothing) == 4
    @test AzManagers.resolve_worker_per_vm(1, 4) == 4
    @test AzManagers.resolve_worker_per_vm(4, 4) == 4
    @test_throws ArgumentError AzManagers.resolve_worker_per_vm(2, 4)
    @test isnothing(AzManagers.validate_worker_per_vm_options(4, 0))
    @test isnothing(AzManagers.validate_worker_per_vm_options(1, 2))
    @test_throws ArgumentError AzManagers.validate_worker_per_vm_options(2, 1)
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
    thread_metadata = AzManagers.worker_placement_metadata(
        topology,
        placement,
        4;
        pinning_backend = "ThreadPinning")
    @test thread_metadata["pinning_backend"] == "ThreadPinning"
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

@testset "unit: environment compression round trip" begin
    mktempdir() do environment_dir
        write(joinpath(environment_dir, "Project.toml"), "[deps]\n")
        write(joinpath(environment_dir, "Manifest.toml"), "# manifest\n")
        write(joinpath(environment_dir, "LocalPreferences.toml"), "flag = true\n")

        project, manifest, preferences =
            AzManagers.compress_environment(environment_dir)

        mktempdir() do depot_dir
            old_depot_path = copy(DEPOT_PATH)
            try
                empty!(DEPOT_PATH)
                push!(DEPOT_PATH, depot_dir)

                AzManagers.decompress_environment(
                    project,
                    manifest,
                    preferences,
                    "azmanagers-unit")

                remote_dir = joinpath(Pkg.envdir(), "azmanagers-unit")
                @test read(joinpath(remote_dir, "Project.toml"), String) ==
                    "[deps]\n"
                @test read(joinpath(remote_dir, "Manifest.toml"), String) ==
                    "# manifest\n"
                @test read(
                    joinpath(remote_dir, "LocalPreferences.toml"),
                    String) == "flag = true\n"
            finally
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, old_depot_path)
            end
        end
    end
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
        AzManagers.DETACHED_JOBS["unit"] = Dict{String,Any}(
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

@testset "unit: pin_julia_threads fallback without ThreadPinning" begin
    @test AzManagers._pin_julia_threads_impl(Int[]) == false
    @test AzManagers._pin_julia_threads_impl([0, 1]) == false
    @test AzManagers.pin_julia_threads(Int[]) == false
    @test AzManagers.pin_julia_threads([0, 1, 2]) == false
end
