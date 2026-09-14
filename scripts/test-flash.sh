#!/bin/bash
# Tests for flash.sh (SPEC.md §spec:installer-media).
#
# `just flash` is the one command in this repository that destroys something.
# Everything it does before the write must be reachable without a USB stick, or
# it can only be tested by losing a disk - so the script is SOURCED here and the
# one function that reads real hardware is replaced with fixtures. main() is
# what calls dd, and sourcing deliberately does not run it.
#
# What these cannot cover is the write itself and the container that builds the
# media: both need hardware and a 1.3 GB download. The refusal that matters most
# there - a corrupted installer - is proved in scripts/test-installer.sh against
# the same code this command calls.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLASH="${REPO_ROOT}/scripts/flash.sh"

# shellcheck source=/dev/null
. "${FLASH}"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

### the macOS provider boundary is diskutil plist data read through plutil

PROVIDER_LOG="${WORK}/provider.log"

# Invoked indirectly through the production provider.
# shellcheck disable=SC2329
diskutil() {
    printf 'diskutil %s\n' "$*" >> "${PROVIDER_LOG}"
    printf '%s\n' '<plist>fixture</plist>'
}

# Invoked indirectly through the production provider.
# shellcheck disable=SC2329
plutil() {
    local key="$2"
    printf 'plutil %s\n' "${key}" >> "${PROVIDER_LOG}"
    # Consume the plist from stdin, as the real command does.
    while IFS= read -r _line; do :; done
    case "${key}" in
        DeviceNode) printf '%s\n' /dev/disk7 ;;
        ParentWholeDisk) printf '%s\n' disk7 ;;
        Whole) printf '%s\n' true ;;
        Internal) printf '%s\n' false ;;
        VirtualOrPhysical) printf '%s\n' Physical ;;
        MediaName) printf '%s\n' 'External USB' ;;
        DiskSize) printf '%s\n' 32000000000 ;;
        *) return 1 ;;
    esac
}

provider_facts="$(kantainer_darwin_device_facts /dev/disk7)"
if [[ "${provider_facts}" == $'Darwin\tdisk\tExternal USB\t32000000000\t/dev/disk7\tfalse\tPhysical\t/dev/disk7' ]]; then
    ok "normalizes macOS diskutil plist facts"
else
    not_ok "normalizes macOS diskutil plist facts (got: ${provider_facts})"
fi

if grep -qF 'diskutil info -plist /dev/disk7' "${PROVIDER_LOG}" &&
    grep -qF 'plutil DeviceNode' "${PROVIDER_LOG}" &&
    grep -qF 'plutil VirtualOrPhysical' "${PROVIDER_LOG}"; then
    ok "obtains macOS identity through diskutil and plutil"
else
    not_ok "obtains macOS identity through diskutil and plutil"
fi

unset -f diskutil plutil

# The normalized device-fact record produced from lsblk or diskutil. An empty
# type stands for a provider that could not read the target at all.
FIXTURE_HOST="Linux"
FIXTURE_TYPE=""
FIXTURE_MODEL=""
FIXTURE_SIZE=""
FIXTURE_WHOLE=""
FIXTURE_INTERNAL=""
FIXTURE_PHYSICAL=""
FIXTURE_CANONICAL=""
FIXTURE_IS_NODE=""

kantainer_host() {
    printf '%s\n' "${FIXTURE_HOST}"
}

kantainer_device_facts() {
    [[ -n "${FIXTURE_TYPE}" ]] || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${FIXTURE_HOST}" "${FIXTURE_TYPE}" "${FIXTURE_MODEL}" \
        "${FIXTURE_SIZE}" "${FIXTURE_WHOLE}" "${FIXTURE_INTERNAL}" \
        "${FIXTURE_PHYSICAL}" "${FIXTURE_CANONICAL}"
}

kantainer_device_node_exists() {
    [[ -n "${FIXTURE_IS_NODE}" ]]
}

linux_facts() {
    FIXTURE_HOST="Linux"
    FIXTURE_TYPE="$1"
    FIXTURE_MODEL="$2"
    FIXTURE_SIZE="$3"
    FIXTURE_WHOLE="$4"
    FIXTURE_INTERNAL="unknown"
    FIXTURE_PHYSICAL="unknown"
    FIXTURE_CANONICAL="$5"
    FIXTURE_IS_NODE=""
}

darwin_facts() {
    FIXTURE_HOST="Darwin"
    FIXTURE_TYPE="$1"
    FIXTURE_MODEL="$2"
    FIXTURE_SIZE="$3"
    FIXTURE_WHOLE="$4"
    FIXTURE_INTERNAL="$5"
    FIXTURE_PHYSICAL="$6"
    FIXTURE_CANONICAL="$7"
    FIXTURE_IS_NODE="1"
}

### what the command refuses before it touches anything

# lsblk's own verdict covers a path that does not exist and a path that is not a
# block device. One refusal, not two checks of ours that could disagree with it.
linux_facts "" "" "" "" ""
if err="$( ( kantainer_check_device /dev/definitely-not-here ) 2>&1 >/dev/null )"; then
    not_ok "refuses a path that is not a block device"
else
    ok "refuses a path that is not a block device"
    if [[ "${err}" == *"/dev/definitely-not-here"* ]]; then
        ok "names the path it refused"
    else
        not_ok "names the path it refused"
    fi
fi

# An ISO written to a partition has no boot sector, so the machine boots into
# whatever was there before and the operator has no idea why.
linux_facts part "Kingston DataTraveler" 28.9G /dev/sdb /dev/sdb1
if err="$( ( kantainer_check_device /dev/sdb1 ) 2>&1 >/dev/null )"; then
    not_ok "refuses a partition rather than a whole drive"
else
    ok "refuses a partition rather than a whole drive"
    if [[ "${err}" == *"/dev/sdb"* ]]; then
        ok "names the whole drive the operator probably meant"
    else
        not_ok "names the whole drive the operator probably meant"
    fi
fi

# A partition is not the only thing that is not a drive. Writing an installer to
# a loop device, an LVM volume or a RAID member fails for exactly the same reason
# - nothing boots from it - and dd would have destroyed the backing store first.
for kind in loop dm raid1 rom; do
    linux_facts "${kind}" unknown 28.9G unknown /dev/whatever
    if err="$( ( kantainer_check_device /dev/whatever ) 2>&1 >/dev/null )"; then
        not_ok "refuses a ${kind} device, which is not a whole drive either"
    else
        if [[ "${err}" == *"${kind}"* ]]; then
            ok "refuses a ${kind} device and says what it saw"
        else
            not_ok "refuses a ${kind} device but does not say what it saw (got: ${err})"
        fi
    fi
done

# No guessing beyond that. A spare stick and the only backup drive look
# identical from here, and choosing between them is the operator's to do.
linux_facts disk "Kingston DataTraveler" 28.9G /dev/sdb /dev/sdb
if got="$(kantainer_check_device /dev/sdb 2>/dev/null)" &&
    [[ "${got}" == $'Linux\tdisk\tKingston DataTraveler\t28.9G\t/dev/sdb\tunknown\tunknown\t/dev/sdb' ]]; then
    ok "accepts a whole drive and reports what it is"
else
    not_ok "accepts a whole drive and reports what it is (got: ${got:-refused})"
fi

### macOS ordinary and advanced target policy

darwin_facts disk "External USB" 32000000000 /dev/disk7 false Physical /dev/disk7
if kantainer_check_device /dev/disk7 > /dev/null 2>&1; then
    ok "accepts an external whole physical macOS disk"
else
    not_ok "accepts an external whole physical macOS disk"
fi

darwin_facts disk "Macintosh HD" 1000000000000 /dev/disk0 true Physical /dev/disk0
if err="$( ( kantainer_check_device /dev/disk0 ) 2>&1 >/dev/null )"; then
    not_ok "refuses an internal macOS disk"
elif [[ "${err}" == *"internal"* && "${err}" == *"/dev/disk0"* ]]; then
    ok "refuses an internal macOS disk and names it"
else
    not_ok "refuses an internal macOS disk with a useful reason (got: ${err})"
fi

darwin_facts part "USB volume" 16000000000 /dev/disk7 false Physical /dev/disk7s1
if err="$( ( kantainer_check_device /dev/disk7s1 ) 2>&1 >/dev/null )"; then
    not_ok "refuses a macOS partition"
elif [[ "${err}" == *"partition"* && "${err}" == *"/dev/disk7"* ]]; then
    ok "refuses a macOS partition and names its whole disk"
else
    not_ok "refuses a macOS partition with a useful reason (got: ${err})"
fi

darwin_facts disk "Apple Disk Image" 32000000 /dev/disk9 false Virtual /dev/disk9
if err="$( ( kantainer_check_device /dev/disk9 ) 2>&1 >/dev/null )"; then
    not_ok "refuses a virtual macOS disk"
elif [[ "${err}" == *"virtual"* && "${err}" == *"/dev/disk9"* ]]; then
    ok "refuses a virtual macOS disk and names it"
else
    not_ok "refuses a virtual macOS disk with a useful reason (got: ${err})"
fi

darwin_facts disk unknown unknown unknown unknown unknown /dev/disk7
if err="$( ( kantainer_check_device /dev/disk7 ) 2>&1 >/dev/null )"; then
    not_ok "refuses incomplete macOS device facts"
elif [[ "${err}" == *"classify"* ]]; then
    ok "refuses incomplete macOS device facts"
else
    not_ok "explains incomplete macOS device facts (got: ${err})"
fi

# The advanced path bypasses the safety class, never the objective requirement
# that the supplied path is a real device node.
darwin_facts disk "Macintosh HD" 1000000000000 /dev/disk0 true Physical /dev/disk0
if kantainer_check_device /dev/disk0 advanced > /dev/null 2>&1; then
    ok "advanced mode admits an internal macOS device node"
else
    not_ok "advanced mode admits an internal macOS device node"
fi

FIXTURE_IS_NODE=""
if err="$( ( kantainer_check_device /tmp/not-a-device advanced ) 2>&1 >/dev/null )"; then
    not_ok "advanced mode refuses a regular file or directory"
elif [[ "${err}" == *"device node"* ]]; then
    ok "advanced mode still refuses anything that is not a device node"
else
    not_ok "advanced mode explains the device-node requirement (got: ${err})"
fi

FIXTURE_HOST="Plan9"
FIXTURE_TYPE="disk"
if err="$( ( kantainer_check_device /dev/sd0 ) 2>&1 >/dev/null )"; then
    not_ok "refuses an unsupported host"
elif [[ "${err}" == *"Plan9"* ]]; then
    ok "refuses an unsupported host and names it"
else
    not_ok "names the unsupported host (got: ${err})"
fi

### the confirmation

# SPEC.md and REQUIREMENTS.md §req:priorities both turn on this prompt: it is
# the last thing between the operator and the only unrecoverable failure in the
# system. It has to say what is about to be erased.
linux_facts disk "Kingston DataTraveler" 28.9G /dev/sdb /dev/sdb
prompt="$( ( kantainer_confirm_erase /dev/sdb ) < /dev/null 2>&1 || true )"
for field in "/dev/sdb" "Kingston DataTraveler" "28.9G"; do
    if [[ "${prompt}" == *"${field}"* ]]; then
        ok "the confirmation names ${field}"
    else
        not_ok "the confirmation names ${field}"
    fi
done

if printf '/dev/sdb\n' | ( kantainer_confirm_erase /dev/sdb ) > /dev/null 2>&1; then
    ok "goes ahead when the device path is typed back"
else
    not_ok "goes ahead when the device path is typed back"
fi

# "yes" is what a person types without reading. The path is what they type after
# reading it.
if printf 'yes\n' | ( kantainer_confirm_erase /dev/sdb ) > /dev/null 2>&1; then
    not_ok "refuses an answer that is not the device path"
else
    ok "refuses an answer that is not the device path"
fi

if printf '/dev/sda\n' | ( kantainer_confirm_erase /dev/sdb ) > /dev/null 2>&1; then
    not_ok "refuses a different device path"
else
    ok "refuses a different device path"
fi

if ( kantainer_confirm_erase /dev/sdb ) < /dev/null > /dev/null 2>&1; then
    not_ok "refuses when nobody answers"
else
    ok "refuses when nobody answers"
fi

### the confirmation describes the device NOW, not when the command started

# Minutes pass between the first look at the device and this prompt: a 1.3 GB
# download and a container that rebuilds the ISO. A stick pulled out in that
# window - or a flaky port - frees its name for whatever is plugged in next, and
# the kernel hands it straight back. Showing what lsblk said at the start would
# describe a device that is no longer there, and the operator would confirm it.
linux_facts disk "WD My Book BACKUP" 4.0T /dev/sdb /dev/sdb
prompt="$( ( kantainer_confirm_erase /dev/sdb ) < /dev/null 2>&1 || true )"
if [[ "${prompt}" == *"WD My Book BACKUP"* && "${prompt}" != *"Kingston"* ]]; then
    ok "the confirmation describes the device as it is when it asks"
else
    not_ok "the confirmation describes the device as it is when it asks"
fi

# The stick was pulled out and nothing took its name. There is nothing to
# describe, so there is nothing to confirm.
linux_facts "" "" "" "" ""
if err="$( ( kantainer_confirm_erase /dev/sdb ) < /dev/null 2>&1 )"; then
    not_ok "refuses rather than asking about a device that is gone"
else
    ok "refuses rather than asking about a device that is gone"
fi
if [[ "${err}" != *"ABOUT TO ERASE"* ]]; then
    ok "does not prompt at all when the device is gone"
else
    not_ok "does not prompt at all when the device is gone"
fi

### the command as the operator runs it

if err="$("${FLASH}" 2>&1)"; then
    not_ok "refuses to run without a device"
else
    ok "refuses to run without a device"
    if [[ "${err}" == *"just flash"* ]]; then
        ok "says how to run it"
    else
        not_ok "says how to run it"
    fi
fi

# The configuration is checked before the device is, so a machine that could
# never be built is refused without a stick being involved at all - and the
# refusal names the field, because the operator is not looking at the file.
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C kantainer-test < /dev/null
{
    echo "KANTAINER_USERNAME=operator"
    echo "KANTAINER_PORTAINER_PASSWORD=$(head -c 24 /dev/urandom | base64)"
} > "${WORK}/incomplete.conf"

if err="$("${FLASH}" /dev/definitely-not-here "${WORK}/incomplete.conf" 2>&1)"; then
    not_ok "refuses a configuration the machine cannot be built from"
else
    ok "refuses a configuration the machine cannot be built from"
    if [[ "${err}" == *"KANTAINER_SSH_PUBLIC_KEY"* ]]; then
        ok "names the field to go and fix"
    else
        not_ok "names the field to go and fix (got: ${err})"
    fi
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all flash checks behave as intended"
else
    echo "${failures} flash check(s) misbehaved"
    exit 1
fi
