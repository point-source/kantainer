#!/bin/bash
# Writes the installer to a USB stick (SPEC.md §spec:installer-media).
#
# This is `just flash`, and it is the whole of the operator's side of the
# system: one command, two inputs - their filled-in configuration and the device
# to write. Out of it comes a stick that installs a machine which serves
# Portainer without anyone touching it.
#
# THE INSTALLER IS BUILT HERE AND NEVER PUBLISHED. It carries the operator's
# account, their SSH key and their Portainer password, and this repository is
# public (REQUIREMENTS.md §req:quality-attributes). The repository publishes the
# IMAGE - which is what machines actually consume - and the media is personalised
# on the operator's own machine, at flash time, from the Fedora CoreOS release
# pinned in versions.env.
#
# Every check that can refuse does so BEFORE the device is touched. The last
# thing that happens before the write is a person reading the model and size of
# what they are about to erase and typing its name back.
#
# Usage: flash.sh <device> [config-file]

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The same rules `just config-check` and `just render` apply, from the same
# library: a configuration one of them accepts is one this can build from.
# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/config-lib.sh"

# shellcheck source=/dev/null
. "${REPO_ROOT}/versions.env"

# lsblk's own account of a device: type, model, size, and the disk a partition
# belongs to. It fails when the path is not a block device, which covers a
# typo'd path and a regular file in one verdict rather than two checks of ours.
# Replaced by the tests, which have no USB stick.
kantainer_device_facts() {
    lsblk --json --nodeps --output TYPE,MODEL,SIZE,PKNAME "$1" 2> /dev/null |
        jq -r '.blockdevices[0]
               | [ .type, (.model // "unknown"), (.size // "unknown"), (.pkname // "") ]
               | @tsv'
}

# Refuses the two mistakes that have an objectively wrong outcome, and prints
# the model and size of what is left.
#
# It does NOT try to work out whether a device is "safe" to erase. There is no
# such judgement to make from here: the operator's spare stick and the operator's
# only backup drive look identical to lsblk. Naming what is about to be erased
# and asking is the whole of the defence, and it is the operator's to make.
kantainer_check_device() {
    local device="$1" facts type model size pkname

    facts="$(kantainer_device_facts "${device}")" ||
        kantainer_fail "${device} is not a block device on this machine.
    List what is attached with:
        lsblk --nodeps --output NAME,MODEL,SIZE"

    IFS=$'\t' read -r type model size pkname <<< "${facts}"

    if [[ "${type}" == "part" ]]; then
        kantainer_fail "${device} is a partition, not a whole drive.
    An installer written to a partition has no boot sector and cannot start.
    You probably mean /dev/${pkname}."
    fi

    printf '%s\t%s\n' "${model}" "${size}"
}

# The last gate before the irreversible part. The device path has to be typed
# back rather than answered with yes: REQUIREMENTS.md §req:priorities calls
# erasing the wrong drive the only failure in this system that cannot be undone,
# and re-reading the path is what catches the one the operator meant.
kantainer_confirm_device() {
    local device="$1" model="$2" size="$3" answer

    {
        echo
        echo "ABOUT TO ERASE ${device}"
        echo "    model: ${model}"
        echo "    size:  ${size}"
        echo
        echo "Everything on that device will be gone, and this cannot be undone."
        echo "Type ${device} to go ahead, or anything else to stop."
    } >&2

    read -r answer || answer=""

    [[ "${answer}" == "${device}" ]] ||
        kantainer_fail "not confirmed. Nothing was written to ${device}."
}

kantainer_as_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif command -v sudo > /dev/null; then
        sudo "$@"
    else
        kantainer_fail "writing to a device needs root, and sudo is not installed."
    fi
}

main() {
    local device="${1-}" config="${2:-kantainer.conf}"
    local facts model size iso staging

    [[ -n "${device}" ]] ||
        kantainer_fail "no device given.
    Usage: just flash <device> [config-file]
    List what is attached with:
        lsblk --nodeps --output NAME,MODEL,SIZE"

    kantainer_load_config "${config}"
    kantainer_validate_config "${config}"

    facts="$(kantainer_check_device "${device}")"
    IFS=$'\t' read -r model size <<< "${facts}"

    command -v podman > /dev/null ||
        kantainer_fail "podman is not on PATH.
    coreos-installer publishes no portable binary, so the installer is
    personalised in the container pinned in versions.env."

    # Verified against the checksum committed to this repository, before
    # anything is written anywhere.
    iso="$("${REPO_ROOT}/scripts/fetch-installer.sh")"

    # /var/tmp rather than /tmp: this holds a copy of a 1.3 GB ISO, and /tmp is
    # commonly a tmpfs sized for something smaller. mktemp gives 0700, and the
    # trap is armed before the operator's key and password are written into it.
    staging="$(mktemp -d -p "${TMPDIR:-/var/tmp}" kantainer-flash.XXXXXXXX)"
    trap 'rm -rf "${staging}"' EXIT

    "${REPO_ROOT}/scripts/render-installer.sh" "${config}" > "${staging}/installer.ign"

    echo "flash: building the installer for ${KANTAINER_USERNAME}'s machine" >&2

    # The pinned coreos-installer, by digest. The cache is mounted read-only so
    # a customise cannot damage the verified copy; label=disable because both
    # mounts are the operator's own directories and relabelling their ISO cache
    # to suit a container is not this command's business.
    podman run --rm \
        --security-opt label=disable \
        --volume "$(dirname "${iso}"):/iso:ro" \
        --volume "${staging}:/out:rw" \
        "${COREOS_INSTALLER_IMAGE}@${COREOS_INSTALLER_DIGEST}" \
        iso customize \
        --live-ignition /out/installer.ign \
        --output "/out/installer.iso" \
        "/iso/$(basename "${iso}")"

    kantainer_confirm_device "${device}" "${model}" "${size}"

    echo "flash: writing to ${device}" >&2
    kantainer_as_root dd \
        if="${staging}/installer.iso" \
        of="${device}" \
        bs=4M status=progress conv=fsync
    kantainer_as_root sync

    {
        echo
        echo "flash: ${device} is ready."
        echo "Boot the target machine from it with a wired network connection."
        echo "It installs itself, reboots twice, and answers on https://<its-address>:9443."
    } >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
