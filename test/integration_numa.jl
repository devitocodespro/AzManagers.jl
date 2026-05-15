using AzManagers, Distributed, Test

if get(ENV, "AZMANAGERS_RUN_NUMA_INTEGRATION", "false") == "true"
    @testset "integration: NUMA worker placement" begin
        template = get(ENV, "AZMANAGERS_NUMA_TEMPLATE", "")
        isempty(template) && error("AZMANAGERS_NUMA_TEMPLATE must be set")

        worker_per_vm = parse(Int, get(ENV, "AZMANAGERS_NUMA_WORKER_PER_VM", "2"))
        addprocs(template, 1; waitfor=true, worker_per_vm)

        try
            placements = worker_placements()
            @test length(placements) == worker_per_vm

            cpu_sets = get.(values(placements), "cpu_set", "")
            numa_nodes = get.(values(placements), "numa_node", nothing)
            sockets = get.(values(placements), "socket", nothing)

            @test all(!isempty, cpu_sets)
            @test length(unique(cpu_sets)) == worker_per_vm
            @test all(node -> node !== nothing, numa_nodes)
            @test all(socket -> socket !== nothing, sockets)

            affinities = Dict(pid => remotecall_fetch(pid) do
                read(`taskset -pc $(getpid())`, String)
            end for pid in workers())

            @test all(!isempty, values(affinities))
        finally
            rmprocs(workers())
        end
    end
end

