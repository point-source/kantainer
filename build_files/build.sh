#!/bin/bash
# Image customisation. Runs inside the container build, with the repository's
# build_files/ at /ctx and system_files/ at /ctx/system_files.
#
# Section order matters:
#   1. system_files    - static files from the repository
#   2. packages        - LATER BATCHES ADD PACKAGE INSTALLS HERE
#   3. services        - what runs on the installed machine
#   4. cleanup         - dnf leftovers, or `bootc container lint` warns
#   5. signing policy  - must stay LAST, so no package transaction can replace
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

# Portainer, carried inside the OS image (SPEC.md §spec:portainer-service)
#
# The machine must NEVER pull Portainer from a registry: a Docker Hub outage or
# rate limit cannot be allowed to stop a freshly installed machine from serving.
# Docker offers no way to share a read-only image store, so the image travels as
# an archive and is loaded into Docker at boot by
# kantainer-portainer-load.service.
#
# THIS MUST STAY ABOVE THE SIGNING POLICY SECTION. That section sets the docker
# transport default to reject, and skopeo reads the same policy.json - a copy
# placed after it would fail.
#
# Pulled by digest alone: skopeo refuses a reference carrying both a tag and a
# digest. The destination's :name:tag suffix supplies the readable name, so the
# loaded image is both digest-exact and something a human can recognise in
# `docker image ls`. That name is what kantainer-portainer.service runs.
#
# skopeo is already in the base image; nothing is installed for this.
# shellcheck source=/dev/null
. /ctx/versions.env

# One expression decides the loaded image's name, and both the archive and the
# reference file are generated from it - the load unit and the service unit read
# that file rather than each carrying their own copy of the string. docker load
# reports the name without the docker.io/ prefix, and this is what an operator
# sees in `docker image ls`, so that is the form written down.
PORTAINER_REF="${PORTAINER_IMAGE#docker.io/}:${PORTAINER_TAG}"

mkdir -p /usr/lib/kantainer
skopeo copy --quiet \
    "docker://${PORTAINER_IMAGE}@${PORTAINER_DIGEST}" \
    "docker-archive:/usr/lib/kantainer/portainer.tar:${PORTAINER_REF}"
printf '%s\n' "${PORTAINER_REF}" > /usr/lib/kantainer/portainer-image
chmod 0644 /usr/lib/kantainer/portainer-image

### 3. Services (SPEC.md §spec:container-engine)
#
# Docker runs from first boot. ucore-minimal ships moby-engine - it comes from
# the Fedora CoreOS base - but uCore's post-install runs `systemctl disable
# docker.socket` to stop the daemon activating by accident alongside podman,
# which it prefers. Nothing preset-enables docker.service either, so an
# untouched machine has no container engine running at all.
#
# We enable the SERVICE, not the socket. Socket activation is lazy: the daemon
# would not start until something spoke to it, and §spec:container-engine wants
# the engine running from first boot. docker.service carries
# `Requires=docker.socket`, so the socket comes along regardless of its own
# enablement.
#
# This writes a symlink into /etc, which is exactly how the base image enables
# firewalld and sshd. In a bootc image /etc is the ostree *default* (committed
# to /usr/etc), not a local modification, so it ships on a fresh install and
# updates normally - while an operator who later disables Docker on their own
# machine keeps that decision across updates.
#
# A preset file in /usr/lib/systemd/system-preset/ was rejected: presets are
# inert data, and nothing runs `systemctl preset` in a hand-written derived
# layer. It would look correct and do nothing.
#
# Podman stays installed and carries no workloads (§spec:container-engine).
# Removing it fights the base image for no gain - it is inert when nothing
# invokes it.
systemctl enable docker.service
systemctl enable kantainer-portainer-load.service
systemctl enable kantainer-portainer.service

# The firewall (SPEC.md §spec:container-engine). firewalld is already installed
# and already enabled in ucore-minimal, so there is nothing to switch on - only
# to narrow. The zone itself ships in system_files as an image-owned file; all
# that is left is to make it the default, because DefaultZone lives in
# firewalld.conf and has no /usr/lib fallback. uCore writes this same file (it
# copies firewalld-server.conf over it), so editing it in place stays consistent
# with the base.
#
# firewall-offline-cmd would generate the zone instead, and does work without
# dbus, but it writes into /etc/firewalld/zones - local customisation territory,
# not the image's.
sed -i 's|^DefaultZone=.*|DefaultZone=kantainer|' /etc/firewalld/firewalld.conf
grep -q '^DefaultZone=kantainer$' /etc/firewalld/firewalld.conf

### 4. Cleanup
#
# uCore's own cleanup does not run for this layer, and `dnf5 clean all` leaves
# /run/dnf and /var/lib/dnf/repos behind. Both trip `bootc container lint`
# (nonempty-run-tmp, var-tmpfiles): content under /run is runtime-only, and
# content baked into /var without a tmpfiles.d entry is not reproducible on a
# fresh machine. ucore-minimal ships neither directory, so removing them
# restores the base image's state exactly.
dnf5 clean all
rm -rf /var/lib/dnf /run/dnf

# skopeo leaves its blob-info cache behind in the same way
# (/var/lib/containers/cache/blob-info-cache-v1.sqlite). It is build-time
# bookkeeping about which blobs were pulled - useless on the installed machine,
# and it trips var-tmpfiles for the same reason.
rm -rf /var/lib/containers

### 5. Container signing policy (SPEC.md §spec:image-publication, §spec:os-updates)
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
