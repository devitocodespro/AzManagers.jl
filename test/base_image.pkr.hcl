# Base image template - rebuilt rarely (on-demand via the
# refresh-base-image.yml workflow). Bakes Julia + apt deps + AzManagers'
# Julia deps with everything precompiled, but is NOT tied to any specific
# CI run. The per-run image.pkr.hcl uses this as its source so each CI
# run only has to Pkg.add AzManagers at the test SHA, not rebuild the
# whole dep tree.

variable "subscription_id" {
    default = "subscriptionid"
}

variable "tenant_id" {
    default = "tenantid"
}

variable "client_id" {
    default = "clientid"
}

variable "client_secret" {
    default = "secret"
}

# Long-lived resource group holding the base gallery / image-definition.
# Created idempotently by refresh-base-image.yml.
variable "resource_group" {
    default = "azmanagers-ci-base-rg"
}

variable "gallery" {
    default = "azmanagersbasegallery"
}

variable "image_name" {
    default = "azmanagers-base"
}

variable "image_version" {
    default = "1.0.0"
}

# Build-time VNet/NSG (lives in the same long-lived base RG).
variable "virtual_network" {
    default = "azmanagers-base-vnet"
}

variable "virtual_subnet" {
    default = "default"
}

variable "julia_version_major" {
    default = "1"
}

variable "julia_version_minor" {
    default = "12"
}

variable "julia_version_patch" {
    default = "0"
}

# AzManagers fork URL + ref used to pull the dep tree at base-build time.
# Precompiling against this fork's Project.toml ensures the dep versions
# in the depot match the compat ranges the per-run image will resolve to.
variable "azmanagers_repo" {
    default = "https://github.com/devitocodespro/AzManagers.jl.git"
}

variable "azmanagers_version" {
    default = "master"
}

variable "location" {
    default = "eastus"
}

variable "replication_regions" {
    type = list(string)
    # Regions that the base image is replicated to. Add a region here
    # if you want a multi-worker-test.yml shard to boot from this base
    # in that region. South Central US is included for the HB176rs_v5
    # shard which only has regular-priority quota there.
    default = ["East US", "South Central US"]
}

packer {
    required_plugins {
        azure = {
            source = "github.com/hashicorp/azure"
            version = "~> 1"
        }
    }
}

source "azure-arm" "base" {
    subscription_id = var.subscription_id
    tenant_id = var.tenant_id
    client_id = var.client_id
    client_secret = var.client_secret
    os_type = "Linux"
    # D4s_v3 is plenty for apt + Julia + Pkg.precompile.
    vm_size = "Standard_D4s_v3"
    image_publisher = "canonical"
    image_offer = "0001-com-ubuntu-server-jammy"
    image_sku = "22_04-lts-gen2"
    shared_image_gallery_destination {
        resource_group = var.resource_group
        gallery_name = var.gallery
        image_name = var.image_name
        image_version = var.image_version
        replication_regions = var.replication_regions
    }
    shared_image_gallery_timeout = "120m"
    build_resource_group_name = var.resource_group
    managed_image_resource_group_name = var.resource_group
    managed_image_name = var.image_name
    managed_image_storage_account_type = "Premium_LRS"
    virtual_network_name = var.virtual_network
    virtual_network_subnet_name = var.virtual_subnet
    virtual_network_resource_group_name = var.resource_group
    private_virtual_network_with_public_ip = true
    ssh_username = "cvx"
}

build {
    sources = [
        "source.azure-arm.base"
    ]

    provisioner "shell" {
        inline = [
            "echo \"Host *\" > ~/.ssh/config",
            "echo \"    StrictHostKeyChecking    no\" >> ~/.ssh/config",
            "echo \"    LogLevel                 ERROR\" >> ~/.ssh/config",
            "echo \"    UserKnownHostsFile       /dev/null\" >> ~/.ssh/config"
        ]
    }

    provisioner "shell" {
        inline = [
            "sudo apt-get -y update",
            "sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" upgrade",
            "sudo apt-get -y install git gcc numactl util-linux openmpi-bin libopenmpi-dev"
        ]
        max_retries = 5
    }

    provisioner "shell" {
        inline = [
            "echo \"**** generating AzManagers ssh key-pair ****\"",
            "ssh-keygen -f /home/cvx/.ssh/azmanagers_rsa -N ''"
        ]
    }

    provisioner "shell" {
        inline = [
            "echo \"**** installing Julia ****\"",
            "sudo wget https://julialang-s3.julialang.org/bin/linux/x64/${var.julia_version_major}.${var.julia_version_minor}/julia-${var.julia_version_major}.${var.julia_version_minor}.${var.julia_version_patch}-linux-x86_64.tar.gz",
            "sudo mkdir -p /opt/julia",
            "sudo tar --strip-components=1 -xzvf julia-${var.julia_version_major}.${var.julia_version_minor}.${var.julia_version_patch}-linux-x86_64.tar.gz -C /opt/julia",
            "sudo rm -f julia-${var.julia_version_major}.${var.julia_version_minor}.${var.julia_version_patch}-linux-x86_64.tar.gz",
            "sed -i '1 i export PATH=\"/opt/julia/bin:$${PATH}\"' ~/.bashrc",
            "sed -i '1 i export JULIA_WORKER_TIMEOUT=\"720\"' ~/.bashrc"
        ]
    }

    # Install AzManagers' third-party deps (matches src/Project.toml [deps]
    # minus stdlib) and precompile them. AzManagers itself is deliberately
    # NOT installed here - per-run image.pkr.hcl handles that against the
    # CI run's SHA, sidestepping any master-vs-branch source incompat and
    # taking the ~30s precompile per run (vs ~10min for the full dep tree).
    provisioner "shell" {
        inline = [
            "echo \"**** installing julia packages and precompiling ****\"",
            "julia -e 'using Pkg; Pkg.add([\"AzSessions\", \"CodecZlib\", \"Coverage\", \"HTTP\", \"Hwloc\", \"JSON\", \"JWTs\", \"LibCURL\", \"MPI\", \"MPIPreferences\", \"Test\", \"ThreadPinning\", \"TOML\"])'",
            "julia -e 'using MPIPreferences; MPIPreferences.use_jll_binary(\"MPICH_jll\")'",
            "julia -e 'using AzSessions, CodecZlib, Coverage, HTTP, Hwloc, JSON, JWTs, LibCURL, MPI, Test, ThreadPinning, TOML'"
        ]
    }
}
