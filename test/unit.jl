using AzManagers, HTTP, JSON, Test

@testset "unit: Azure URL helpers" begin
    expected_url = "https://management.azure.com/subscriptions/sub/" *
        "providers/Microsoft.Compute/locations/eastus/usages?api-version=2019-07-01"

    @test AzManagers.azure_compute_usages_url("sub", "eastus") == expected_url
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
