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
