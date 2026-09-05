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

# lsblk's shape for one device: type, model, size, and the disk a partition
# belongs to. An empty type stands for the device lsblk could not read at all.
FIXTURE_TYPE=""
FIXTURE_MODEL=""
FIXTURE_SIZE=""
FIXTURE_PARENT=""

kantainer_device_facts() {
    [[ -n "${FIXTURE_TYPE}" ]] || return 1
    printf '%s\t%s\t%s\t%s\n' \
        "${FIXTURE_TYPE}" "${FIXTURE_MODEL}" "${FIXTURE_SIZE}" "${FIXTURE_PARENT}"
}

facts() {
    FIXTURE_TYPE="$1"
    FIXTURE_MODEL="$2"
    FIXTURE_SIZE="$3"
    FIXTURE_PARENT="$4"
}

### what the command refuses before it touches anything

# lsblk's own verdict covers a path that does not exist and a path that is not a
# block device. One refusal, not two checks of ours that could disagree with it.
facts "" "" "" ""
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
facts part "Kingston DataTraveler" 28.9G sdb
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

# No guessing beyond that. A spare stick and the only backup drive look
# identical from here, and choosing between them is the operator's to do.
facts disk "Kingston DataTraveler" 28.9G ""
if got="$(kantainer_check_device /dev/sdb 2>/dev/null)" &&
    [[ "${got}" == $'Kingston DataTraveler\t28.9G' ]]; then
    ok "accepts a whole drive and reports what it is"
else
    not_ok "accepts a whole drive and reports what it is (got: ${got:-refused})"
fi

### the confirmation

# SPEC.md and REQUIREMENTS.md §req:priorities both turn on this prompt: it is
# the last thing between the operator and the only unrecoverable failure in the
# system. It has to say what is about to be erased.
prompt="$( ( kantainer_confirm_device /dev/sdb "Kingston DataTraveler" 28.9G ) < /dev/null 2>&1 || true )"
for field in "/dev/sdb" "Kingston DataTraveler" "28.9G"; do
    if [[ "${prompt}" == *"${field}"* ]]; then
        ok "the confirmation names ${field}"
    else
        not_ok "the confirmation names ${field}"
    fi
done

if printf '/dev/sdb\n' | ( kantainer_confirm_device /dev/sdb Kingston 28.9G ) > /dev/null 2>&1; then
    ok "goes ahead when the device path is typed back"
else
    not_ok "goes ahead when the device path is typed back"
fi

# "yes" is what a person types without reading. The path is what they type after
# reading it.
if printf 'yes\n' | ( kantainer_confirm_device /dev/sdb Kingston 28.9G ) > /dev/null 2>&1; then
    not_ok "refuses an answer that is not the device path"
else
    ok "refuses an answer that is not the device path"
fi

if printf '/dev/sda\n' | ( kantainer_confirm_device /dev/sdb Kingston 28.9G ) > /dev/null 2>&1; then
    not_ok "refuses a different device path"
else
    ok "refuses a different device path"
fi

if ( kantainer_confirm_device /dev/sdb Kingston 28.9G ) < /dev/null > /dev/null 2>&1; then
    not_ok "refuses when nobody answers"
else
    ok "refuses when nobody answers"
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
