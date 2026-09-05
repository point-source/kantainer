#!/bin/bash
# Image customisation. Runs inside the container build, with the repository's
# build_files/ at /ctx and system_files/ at /ctx/system_files.
#
# Section order matters:
#   1. system_files    - static files from the repository
#   2. packages        - LATER BATCHES ADD PACKAGE INSTALLS HERE
#   3. cleanup         - dnf leftovers, or `bootc container lint` warns
#   4. signing policy  - must stay LAST, so no package transaction can replace
#                        /etc/containers/policy.json after we have merged it

set -ouex pipefail

### 1. Static files
# Copy the contents of system_files/ of the git repo to /
cp -avf /ctx/system_files/. /

### 2. Packages
#
# Wireless support (SPEC.md §spec:base-image, §spec:network-attachment)
#
# ucore-minimal ships the wifi *drivers* (kernel-modules-extra carries iwlwifi,
# rtw88/89, mt76, ath1xk, brcmfmac) but neither the firmware blobs nor the
# userspace supplicant. Fedora 42+ split linux-firmware into per-vendor
# subpackages joined by Recommends:, and Fedora CoreOS composes with
# `recommends: false`, so every vendor subpackage has to be named explicitly.
#
# We restore these by hand rather than moving to ucore's full variant, which
# would import Samba, NFS, snapraid and mergerfs - excluded by §req:constraints.
#
# wpa_supplicant is named explicitly on purpose: NetworkManager-wifi's
# dependency is the rich boolean `(wpa_supplicant or iwd)`, and with neither
# installed the resolver's choice is not guaranteed.
#
# wireless-regdb and iwlwifi-mld-firmware arrive as hard dependencies; listing
# them here would only add something else to keep correct.
dnf5 -y install \
    NetworkManager-wifi \
    wpa_supplicant \
    iw \
    iwlwifi-mvm-firmware \
    iwlwifi-dvm-firmware \
    realtek-firmware \
    atheros-firmware \
    brcmfmac-firmware \
    mt7xxx-firmware

### 3. Cleanup
#
# uCore's own cleanup does not run for this layer, and `dnf5 clean all` leaves
# /run/dnf and /var/lib/dnf/repos behind. Both trip `bootc container lint`
# (nonempty-run-tmp, var-tmpfiles): content under /run is runtime-only, and
# content baked into /var without a tmpfiles.d entry is not reproducible on a
# fresh machine. ucore-minimal ships neither directory, so removing them
# restores the base image's state exactly.
dnf5 clean all
rm -rf /var/lib/dnf /run/dnf

### 4. Container signing policy (SPEC.md §spec:image-publication, §spec:os-updates)
#
# KEEP THIS LAST. containers-common can be pulled into any package transaction
# and replaces /etc/containers/policy.json when it is, so anything installed
# after this point would silently undo the merge below.

# The scope is derived from image.env, never written by hand. It must name the
# exact reference the publish workflow pushes to: a machine looks up the image
# it is pulling, and a scope that does not match is not a strict policy, it is
# no policy at all (see the transport default below).
# shellcheck source=/dev/null
. /ctx/image.env
IMAGE_REF="$(echo "${IMAGE_REGISTRY}/${REPO_ORGANIZATION}/${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]')"

# ucore-minimal already ships a policy (from ublue-os-signing) with a
# sigstoreSigned entry for ghcr.io/ublue-os. We MERGE into it rather than
# writing our own file - overwriting would drop verification of our own base.
#
# Two things are set here:
#
#   - our own scope, requiring a signature from the key baked in below.
#     matchRepository is required, not stylistic: a cosign signature carries
#     only a repository, so it is the only identity type that can accept one.
#
#   - the docker transport default, changed from the base image's
#     insecureAcceptAnything to reject. That default is consulted BEFORE the
#     top-level "default": reject, so inheriting it means any image not matching
#     an explicit scope is accepted unsigned. SPEC.md §spec:os-updates requires
#     the opposite. With this set, a scope that ever stopped matching the
#     published reference would stop updates rather than accept anything - the
#     failure becomes loud instead of silent.
#
#     The cost is that podman on the installed machine can only pull from the
#     scopes named here. That is consistent with §spec:container-engine, where
#     podman is present but carries no workloads; Docker runs the operator's
#     containers and does not consult this file.
install -Dpm 0644 /ctx/cosign.pub /etc/pki/containers/kantainer.pub

jq --arg ref "${IMAGE_REF}" '
      .transports.docker[$ref] = [
        { "type": "sigstoreSigned",
          "keyPath": "/etc/pki/containers/kantainer.pub",
          "signedIdentity": { "type": "matchRepository" } } ]
    | .transports.docker[""] = [ { "type": "reject" } ]' \
    /etc/containers/policy.json > /tmp/policy.json
install -Dpm 0644 /tmp/policy.json /etc/containers/policy.json
rm -f /tmp/policy.json

# Tell containers/image to look for cosign signatures on our image. Generated
# from the same IMAGE_REF, so the scope cannot drift from the policy above.
mkdir -p /etc/containers/registries.d
cat > /etc/containers/registries.d/kantainer.yaml <<EOF
docker:
  ${IMAGE_REF}:
    use-sigstore-attachments: true
EOF
chmod 0644 /etc/containers/registries.d/kantainer.yaml

# Fail the build if the merge did not take. Mirrors uCore's own assertion, and
# catches a clobbered policy.json - the failure mode that would otherwise ship
# an image no machine can verify an update from.
jq -e '.transports.docker["ghcr.io/ublue-os"] | any(.type == "sigstoreSigned")' \
    /etc/containers/policy.json > /dev/null
jq -e --arg ref "${IMAGE_REF}" '.transports.docker[$ref] | any(.type == "sigstoreSigned")' \
    /etc/containers/policy.json > /dev/null
jq -e '.transports.docker[""] | all(.type == "reject")' \
    /etc/containers/policy.json > /dev/null
