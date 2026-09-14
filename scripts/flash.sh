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

kantainer_host() {
    uname -s
}

# One objective predicate for the advanced path. Tests replace this boundary;
# ordinary selection trusts diskutil/lsblk's own verdict instead.
kantainer_device_node_exists() {
    [[ -b "$1" || -c "$1" ]]
}

kantainer_plist_value() {
    local plist="$1" key="$2"
    printf '%s' "${plist}" | plutil -extract "${key}" raw -o - -- - 2> /dev/null
}

kantainer_linux_device_facts() {
    local device="$1" facts type model size parent whole
    facts="$(
        lsblk --json --nodeps --output TYPE,MODEL,SIZE,PKNAME "${device}" 2> /dev/null |
            jq -r '.blockdevices[0]
                   | [ .type, (.model // "unknown"), (.size // "unknown"), (.pkname // "unknown") ]
                   | @tsv'
    )" || return 1
    [[ -n "${facts}" ]] || return 1
    IFS=$'\t' read -r type model size parent <<< "${facts}"
    if [[ "${type}" == "part" && "${parent}" != "unknown" ]]; then
        whole="/dev/${parent}"
    elif [[ "${type}" == "disk" ]]; then
        whole="${device}"
    else
        whole="unknown"
    fi
    printf 'Linux\t%s\t%s\t%s\t%s\tunknown\tunknown\t%s\n' \
        "${type:-unknown}" "${model:-unknown}" "${size:-unknown}" \
        "${whole}" "${device}"
}

kantainer_darwin_device_facts() {
    local device="$1" plist node parent is_whole internal physical model size kind whole
    plist="$(diskutil info -plist "${device}" 2> /dev/null)" || return 1
    [[ -n "${plist}" ]] || return 1

    node="$(kantainer_plist_value "${plist}" DeviceNode || true)"
    parent="$(kantainer_plist_value "${plist}" ParentWholeDisk || true)"
    is_whole="$(kantainer_plist_value "${plist}" Whole || true)"
    internal="$(kantainer_plist_value "${plist}" Internal || true)"
    physical="$(kantainer_plist_value "${plist}" VirtualOrPhysical || true)"
    model="$(kantainer_plist_value "${plist}" MediaName || true)"
    size="$(kantainer_plist_value "${plist}" DiskSize || true)"

    case "${is_whole}" in
        true) kind="disk" ;;
        false) kind="part" ;;
        *) kind="unknown" ;;
    esac
    if [[ -n "${parent}" ]]; then
        whole="/dev/${parent#/dev/}"
    elif [[ "${is_whole}" == "true" ]]; then
        whole="${node}"
    else
        whole="unknown"
    fi
    printf 'Darwin\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${kind}" "${model:-unknown}" "${size:-unknown}" \
        "${whole:-unknown}" "${internal:-unknown}" \
        "${physical:-unknown}" "${node:-unknown}"
}

# Normalize the two operating systems' device accounts into eight non-empty
# fields: host, kind, model, size, containing whole disk, internal state,
# physical state, and canonical node. Tests replace this hardware boundary.
kantainer_device_facts() {
    local device="$1" host
    host="$(kantainer_host)"
    case "${host}" in
        Linux) kantainer_linux_device_facts "${device}" ;;
        Darwin) kantainer_darwin_device_facts "${device}" ;;
        *) return 2 ;;
    esac
}

# Print the normalized identity after applying the host's target policy.
kantainer_check_device() {
    local device="$1" mode="${2:-ordinary}" host facts
    local fact_host type model size whole internal physical canonical

    host="$(kantainer_host)"
    case "${host}" in
        Linux | Darwin) ;;
        *)
            kantainer_fail "${host:-unknown} is not a supported host for flashing."
            ;;
    esac

    if [[ "${mode}" == "advanced" ]]; then
        [[ "${host}" == "Darwin" ]] ||
            kantainer_fail "the advanced device override is only available on macOS."
        if [[ ! "${device}" =~ ^/dev/[^/]+$ ]] ||
            ! kantainer_device_node_exists "${device}"; then
            kantainer_fail "${device} is not an existing block or character device node."
        fi

        # diskutil does not describe every character device. The advanced path
        # deliberately admits those nodes, with unknown display facts.
        facts="$(kantainer_device_facts "${device}" 2> /dev/null || true)"
        if [[ -z "${facts}" ]]; then
            facts="Darwin"$'\t'"device"$'\t'"unknown"$'\t'"unknown"$'\t'"unknown"$'\t'"unknown"$'\t'"unknown"$'\t'"${device}"
        fi
        printf '%s\n' "${facts}"
        return 0
    fi

    if ! facts="$(kantainer_device_facts "${device}")"; then
        if [[ "${host}" == "Linux" ]]; then
            kantainer_fail "${device} is not a block device on this machine.
    List what is attached with:
        lsblk --nodeps --output NAME,MODEL,SIZE"
        fi
        kantainer_fail "${device} is not a macOS disk device.
    List external physical disks with:
        diskutil list external physical"
    fi

    IFS=$'\t' read -r fact_host type model size whole internal physical canonical <<< "${facts}"
    [[ "${fact_host}" == "${host}" ]] ||
        kantainer_fail "cannot safely classify ${device} from ${host} device facts."

    if [[ "${host}" == "Linux" ]]; then
        if [[ "${type}" == "part" ]]; then
            kantainer_fail "${device} is a partition, not a whole drive.
    An installer written to a partition has no boot sector and cannot start.
    You probably mean ${whole}."
        fi
        if [[ "${type}" != "disk" ]]; then
            kantainer_fail "${device} is a ${type:-unrecognised} device, not a whole drive.
    An installer has to be written to a physical drive to be bootable.
    List what is attached with:
        lsblk --nodeps --output NAME,TYPE,MODEL,SIZE"
        fi
        printf '%s\n' "${facts}"
        return 0
    fi

    if [[ "${type}" == "part" ]]; then
        kantainer_fail "${device} is a partition, not a whole disk.
    Use ${whole} for the whole disk, or choose the advanced device override."
    fi
    if [[ "${type}" == "unknown" || "${model}" == "unknown" ||
          "${size}" == "unknown" || "${whole}" == "unknown" ||
          "${internal}" == "unknown" || "${physical}" == "unknown" ||
          "${canonical}" == "unknown" ]]; then
        kantainer_fail "cannot safely classify ${device} from macOS device facts."
    fi
    [[ "${canonical}" == "${device}" && "${whole}" == "${device}" &&
       "${device}" =~ ^/dev/disk[0-9]+$ ]] ||
        kantainer_fail "${device} is not the full /dev/diskN path of a whole macOS disk."
    [[ "${internal}" == "false" ]] ||
        kantainer_fail "${device} is an internal disk. The ordinary path accepts only external disks."
    [[ "${physical}" == "Physical" ]] ||
        kantainer_fail "${device} is a virtual disk. The ordinary path accepts only physical disks."

    printf '%s\n' "${facts}"
}

# The last gate before the irreversible part. The device path has to be typed
# back rather than answered with yes: REQUIREMENTS.md §req:priorities calls
# erasing the wrong drive the only failure in this system that cannot be undone,
# and re-reading the path is what catches the one the operator meant.
#
# THE DEVICE IS READ AGAIN HERE, not carried down from the check at the start of
# the command. Minutes pass in between - a 1.3 GB download and a container that
# rebuilds the ISO - and a stick pulled out in that window frees its name for
# whatever is plugged in next, which the kernel hands straight back. Describing
# what lsblk said at the start would put the operator's own stick on the screen
# while dd wrote to the drive that inherited the name. Same objective verdict,
# read at the moment it is used.
kantainer_confirm_erase() {
    local device="$1" mode="${2:-ordinary}" expected="${3-}" facts
    local host type model size whole internal physical canonical risk answer

    # Tested, not assumed: kantainer_fail exits, but inside a command
    # substitution that only kills the subshell. Without this the caller sails
    # on and asks the operator to confirm erasing a device that is not there,
    # with an empty model and size where the answer should be.
    if ! facts="$(kantainer_check_device "${device}" "${mode}")"; then
        exit 1
    fi
    if [[ -n "${expected}" && "${facts}" != "${expected}" ]]; then
        kantainer_fail "${device} changed after it was first checked.
    Nothing was unmounted or written. Run the command again for the device now attached."
    fi
    IFS=$'\t' read -r host type model size whole internal physical canonical <<< "${facts}"

    case "${host}:${mode}" in
        Darwin:advanced)
            risk="ADVANCED OVERRIDE — macOS safety classification bypassed"
            ;;
        Darwin:ordinary)
            risk="external whole physical disk"
            ;;
        *)
            risk="whole disk selected by the operator"
            ;;
    esac

    {
        echo
        echo "ABOUT TO ERASE ${device}"
        echo "    model: ${model}"
        echo "    size:  ${size}"
        echo "    risk:  ${risk}"
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

# The only function allowed to cross from confirmation into target mutation.
kantainer_mutate_target() {
    local image="$1" device="$2" facts="$4"
    local host _type _model _size whole _internal _physical _canonical
    local bytes buffered write_device suffix disk_number

    IFS=$'\t' read -r host _type _model _size whole _internal _physical _canonical <<< "${facts}"

    write_device="${device}"
    if [[ "${host}" == "Darwin" ]]; then
        if ! bytes="$(LC_ALL=C wc -c < "${image}" | tr -d '[:space:]')"; then
            kantainer_fail "cannot read the personalized installer at ${image}.
    Nothing was written to ${device}."
        fi

        # disk and rdisk are the buffered and unbuffered views of the same
        # macOS device. Always unmount the buffered containing whole disk.
        buffered="${device}"
        case "${buffered}" in
            /dev/rdisk*) buffered="/dev/disk${buffered#/dev/rdisk}" ;;
        esac
        if [[ "${whole}" == "unknown" && "${buffered}" == /dev/disk[0-9]* ]]; then
            suffix="${buffered#/dev/disk}"
            disk_number="${suffix%%[!0-9]*}"
            [[ -n "${disk_number}" ]] && whole="/dev/disk${disk_number}"
        fi

        if [[ "${whole}" =~ ^/dev/disk[0-9]+$ ]]; then
            if ! diskutil unmountDisk "${whole}"; then
                kantainer_fail "could not unmount ${whole}.
    Nothing was written to ${device}."
            fi
        fi

        if [[ "${buffered}" == /dev/disk[0-9]* ]]; then
            if (( bytes % 4096 == 0 )); then
                write_device="/dev/r${buffered#/dev/}"
            else
                write_device="${buffered}"
            fi
        fi
    fi

    echo "flash: writing to ${device}" >&2
    if [[ "${host}" == "Darwin" ]]; then
        if ! kantainer_as_root dd if="${image}" of="${write_device}" bs=4194304; then
            kantainer_fail "writing ${device} failed after it began.
    The target may be incomplete. Do not boot from it."
        fi
    else
        if ! kantainer_as_root dd \
            if="${image}" \
            of="${write_device}" \
            bs=4M status=progress conv=fsync; then
            kantainer_fail "writing ${device} failed after it began.
    The target may be incomplete. Do not boot from it."
        fi
    fi
    if ! kantainer_as_root sync; then
        kantainer_fail "sync failed after writing ${device}.
    The target may be incomplete. Do not boot from it."
    fi

    {
        echo
        echo "flash: ${device} is ready."
        if [[ "${host}" == "Darwin" ]]; then
            echo "Eject ${device} manually before removing it."
        fi
        echo "Boot the target machine from it with a wired network connection."
        echo "It installs itself, reboots twice, and answers on https://<its-address>:9443."
    } >&2
}

kantainer_flash_device() {
    local image="$1" device="$2" mode="$3" initial_facts="$4"
    kantainer_confirm_erase "${device}" "${mode}" "${initial_facts}"
    kantainer_mutate_target "${image}" "${device}" "${mode}" "${initial_facts}"
}

main() {
    local target="${1-}" config="${2:-kantainer.conf}"
    local device mode="ordinary" initial_facts iso staging

    case "${target}" in
        --advanced-device=*)
            mode="advanced"
            device="${target#--advanced-device=}"
            ;;
        *)
            device="${target}"
            ;;
    esac

    [[ -n "${device}" ]] ||
        kantainer_fail "no device given.
    Usage: just flash <device> [config-file]
    Advanced: just flash --advanced-device=<device> [config-file]
    List what is attached with:
        lsblk --nodeps --output NAME,MODEL,SIZE"

    kantainer_load_config "${config}"
    kantainer_validate_config "${config}"

    # Fail fast on a path that could never work, before spending a download on
    # it. What the operator is shown and confirms is read again below.
    if ! initial_facts="$(kantainer_check_device "${device}" "${mode}")"; then
        exit 1
    fi

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

    kantainer_flash_device "${staging}/installer.iso" "${device}" "${mode}" "${initial_facts}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
