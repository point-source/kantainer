#!/bin/bash
# Controlled write-path tests for flash.sh (SPEC.md §spec:flash-target-safety).
# No real device is opened: the root-command boundary records the selected node
# and copies the fixture image to a normal file so completeness is observable.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/flash.sh"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ALIGNED="${WORK}/aligned.iso"
UNALIGNED="${WORK}/unaligned.iso"
dd if=/dev/zero of="${ALIGNED}" bs=4096 count=1 2> /dev/null
cp "${ALIGNED}" "${UNALIGNED}"
printf x >> "${UNALIGNED}"

COMMAND_LOG="${WORK}/commands.log"
WRITTEN="${WORK}/written.iso"
FAIL_UNMOUNT=""
FAIL_WRITE=""
FAIL_SYNC=""

# Called indirectly by the production mutation function.
# shellcheck disable=SC2329
diskutil() {
    printf 'diskutil %s\n' "$*" >> "${COMMAND_LOG}"
    [[ -z "${FAIL_UNMOUNT}" ]]
}

# Called indirectly by the production mutation function.
# shellcheck disable=SC2329
kantainer_as_root() {
    local command="$1" argument input="" output="" block=""
    shift
    case "${command}" in
        dd)
            for argument in "$@"; do
                case "${argument}" in
                    if=*) input="${argument#if=}" ;;
                    of=*) output="${argument#of=}" ;;
                    bs=*) block="${argument}" ;;
                esac
            done
            printf 'dd %s %s %s %s\n' "${input}" "${output}" "${block}" "$*" >> "${COMMAND_LOG}"
            [[ -z "${FAIL_WRITE}" ]] || return 1
            cp "${input}" "${WRITTEN}"
            ;;
        sync)
            printf 'sync\n' >> "${COMMAND_LOG}"
            [[ -z "${FAIL_SYNC}" ]]
            ;;
        *)
            return 2
            ;;
    esac
}

DARWIN_FACTS=$'Darwin\tdisk\tExternal USB\t32000000000\t/dev/disk7\tfalse\tPhysical\t/dev/disk7'
LINUX_FACTS=$'Linux\tdisk\tExternal USB\t29.8G\t/dev/sdb\tunknown\tunknown\t/dev/sdb'

reset_case() {
    : > "${COMMAND_LOG}"
    rm -f "${WRITTEN}"
    FAIL_UNMOUNT=""
    FAIL_WRITE=""
    FAIL_SYNC=""
}

reset_case
if output="$(kantainer_mutate_target "${ALIGNED}" /dev/disk7 ordinary "${DARWIN_FACTS}" 2>&1)" &&
    grep -qF 'diskutil unmountDisk /dev/disk7' "${COMMAND_LOG}" &&
    grep -qF ' /dev/rdisk7 ' "${COMMAND_LOG}" &&
    [[ "$(sed -n '1p' "${COMMAND_LOG}")" == 'diskutil unmountDisk /dev/disk7' ]] &&
    [[ "$(tail -n 1 "${COMMAND_LOG}")" == 'sync' ]]; then
    ok "unmounts before an aligned macOS write and selects the raw node"
else
    not_ok "unmounts before an aligned macOS write and selects the raw node"
fi

if [[ -e "${WRITTEN}" ]] && cmp -s "${ALIGNED}" "${WRITTEN}"; then
    ok "passes every aligned image byte to the write command"
else
    not_ok "passes every aligned image byte to the write command"
fi

if [[ "${output:-}" == *"Eject /dev/disk7 manually"* &&
      "${output}" == *"is ready"* &&
      "$(cat "${COMMAND_LOG}")" != *"eject"* ]]; then
    ok "reports success and instructs manual eject without ejecting"
else
    not_ok "reports success and instructs manual eject without ejecting"
fi

reset_case
if kantainer_mutate_target "${UNALIGNED}" /dev/disk7 ordinary "${DARWIN_FACTS}" \
        > /dev/null 2>&1 &&
    grep -qF ' /dev/disk7 ' "${COMMAND_LOG}" &&
    ! grep -qF ' /dev/rdisk7 ' "${COMMAND_LOG}"; then
    ok "keeps the buffered macOS node for an unaligned image"
else
    not_ok "keeps the buffered macOS node for an unaligned image"
fi

reset_case
FAIL_UNMOUNT=1
if err="$( ( kantainer_mutate_target "${ALIGNED}" /dev/disk7 ordinary "${DARWIN_FACTS}" ) 2>&1 )"; then
    not_ok "refuses when macOS cannot unmount the whole disk"
elif [[ "${err}" == *"Nothing was written"* ]] &&
    ! grep -q '^dd ' "${COMMAND_LOG}"; then
    ok "an unmount failure occurs with zero writes"
else
    not_ok "an unmount failure occurs with zero writes"
fi

reset_case
FAIL_WRITE=1
if err="$( ( kantainer_mutate_target "${ALIGNED}" /dev/disk7 ordinary "${DARWIN_FACTS}" ) 2>&1 )"; then
    not_ok "reports a macOS write failure"
elif [[ "${err}" == *"may be incomplete"* && "${err}" != *"is ready"* ]] &&
    ! grep -q '^sync$' "${COMMAND_LOG}"; then
    ok "a write failure reports a possible incomplete target without success"
else
    not_ok "a write failure reports a possible incomplete target without success"
fi

reset_case
FAIL_SYNC=1
if err="$( ( kantainer_mutate_target "${ALIGNED}" /dev/disk7 ordinary "${DARWIN_FACTS}" ) 2>&1 )"; then
    not_ok "reports a macOS durability failure"
elif [[ "${err}" == *"may be incomplete"* && "${err}" != *"is ready"* ]] &&
    grep -q '^sync$' "${COMMAND_LOG}"; then
    ok "a durability failure reports a possible incomplete target without success"
else
    not_ok "a durability failure reports a possible incomplete target without success"
fi

reset_case
if kantainer_mutate_target "${ALIGNED}" /dev/sdb ordinary "${LINUX_FACTS}" \
        > /dev/null 2>&1 &&
    grep -qF ' /dev/sdb bs=4M ' "${COMMAND_LOG}" &&
    grep -qF 'status=progress' "${COMMAND_LOG}" &&
    grep -qF 'conv=fsync' "${COMMAND_LOG}" &&
    ! grep -q '^diskutil ' "${COMMAND_LOG}" &&
    [[ "$(tail -n 1 "${COMMAND_LOG}")" == 'sync' ]]; then
    ok "preserves the Linux dd and sync contract"
else
    not_ok "preserves the Linux dd and sync contract"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all flash write checks behave as intended"
else
    echo "${failures} flash write check(s) misbehaved"
    exit 1
fi
