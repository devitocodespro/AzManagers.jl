# Per-run image template. Sources from the long-lived base image
# (test/base_image.pkr.hcl, refreshed by refresh-base-image.yml) which
# already has Julia + apt deps + AzManagers' Julia deps precompiled.
# This template only needs to:
#   - swap AzManagers to the CI run's SHA
#   - write the per-run templates_scaleset.json (resource group / vnet /
#     gallery / image name change every run)

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

variable "resource_group" {
    default = "resourcegroup"
}

variable "image_name" {
    default = "imagename"
}

variable "gallery" {
    default = "gallery"
}

variable "image_version" {
    default = "1.0.0"
}

variable "virtual_network" {
    default = "virtualnetwork"
}

variable "virtual_subnet" {
    default = "subnet"
}

variable "azmanagers_version" {
    default = "master"
}

# Git URL the workers clone AzManagers from. Defaults to this fork; the
# CI workflows still override it via `-var` so the URL always matches
# `${{ github.repository }}` of the run that triggered them.
variable "azmanagers_repo" {
    default = "https://github.com/devitocodespro/AzManagers.jl.git"
}

# Region the baked-in test/templates.jl scale-set / VM / NIC templates
# point at, and the VM SKU they request. ci.yml passes these via -var so
# the same Packer file can build images for any region / SKU pair.
variable "location" {
    default = "eastus"
}

variable "vm_size" {
    default = "Standard_D4s_v3"
}

# Long-lived base image to derive from. See refresh-base-image.yml.
variable "base_resource_group" {
    default = "azmanagers-ci-base-rg"
}

variable "base_gallery" {
    default = "azmanagersbasegallery"
}

variable "base_image_name" {
    default = "azmanagers-base"
}

packer {
    required_plugins {
        azure = {
            source = "github.com/hashicorp/azure"
            version = "~> 1"
        }
    }
}

source "azure-arm" "cofii" {
    subscription_id = var.subscription_id
    tenant_id = var.tenant_id
    client_id = var.client_id
    client_secret = var.client_secret
    os_type = "Linux"
    vm_size = "Standard_D4s_v3"
    # Boot the build VM from the precompiled base image instead of the
    # marketplace Ubuntu image. `image_version` is omitted so Packer picks
    # the latest version published by the refresh workflow.
    shared_image_gallery {
        subscription = var.subscription_id
        resource_group = var.base_resource_group
        gallery_name = var.base_gallery
        image_name = var.base_image_name
    }
    shared_image_gallery_destination {
        resource_group = var.resource_group
        gallery_name = var.gallery
        image_name = var.image_name
        image_version = var.image_version
        replication_regions = ["East US"]
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
        "source.azure-arm.cofii"
    ]

    # AzManagers is already in the depot at whatever ref the base was built
    # with; swap it to the test SHA. Deps stay in the depot and don't
    # recompile because their resolved versions don't change.
    provisioner "shell" {
        inline = [
            "echo \"**** swapping AzManagers to CI ref ${var.azmanagers_version} ****\"",
            "julia -e 'using Pkg; Pkg.add(PackageSpec(url=\"${var.azmanagers_repo}\", rev=\"${var.azmanagers_version}\"))'",
            "julia -e 'using AzManagers'"
        ]
    }

    provisioner "file" {
        source = "test/templates.jl"
        destination = "/tmp/templates.jl"
    }

    provisioner "shell" {
        inline = [
            "echo \"**** building AzManagers manifest and templates ****\"",
            "export TENANT_ID=\"${var.tenant_id}\"",
            "export SUBSCRIPTION_ID=\"${var.subscription_id}\"",
            "export RESOURCE_GROUP=\"${var.resource_group}\"",
            "export CLIENT_ID=\"${var.client_id}\"",
            "export CLIENT_SECRET=\"${var.client_secret}\"",
            "export IMAGE_NAME=\"${var.image_name}\"",
            "export VNET_NAME=\"${var.virtual_network}\"",
            "export SUBNET_NAME=\"${var.virtual_subnet}\"",
            "export GALLERY_NAME=\"${var.gallery}\"",
            "export LOCATION=\"${var.location}\"",
            "export VM_SIZE=\"${var.vm_size}\"",
            "julia /tmp/templates.jl"
        ]
    }
}
