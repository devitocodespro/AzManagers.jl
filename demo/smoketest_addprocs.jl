#=
End-to-end smoke test for AzManagers.addprocs against a real Azure subscription.
This script is **not** part of the CI matrix. Run it manually from a workstation
or a small "controller" VM to verify that:

  - templates render correctly
  - a scale set is created
  - Julia workers register with the master
  - automatic worker_per_vm placement (cpu_set / numa_node / socket / pinning_backend)
    matches the SKU you provisioned
  - optional MPI nested launch (worker_per_vm > 1 AND mpi_ranks_per_worker > 0)
  - the scale set is torn down at the end

Each smoke section is gated by an env var. Set only the ones you want to run.

================================================================================
PREREQUISITES (host running this script)
================================================================================

  - Julia 1.9 or newer (package extensions ship with 1.9+)
  - This repo cloned and activated: `julia --project=. demo/smoketest_addprocs.jl`
  - AzSessions installed; AzManagers will be loaded from the project
  - Network access to https://management.azure.com and the worker subnet

================================================================================
AZURE RESOURCES YOU MUST HAVE
================================================================================

  1. An Azure subscription you can deploy to.
  2. A resource group in your chosen region.
  3. A VNet + subnet in that resource group. The workers will get NICs on this
     subnet, and the host running this script must be able to reach them on the
     Julia worker port (default ephemeral; see JULIA_WORKER_TIMEOUT).
  4. A Shared Image Gallery, image definition, and at least one image version
     containing:
       * Julia (matching the version flag in your `exename`)
       * AzManagers checked out and precompiled, OR `customenv=true` so the
         current project is shipped to the workers (slower bootstrap)
       * For MPI tests: an Open MPI build whose mpirun accepts
         `--cpu-set <cpu-list> --bind-to cpu-list:ordered`
       * `numactl` and `lscpu` (already present on most Ubuntu/RHEL images)
     If you don't have an image yet, the Packer file at test/image.pkr.hcl is a
     starting point.
  5. A service principal (client_id + client_secret + tenant) with Contributor
     on the resource group, OR a managed identity if you're running on Azure.

================================================================================
ENV VARS REQUIRED
================================================================================

  SUBSCRIPTION_ID  — Azure subscription GUID
  RESOURCE_GROUP   — resource group name for scale sets
  TENANT_ID        — AAD tenant GUID
  CLIENT_ID        — service principal app id
  CLIENT_SECRET    — service principal secret
  VNET_NAME        — VNet hosting the worker subnet
  SUBNET_NAME      — subnet for worker NICs
  GALLERY_NAME     — shared image gallery name
  IMAGE_NAME       — image definition name inside the gallery
  LOCATION         — e.g. "southcentralus" (default if unset)
  SKU_NAME         — VM SKU for the scale set, e.g. "Standard_D4s_v5"
                     (a single-NUMA SKU is fine for the basic smoke; pick a
                     multi-NUMA SKU like Standard_HB176rs_v4 for placement
                     verification)
  SSH_USER         — admin user baked into the image (typically "cvx")

ENV VARS THAT GATE EACH SCENARIO

  SMOKE_BASIC=1           — provision N=1 VM, ppi=1, verify connectivity
  SMOKE_PLACEMENT=1       — provision N=1 VM, worker_per_vm=2, verify cpu_set /
                            numa_node / socket / taskset on each worker
  SMOKE_MPI_NESTED=1      — provision N=1 VM, worker_per_vm=2,
                            mpi_ranks_per_worker=2 → 4 ranks total via two
                            parallel mpirun groups
  SMOKE_WORKER_PER_VM     — integer override for placement test (default 2)
  SMOKE_MPI_RANKS         — integer override for MPI ranks per worker (default 2)
  SMOKE_KEEP=1            — skip rmprocs at the end (so you can ssh in and poke
                            around; you'll need to delete the scale set yourself)

================================================================================
RUN IT
================================================================================

  cd ~/.julia/dev/AzManagers
  julia --project=. demo/smoketest_addprocs.jl

You'll see logs like:

  [ Info: writing templates for sku=Standard_HB176rs_v4
  [ Info: addprocs(smoke; n=1, worker_per_vm=2) ...
  [ Info: worker 2: cpu_set=0-87 numa_node=0 socket=0 pinning_backend=numactl
  [ Info: worker 3: cpu_set=88-175 numa_node=1 socket=0 pinning_backend=numactl
  [ Info: taskset -pc 12345: pid 12345's current affinity list: 0-87
  [ Info: rmprocs done

================================================================================
HOW TO CLEAN UP IF SOMETHING WEDGES
================================================================================

  az vmss list -g $RESOURCE_GROUP --query "[?starts_with(name,'smoke')].name" -o tsv \
      | xargs -I {} az vmss delete -g $RESOURCE_GROUP -n {}

=#

using Distributed, AzManagers, AzSessions, Random, Test, HTTP, JSON

const TEMPLATE_NAME = "smoke" * randstring('a':'z', 4)

function _env(name; default = nothing)
    value = get(ENV, name, default)
    value === nothing && error("missing required env var: $name")
    value
end

function _bool(name)
    get(ENV, name, "0") in ("1", "true", "TRUE", "yes")
end

function build_smoke_templates()
    subscriptionid = _env("SUBSCRIPTION_ID")
    resourcegroup  = _env("RESOURCE_GROUP")
    tenant_id      = _env("TENANT_ID")
    client_id      = _env("CLIENT_ID")
    client_secret  = _env("CLIENT_SECRET")
    vnet           = _env("VNET_NAME")
    subnet         = _env("SUBNET_NAME")
    gallery        = _env("GALLERY_NAME")
    imagename      = _env("IMAGE_NAME")
    location       = _env("LOCATION";  default = "southcentralus")
    sku            = _env("SKU_NAME";  default = "Standard_D4s_v5")
    ssh_user       = _env("SSH_USER";  default = "cvx")

    @info "writing templates for sku=$sku location=$location"

    sstemplate = AzManagers.build_sstemplate(
        TEMPLATE_NAME;
        subscriptionid     = subscriptionid,
        admin_username     = ssh_user,
        location           = location,
        resourcegroup      = resourcegroup,
        resourcegroup_vnet = resourcegroup,
        vnet               = vnet,
        subnet             = subnet,
        imagegallery       = gallery,
        imagename          = imagename,
        skuname            = sku)

    nictemplate = AzManagers.build_nictemplate(
        TEMPLATE_NAME;
        accelerated        = false,
        subscriptionid     = subscriptionid,
        location           = location,
        resourcegroup_vnet = resourcegroup,
        vnet               = vnet,
        subnet             = subnet)

    AzManagers.save_template_scaleset(TEMPLATE_NAME, sstemplate)
    AzManagers.save_template_nic(TEMPLATE_NAME, nictemplate)

    AzSessions.write_manifest(;
        client_id     = client_id,
        client_secret = client_secret,
        tenant        = tenant_id)
    AzManagers.write_manifest(;
        resourcegroup  = resourcegroup,
        subscriptionid = subscriptionid,
        ssh_user       = ssh_user)

    AzSession(; protocal = AzClientCredentials)
end

function dump_worker_placements()
    placements = worker_placements()
    for pid in sort(collect(keys(placements)))
        info = placements[pid]
        cpu_set  = get(info, "cpu_set", "?")
        numa     = get(info, "numa_node", "?")
        socket   = get(info, "socket", "?")
        backend  = get(info, "pinning_backend", "?")
        threads  = get(info, "julia_threads", "?")
        @info "worker $pid: cpu_set=$cpu_set numa_node=$numa socket=$socket julia_threads=$threads backend=$backend"
    end
    placements
end

function assert_taskset_matches(placements)
    for pid in workers()
        info = get(placements, pid, Dict())
        expected = get(info, "cpu_set", "")
        affinity = remotecall_fetch(pid) do
            try
                strip(read(`taskset -pc $(getpid())`, String))
            catch e
                "taskset failed: $e"
            end
        end
        @info "taskset for pid $pid expected=$expected got=$affinity"
    end
end

function teardown(group)
    if _bool("SMOKE_KEEP")
        @warn "SMOKE_KEEP=1; leaving workers + scale set '$group' running"
        return
    end
    isempty(workers()) || rmprocs(workers())
    try
        AzManagers.rmgroup(group)
    catch e
        @warn "rmgroup($group) failed; check scale set manually" exception=e
    end
    @info "teardown complete for scale set $group"
end

function smoke_basic(session)
    group = "smoke-basic-" * randstring('a':'z', 4)
    @info "addprocs basic: group=$group n=1 ppi=1"
    addprocs(AzManager(), TEMPLATE_NAME, 1; waitfor = true, ppi = 1, group, session)
    try
        @assert nworkers() == 1
        hostname = remotecall_fetch(gethostname, first(workers()))
        @info "basic worker hostname=$hostname"
    finally
        teardown(group)
    end
end

function smoke_placement(session)
    group = "smoke-place-" * randstring('a':'z', 4)
    worker_per_vm = parse(Int, get(ENV, "SMOKE_WORKER_PER_VM", "2"))
    @info "addprocs placement: group=$group n=1 worker_per_vm=$worker_per_vm"
    addprocs(AzManager(), TEMPLATE_NAME, 1;
        waitfor       = true,
        worker_per_vm = worker_per_vm,
        group,
        session)
    try
        @assert nworkers() == worker_per_vm
        placements = dump_worker_placements()
        cpu_sets = [get(p, "cpu_set", "") for p in values(placements)]
        @assert all(!isempty, cpu_sets) "some workers reported empty cpu_set"
        @assert length(unique(cpu_sets)) == worker_per_vm "cpu_sets are not disjoint: $cpu_sets"
        assert_taskset_matches(placements)
    finally
        teardown(group)
    end
end

function smoke_mpi_nested(session)
    group                 = "smoke-mpi-" * randstring('a':'z', 4)
    worker_per_vm         = parse(Int, get(ENV, "SMOKE_WORKER_PER_VM", "2"))
    mpi_ranks_per_worker  = parse(Int, get(ENV, "SMOKE_MPI_RANKS", "2"))
    @info "addprocs MPI nested: group=$group worker_per_vm=$worker_per_vm mpi_ranks_per_worker=$mpi_ranks_per_worker"
    # `mpi_flags=""` so the auto-emitted `--bind-to cpu-list:ordered` is not
    # overridden. If your image needs explicit --map-by or extra flags, set
    # SMOKE_MPI_FLAGS and they will be appended verbatim.
    mpi_flags = get(ENV, "SMOKE_MPI_FLAGS", "")
    addprocs(AzManager(), TEMPLATE_NAME, 1;
        waitfor              = true,
        worker_per_vm        = worker_per_vm,
        mpi_ranks_per_worker = mpi_ranks_per_worker,
        mpi_flags            = mpi_flags,
        group,
        session)
    try
        @assert nworkers() == worker_per_vm "expected $worker_per_vm julia workers, got $(nworkers())"
        for pid in workers()
            rank_count = remotecall_fetch(pid) do
                try
                    Base.invokelatest(eval, :(using MPI; MPI.Comm_size(MPI.COMM_WORLD)))
                catch e
                    "MPI introspection failed: $e"
                end
            end
            @info "worker $pid MPI.Comm_size=$rank_count"
        end
        dump_worker_placements()
    finally
        teardown(group)
    end
end

function main()
    session = build_smoke_templates()
    any_run = false
    if _bool("SMOKE_BASIC");      any_run = true; smoke_basic(session); end
    if _bool("SMOKE_PLACEMENT");  any_run = true; smoke_placement(session); end
    if _bool("SMOKE_MPI_NESTED"); any_run = true; smoke_mpi_nested(session); end
    any_run ||
        @warn "no SMOKE_* gate enabled; set SMOKE_BASIC=1, SMOKE_PLACEMENT=1, or SMOKE_MPI_NESTED=1"
end

main()
