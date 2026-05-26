#!/usr/bin/env bash
#
# ensure_base_image.sh
#
# Idempotently make sure the long-lived AzManagers CI base image exists in
# the configured Shared Image Gallery, building it via Packer when missing.
# Intended to be called from a GitHub Actions job that has already done an
# `az login` for the service principal. Reads:
#
#   Auth   : CLIENT_ID, CLIENT_SECRET, TENANT_ID, SUBSCRIPTION_ID
#   GHA    : GITHUB_WORKSPACE (path to the checked-out repo)
#   Base   : BASE_RG, BASE_GALLERY, BASE_IMAGE, BASE_VNET, BASE_SUBNET,
#            BASE_NSG, LOCATION (defaults match test/image.pkr.hcl)
#   Packer : JULIA_VERSION (default 1.12.0), AZMANAGERS_REF (default master),
#            AZMANAGERS_REPO (default devitocodespro fork)
#
# Exit code 0 means the base image is present afterwards - either because
# it already existed (fast path, ~5s) or because we built it (cold path,
# ~10min). Run after `az login` and before any `packer build` against
# test/image.pkr.hcl.

set -euo pipefail

: "${BASE_RG:=azmanagers-ci-base-rg}"
: "${BASE_GALLERY:=azmanagersbasegallery}"
: "${BASE_IMAGE:=azmanagers-base}"
: "${BASE_VNET:=azmanagers-base-vnet}"
: "${BASE_SUBNET:=default}"
: "${BASE_NSG:=azmanagers-base-nsg}"
: "${LOCATION:=eastus}"
: "${JULIA_VERSION:=1.12.0}"
: "${AZMANAGERS_REF:=master}"
: "${AZMANAGERS_REPO:=https://github.com/devitocodespro/AzManagers.jl.git}"

# Fast path: any image-version already published under this image-def
# means we can skip everything.
if az sig image-version list \
        -g "$BASE_RG" -r "$BASE_GALLERY" -i "$BASE_IMAGE" \
        --query "[0].name" -o tsv 2>/dev/null | grep -q .; then
    echo "Base image found in $BASE_RG/$BASE_GALLERY/$BASE_IMAGE - skipping build."
    exit 0
fi

echo "Base image missing in $BASE_RG/$BASE_GALLERY/$BASE_IMAGE - bootstrapping..."
echo "This is a one-time cost (~10 min); subsequent CI runs will skip it."

# Idempotent infra: RG, gallery, image-def, build VNet/NSG.
if [ "$(az group exists -n "$BASE_RG")" != "true" ]; then
    az group create -g "$BASE_RG" -l "$LOCATION" \
        --tags purpose=azmanagers-ci-base
fi
if ! az sig show -g "$BASE_RG" -r "$BASE_GALLERY" >/dev/null 2>&1; then
    az sig create -g "$BASE_RG" -r "$BASE_GALLERY" -l "$LOCATION"
fi
if ! az sig image-definition show \
        -g "$BASE_RG" -r "$BASE_GALLERY" -i "$BASE_IMAGE" >/dev/null 2>&1; then
    az sig image-definition create \
        -g "$BASE_RG" -r "$BASE_GALLERY" -i "$BASE_IMAGE" \
        -p canonical -f 0001-com-ubuntu-server-jammy -s 22_04-lts-gen2 \
        --os-type linux --hyper-v-generation V2 -l "$LOCATION"
fi
if ! az network nsg show -g "$BASE_RG" -n "$BASE_NSG" >/dev/null 2>&1; then
    az network nsg create -g "$BASE_RG" -n "$BASE_NSG" -l "$LOCATION"
    az network nsg rule create \
        -g "$BASE_RG" --nsg-name "$BASE_NSG" \
        -n "rule-$BASE_NSG" --priority 101 \
        --source-address-prefixes AzureCloud --destination-port-ranges 22
fi
if ! az network vnet show -g "$BASE_RG" -n "$BASE_VNET" >/dev/null 2>&1; then
    az network vnet create -g "$BASE_RG" -n "$BASE_VNET" -l "$LOCATION" \
        --subnet-name "$BASE_SUBNET"
    az network vnet subnet update \
        -g "$BASE_RG" -n "$BASE_SUBNET" --vnet-name "$BASE_VNET" \
        --network-security-group "$BASE_NSG"
fi

# Packer (no-op when already on PATH).
if ! command -v packer >/dev/null; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo apt-add-repository \
        "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get update && sudo apt-get install -y packer
fi

# Parse julia x.y.z so the packer var pieces line up with the tarball URL.
JV="$JULIA_VERSION"
JMAJ="${JV%%.*}"
rest="${JV#*.}"
JMIN="${rest%%.*}"
JPAT="${rest#*.}"

# SIG image-versions must be monotonic x.y.z. Use UTC date+time so two
# back-to-back base rebuilds in the same day don't collide.
IMAGE_VER="$(date -u +%Y%m%d.%H%M.0)"

cd "$GITHUB_WORKSPACE"
packer init test/base_image.pkr.hcl
packer build -color=false -timestamp-ui \
    -var "subscription_id=$SUBSCRIPTION_ID" \
    -var "tenant_id=$TENANT_ID" \
    -var "client_id=$CLIENT_ID" \
    -var "client_secret=$CLIENT_SECRET" \
    -var "resource_group=$BASE_RG" \
    -var "gallery=$BASE_GALLERY" \
    -var "image_name=$BASE_IMAGE" \
    -var "image_version=$IMAGE_VER" \
    -var "virtual_network=$BASE_VNET" \
    -var "virtual_subnet=$BASE_SUBNET" \
    -var "julia_version_major=$JMAJ" \
    -var "julia_version_minor=$JMIN" \
    -var "julia_version_patch=$JPAT" \
    -var "azmanagers_repo=$AZMANAGERS_REPO" \
    -var "azmanagers_version=$AZMANAGERS_REF" \
    -var "location=$LOCATION" \
    test/base_image.pkr.hcl
