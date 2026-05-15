# AzManagers Package Review And Improvement Proposal


## Development guidelines

- For each proposed change, create a separate branch
- Make a new commit for each logical step in the change, with a descriptive message
- Never put yourself as commit author or description.
- Add tests for any new behavior or bug fixes, and ensure all tests pass before merging
- For refactors, try to keep behavior identical in the initial commit, then add improvements in later commits
- Do not put each branch on top of each other. Each branch should be based on the main branch to keep changes isolated and reviewable independently.

## Package Summary

AzManagers is a Julia package for provisioning Azure compute from Julia and
attaching it to Julia workflows.

The package provides:

- `AzManager <: ClusterManager` for `Distributed.addprocs`, backed by Azure VM
  scale sets.
- Dynamic worker registration, where Azure VMs boot, run cloud-init, start
  Julia, then connect back to the master process.
- Scale set lifecycle management, including creation, growth, worker pruning,
  VM deletion, scale set cleanup, quota checks, and retry logic.
- Azure Spot VM support, including scheduled eviction polling and simulated
  eviction tests.
- Detached single-VM execution through `addproc`, `@detach`, and `@detachat`.
- Runtime project/environment transfer to workers when `customenv=true`.
- Template builders for scale sets, VMs, and NICs in `src/templates.jl`.
- Optional MPI support through `ext/MPIExt.jl`, which broadcasts Julia
  `Distributed` messages across MPI ranks inside a worker VM.

The main implementation is concentrated in `src/AzManagers.jl`. It includes
cluster manager logic, Azure REST calls, cloud-init generation, detached
service APIs, cleanup loops, retry logic, NVIDIA/GPU handling, data disk
mounting, and helper APIs. This makes the package powerful, but also makes it
hard to test and evolve safely.

## Test Summary

The current test suite is primarily live Azure integration testing.

Important test files:

- `test/templates.jl`: creates Azure templates and manifests from CI
  environment variables.
- `test/runtests.jl`: provisions real Azure scale sets and VMs, then validates
  behavior.
- `test/image.pkr.hcl`: builds the CI image with Julia, AzManagers, MPI, and
  test dependencies.
- `test/julia-codecov.jl`: writes coverage output.

Covered behaviors include:

- Scale set worker provisioning through `addprocs`.
- Worker count and hostname validation.
- Scale set deletion through `rmprocs`.
- Spot VM startup and thread propagation.
- Spot eviction simulation.
- Custom Julia environment propagation to workers.
- Template tag propagation.
- Detached VM job execution, stdout/stderr capture, status, wait, and cleanup.
- Variable bundling into detached jobs.
- Physical host name metadata.
- `nphysical_cores` for known machine templates.

The tests require Azure credentials, live Azure resources, Packer image
creation, and potentially long-running paid infrastructure. They should remain
as integration tests, but the package also needs fast local unit tests.

## High-Priority Issues

1. Fix the final `nphysical_cores` test.

   `test/runtests.jl` loads `templates_scaleset`, then references
   `templates_vm`, which is undefined.

2. Fix the Azure quota usage URL.

   `quotacheck` builds a usage URL with `locations/$location)/usages`, which
   contains an extra `)`.

3. Fix detached auto-destroy for `persist=false`.

   The detached service calls `sessionbundle(:management)`, but that function
   is not defined in this package. Persist-false detached jobs should delete
   their VM using explicit session information available to AzManagers, or the
   API should require a serialized session bundle in a documented way.

4. Fix detached wait error reporting.

   `detachedwait` references `io` in its catch path without defining it. This
   can hide the original detached job failure behind a secondary error.

5. Fix generated VM template NIC IDs.

   `build_vmtemplate` emits `/subscription/...` instead of `/subscriptions/...`.
   The path may be overwritten later in normal `addproc` flow, but the template
   itself should be valid.

## General Improvement Proposal

### Split Test Tiers

Introduce three test levels:

- Fast unit tests for template generation, URL construction, retry
  classification, thread parsing, environment compression, and startup script
  generation.
- Mocked Azure REST tests using fake HTTP responses or an injectable request
  function.
- Live Azure integration tests behind an explicit CI flag, workflow dispatch,
  or scheduled workflow.

This reduces feedback time and lets most regressions be caught without
provisioning Azure resources.

### Refactor Large Modules

Split `src/AzManagers.jl` into smaller internal files:

- `azure_api.jl`: REST request, retry, pagination, quota, and Azure metadata.
- `cluster_manager.jl`: `AzManager`, worker registration, pruning, cleanup.
- `cloud_init.jl`: startup script generation and shell environment handling.
- `detached.jl`: detached service and client APIs.
- `placement.jl`: worker-per-node topology detection and CPU placement.
- `templates.jl`: existing template builders.

This refactor should be mechanical first. Avoid changing behavior during the
initial split.

### Reduce Hidden Global State

Review these globals:

- `_manifest`
- `_manager`
- `DETACHED_JOBS`
- `DETACHED_VM`
- `VARIABLE_BUNDLE`

Where practical, move state into explicit structs or pass it through function
arguments. This will make behavior easier to test and reduce hidden coupling
between cluster mode, detached mode, and test state.

### Harden Startup Script Generation

Startup script generation currently interpolates values directly into shell
commands. Add helpers that:

- Validate environment variable names.
- Shell-quote environment values.
- Keep generated scripts deterministic enough for snapshot-style tests.
- Separate data construction from string rendering.

## Automatic Multi-Worker Per VM Placement Proposal

### Goal

Improve `worker_per_vm` so users only specify the number of Julia workers per VM, while
AzManagers automatically derives CPU, NUMA, Julia thread, and OpenMP placement.

The user-facing API should remain simple:

```julia
addprocs("cbox176", 2; worker_per_vm=4)
```

This means:

- Provision 2 Azure VMs.
- Start 4 Julia workers per VM.
- Infer topology independently on each VM.
- Pin each worker to an appropriate CPU and NUMA region.
- Configure Julia and OpenMP thread counts consistently.

Users should not need to provide `worker_placement`, `pinning_backend`,
`julia_num_threads`, or `omp_num_threads` for the common case.

### Topology Detection

On VM startup, detect hardware topology before launching local Julia workers.

Preferred detection order:

1. Use `lscpu --json` for sockets, NUMA nodes, cores, and CPU IDs.
2. Use `numactl --hardware` for NUMA memory locality and CPU lists.
3. Optionally use Hwloc.jl later if it is available in the image or current
   Julia environment.

The detection result should be converted into an internal structure:

```julia
struct MachineTopology
    physical_cores::Int
    logical_cpus::Vector{Int}
    sockets::Vector{SocketTopology}
    numa_nodes::Vector{NumaTopology}
    hyperthreading::Bool
end
```

The exact type layout can differ, but the planner needs physical cores, logical
CPU IDs, socket IDs, NUMA node IDs, and CPU lists per domain.

### Automatic Placement Policy

Given `worker_per_vm`, derive placement automatically:

- `worker_per_vm == 1`: one worker owns the whole VM.
- `worker_per_vm == number_of_sockets`: one worker per socket.
- `worker_per_vm == number_of_numa_nodes`: one worker per NUMA domain.
- `worker_per_vm < number_of_numa_nodes`: spread workers across NUMA domains to maximize
  memory bandwidth.
- `worker_per_vm > number_of_numa_nodes`: subdivide NUMA domains into contiguous physical
  core ranges.
- If `worker_per_vm` does not divide cleanly into available physical cores, distribute
  cores as evenly as possible and warn if the imbalance is material.
- If `worker_per_vm > physical_cores`, error by default.

The planner should produce one placement record per local worker:

```julia
struct WorkerPlacement
    localid::Int
    cpu_set::Vector{Int}
    numa_node::Union{Int,Nothing}
    socket::Union{Int,Nothing}
    julia_threads::Int
    julia_interactive_threads::Int
    omp_threads::Int
end
```

### Thread Count Inference

By default:

```julia
threads_per_worker = floor(Int, physical_cores / worker_per_vm)
interactive_threads = VERSION >= v"1.9" ? 1 : 0
```

For each worker:

- `JULIA_NUM_THREADS` should become
  `"$threads_per_worker,$interactive_threads"` on Julia versions that support
  interactive threads.
- `JULIA_NUM_THREADS` should become `"$threads_per_worker"` on older Julia
  versions.
- `OMP_NUM_THREADS` should match `threads_per_worker`.
- `OMP_PROC_BIND=close`.
- `OMP_PLACES=cores`.

If the worker receives a smaller CPU set because of uneven division,
`threads_per_worker` should match that worker's CPU set length.

### Launch Command Generation

Each local worker should be launched inside its inferred CPU and memory domain.

Example generated command:

```bash
OMP_NUM_THREADS=44 OMP_PROC_BIND=close OMP_PLACES=cores \
numactl --physcpubind=44-87 --membind=1 \
    julia -t 44,1 -e 'using AzManagers; AzManagers.azure_worker(...)'
```

Rules:

- Prefer `numactl --physcpubind=<cpu-list>` for CPU binding.
- Use `--membind=<numa-node>` when the CPU set maps cleanly to one NUMA node.
- If a CPU set spans multiple NUMA nodes, use `--cpunodebind`/`--membind` only
  when the maworker_per_vmng is unambiguous; otherwise CPU-bind only and warn at debug
  level.
- If `numactl` is unavailable, continue without OS-level pinning but log a
  warning.

### ThreadPinning.jl Integration

ThreadPinning.jl should be used automatically when available. It should not be
required for basic operation.

Startup behavior:

1. `numactl` constrains the process to the assigned CPU set.
2. Inside the worker, try to load ThreadPinning.jl.
3. If available, pin Julia threads within the assigned CPU set.
4. If unavailable, continue with `numactl` only.

The worker startup code can follow this pattern:

```julia
try
    using ThreadPinning
    AzManagers.pin_julia_threads(cpu_set)
catch err
    @debug "ThreadPinning.jl unavailable; relying on numactl pinning" err
end
```

`pin_julia_threads(cpu_set)` should live in AzManagers and isolate the
ThreadPinning-specific calls so the rest of the code remains testable.

### Worker Metadata

Store inferred placement metadata in `WorkerConfig.userdata`:

```julia
"localid" => 2,
"worker_per_vm" => 4,
"physical_cores" => 176,
"julia_threads" => 44,
"julia_interactive_threads" => 1,
"omp_threads" => 44,
"cpu_set" => "44-87",
"numa_node" => 1,
"socket" => 0,
"pinning_backend" => "numactl+ThreadPinning"
```

Expose inspection helpers:

```julia
AzManagers.worker_placement(pid)
AzManagers.worker_placements()
```

These should return the metadata for one worker or all workers.

### Integration With Existing `worker_per_vm`

Currently, AzManagers starts one initial worker per VM and asks Julia
`Distributed` to launch additional local workers. The placement work should
replace or extend that path so every local worker can receive its own CPU set.

Required changes:

- Compute placement before launching additional workers.
- Pass local placement data to each worker startup command.
- Ensure `localid` remains stable and corresponds to the placement record.
- Ensure `Distributed.launch_n_additional_processes` receives per-worker
  `exeflags`, environment variables, and placement metadata.

If Julia's default additional-worker launcher cannot express distinct
`numactl` commands per local worker, implement a custom additional-worker launch
path for AzManagers.

### MPI And OpenMP Interaction

The automatic placement policy must keep Julia, OpenMP, and MPI consistent.

For non-MPI workers:

- One Julia process per placement.
- Julia threads and OpenMP threads match the assigned CPU set.

For MPI workers:

- Treat `mpi_ranks_per_worker` as a subdivision inside each worker placement.
- Either reject incompatible combinations initially, or define a clear nested
  maworker_per_vmng:
  `VM -> Julia worker placement -> MPI rank placement`.

Initial recommendation:

- Implement automatic placement first for `mpi_ranks_per_worker == 0`.
- Add explicit validation that errors for unsupported `worker_per_vm` plus MPI
  combinations.
- Extend MPI placement after non-MPI placement is stable.

### Failure Behavior

Default behavior should be conservative:

- Error if `worker_per_vm > physical_cores`.
- Warn if CPU division is uneven.
- Warn if `numactl` is unavailable.
- Debug-log if ThreadPinning.jl is unavailable.
- Continue without ThreadPinning.jl when `numactl` succeeded.
- Include placement metadata in error messages when worker startup fails.

### Tests For Automatic Placement

Add fast unit tests using synthetic topology fixtures:

- 1 socket, 1 NUMA node, `worker_per_vm=1`.
- 2 sockets, 2 NUMA nodes, `worker_per_vm=2`.
- 4 NUMA nodes, `worker_per_vm=4`.
- 4 NUMA nodes, `worker_per_vm=2`, verifying spread across NUMA domains.
- 4 NUMA nodes, `worker_per_vm=8`, verifying subdivision.
- Uneven core counts, verifying balanced allocation and warnings.
- Oversubscription, verifying an error.

Add startup script tests:

- Generated `numactl` CPU lists are correct.
- `JULIA_NUM_THREADS` is inferred correctly.
- `OMP_NUM_THREADS`, `OMP_PROC_BIND`, and `OMP_PLACES` are set correctly.
- ThreadPinning startup code is included only in the intended worker path.

Add integration tests on a known multi-NUMA Azure SKU:

- Validate each worker reports expected `cpu_set`, `numa_node`, and `socket`.
- Validate actual process affinity with `taskset -pc` or equivalent.
- Validate Julia thread pinning with ThreadPinning.jl introspection when
  available.
- Validate memory locality with `numactl --show` or a lightweight locality
  check.

## Suggested Work Order

1. Fix the known correctness bugs listed above.
2. Add unit-test infrastructure for pure functions and generated scripts.
3. Extract Azure REST helpers and startup script generation into smaller files.
4. Add topology parsing and placement planning as pure, unit-tested code.
5. Generate per-worker startup commands from placement records.
6. Integrate automatic placement into `worker_per_vm`.
7. Add ThreadPinning.jl best-effort support.
8. Add worker placement inspection APIs.
9. Add Azure integration tests for one representative multi-NUMA SKU.

