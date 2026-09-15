#!/bin/bash
# macOS flash compatibility checks through the real `just flash` entry point.
# Controlled commands make the destructive ordering runnable on Linux; the
# final section adds a real disposable RAM-disk write when running on macOS.

# Fixture scripts below contain expansions evaluated by those scripts.
# shellcheck disable=SC2016

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
RAM_DEVICE=""
CREATED_CACHE=""

cleanup() {
    if [[ -n "${RAM_DEVICE}" ]]; then
        hdiutil detach "${RAM_DEVICE}" > /dev/null 2>&1 || true
    fi
    if [[ -n "${CREATED_CACHE}" ]]; then
        rm -f "${CREATED_CACHE}"
        rmdir "$(dirname "${CREATED_CACHE}")" 2> /dev/null || true
        rmdir "$(dirname "$(dirname "${CREATED_CACHE}")")" 2> /dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C kantainer-macos-flash-test < /dev/null
{
    echo "KANTAINER_USERNAME=operator"
    echo "KANTAINER_SSH_PUBLIC_KEY=$(cat "${WORK}/id.pub")"
    echo "KANTAINER_PORTAINER_PASSWORD=portable-test-password"
} > "${WORK}/operator.conf"

BIN="${WORK}/bin"
mkdir -p "${BIN}"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "%s\n" "${FIXTURE_UNAME:-Darwin}"' \
    > "${BIN}/uname"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "diskutil %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'if [[ "$1" == "unmountDisk" ]]; then' \
    '    [[ -z "${FIXTURE_FAIL_UNMOUNT-}" ]]' \
    '    exit' \
    'fi' \
    '[[ "$1" == "info" && "$2" == "-plist" ]] || exit 2' \
    'device="$3"' \
    '[[ "${device}" == /dev/disk* || "${device}" == /dev/rdisk* ]] || exit 1' \
    '[[ "${FIXTURE_CLASS:-external}" != "missing" ]] || exit 1' \
    'changed=0' \
    'if [[ -n "${FIXTURE_CHANGE-}" ]]; then' \
    '    count=0' \
    '    [[ ! -f "${FIXTURE_INFO_COUNT}" ]] || read -r count < "${FIXTURE_INFO_COUNT}"' \
    '    count=$(( count + 1 ))' \
    '    printf "%s\n" "${count}" > "${FIXTURE_INFO_COUNT}"' \
    '    [[ "${count}" -lt 2 ]] || changed=1' \
    'fi' \
    'printf "<fixture class=\"%s\" device=\"%s\" changed=\"%s\"/>\n" "${FIXTURE_CLASS:-external}" "${device}" "${changed}"' \
    > "${BIN}/diskutil"

printf '%s\n' \
    '#!/bin/bash' \
    'key="$2"' \
    'plist="$(cat)"' \
    'class="${plist#*class=\"}"; class="${class%%\"*}"' \
    'device="${plist#*device=\"}"; device="${device%%\"*}"' \
    'changed="${plist#*changed=\"}"; changed="${changed%%\"*}"' \
    'printf "plutil %s\n" "${key}" >> "${FIXTURE_EVENT_LOG}"' \
    'case "${key}" in' \
    '    DeviceNode) printf "%s\n" "${device}" ;;' \
    '    ParentWholeDisk)' \
    '        parent="${device#/dev/}"; parent="${parent#r}"; parent="${parent%%s[0-9]*}"' \
    '        printf "%s\n" "${parent}"' \
    '        ;;' \
    '    WholeDisk) [[ "${class}" == "partition" ]] && printf "false\n" || printf "true\n" ;;' \
    '    Internal) [[ "${class}" == "internal" ]] && printf "true\n" || printf "false\n" ;;' \
    '    VirtualOrPhysical) [[ "${class}" == "virtual" ]] && printf "Virtual\n" || printf "Physical\n" ;;' \
    '    MediaName)' \
    '        [[ "${class}" != "incomplete" ]] || exit 1' \
    '        [[ "${changed}" == 0 ]] && printf "Fixture USB\n" || printf "Replacement Disk\n"' \
    '        ;;' \
    '    TotalSize) [[ "${class}" != "incomplete" ]] && printf "32000000000\n" || exit 1 ;;' \
    '    *) exit 1 ;;' \
    'esac' \
    > "${BIN}/plutil"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "docker %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'if [[ "$1" == "info" ]]; then' \
    '    [[ -n "${FIXTURE_DOCKER_USABLE-}" ]]' \
    '    exit' \
    'fi' \
    '[[ "$1" == "run" ]] || exit 2' \
    'out=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '    if [[ "$1" == "--volume" && "$2" == *:/out:rw ]]; then' \
    '        out="${2%:/out:rw}"' \
    '        shift 2' \
    '    else' \
    '        shift' \
    '    fi' \
    'done' \
    '[[ -n "${out}" ]] || exit 2' \
    'if [[ -n "${FIXTURE_DOCKER_FAIL-}" ]]; then' \
    '    printf partial > "${out}/installer.iso"' \
    '    exit 1' \
    'fi' \
    'i=0' \
    'while [[ "${i}" -lt 4096 ]]; do printf x; i=$(( i + 1 )); done > "${out}/installer.iso"' \
    '[[ -z "${FIXTURE_UNALIGNED-}" ]] || printf y >> "${out}/installer.iso"' \
    > "${BIN}/docker"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "podman %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'if [[ "$1" == "info" ]]; then' \
    '    [[ -n "${FIXTURE_PODMAN_USABLE-}" ]]' \
    '    exit' \
    'fi' \
    '[[ "$1" == "run" ]] || exit 2' \
    'out=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '    if [[ "$1" == "--volume" && "$2" == *:/out:rw ]]; then' \
    '        out="${2%:/out:rw}"' \
    '        shift 2' \
    '    else' \
    '        shift' \
    '    fi' \
    'done' \
    '[[ -n "${out}" ]] || exit 2' \
    'if [[ -e "${out}/installer.iso" ]]; then' \
    '    printf "podman stale-output\n" >> "${FIXTURE_EVENT_LOG}"' \
    '    exit 3' \
    'fi' \
    'if [[ -n "${FIXTURE_PODMAN_FAIL-}" ]]; then' \
    '    printf partial > "${out}/installer.iso"' \
    '    exit 1' \
    'fi' \
    'i=0' \
    'while [[ "${i}" -lt 4096 ]]; do printf x; i=$(( i + 1 )); done > "${out}/installer.iso"' \
    '[[ -z "${FIXTURE_UNALIGNED-}" ]] || printf y >> "${out}/installer.iso"' \
    > "${BIN}/podman"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "curl\n" >> "${FIXTURE_EVENT_LOG}"' \
    'output=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '    case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac' \
    'done' \
    '[[ -n "${output}" ]] || exit 2' \
    'printf fixture-installer > "${output}"' \
    > "${BIN}/curl"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "shasum %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'exit 0' \
    > "${BIN}/shasum"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "{}\n"' \
    > "${BIN}/butane"

printf '%s\n' \
    '#!/bin/bash' \
    'exec "$@"' \
    > "${BIN}/sudo"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "dd %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    '[[ -z "${FIXTURE_FAIL_WRITE-}" ]]' \
    > "${BIN}/dd"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "sync\n" >> "${FIXTURE_EVENT_LOG}"' \
    '[[ -z "${FIXTURE_FAIL_SYNC-}" ]]' \
    > "${BIN}/sync"

chmod +x "${BIN}"/*

EVENT_LOG="${WORK}/events.log"
INFO_COUNT="${WORK}/info-count"
FIXTURE_PATH="${BIN}:${PATH}"
FIXTURE_DOCKER_FAIL=""
FIXTURE_DOCKER_USABLE=""
FIXTURE_PODMAN_FAIL=""
FIXTURE_PODMAN_USABLE="1"

# fetch-installer's cache lives under the repository by design. Remove only
# the exact fixture file this test creates, and leave a pre-existing cache
# untouched.
# shellcheck source=/dev/null
. "${REPO_ROOT}/versions.env"
CACHE_FILE="${REPO_ROOT}/output/installer/fedora-coreos-${FCOS_VERSION}-live-iso.x86_64.iso"
if [[ ! -e "${CACHE_FILE}" ]]; then
    CREATED_CACHE="${CACHE_FILE}"
fi

reset_fixture() {
    : > "${EVENT_LOG}"
    rm -f "${INFO_COUNT}"
    FIXTURE_DOCKER_FAIL=""
    FIXTURE_DOCKER_USABLE=""
    FIXTURE_PODMAN_FAIL=""
    FIXTURE_PODMAN_USABLE="1"
}

run_fixture() {
    local device="$1" class="$2" input="$3" host="${4:-Darwin}" change="${5-}"
    printf '%s' "${input}" | (
        cd "${REPO_ROOT}"
        env \
            PATH="${FIXTURE_PATH}" \
            FIXTURE_UNAME="${host}" \
            FIXTURE_CLASS="${class}" \
            FIXTURE_CHANGE="${change}" \
            FIXTURE_DOCKER_FAIL="${FIXTURE_DOCKER_FAIL}" \
            FIXTURE_DOCKER_USABLE="${FIXTURE_DOCKER_USABLE}" \
            FIXTURE_EVENT_LOG="${EVENT_LOG}" \
            FIXTURE_INFO_COUNT="${INFO_COUNT}" \
            FIXTURE_PODMAN_FAIL="${FIXTURE_PODMAN_FAIL}" \
            FIXTURE_PODMAN_USABLE="${FIXTURE_PODMAN_USABLE}" \
            TMPDIR="${WORK}" \
            just flash "${device}" "${WORK}/operator.conf"
    )
}

assert_refused_before_mutation() {
    local name="$1" device="$2" class="$3" host="${4:-Darwin}"
    reset_fixture
    if run_fixture "${device}" "${class}" "" "${host}" > "${WORK}/case.out" 2> "${WORK}/case.err"; then
        not_ok "refuses ${name}"
    elif grep -Eq '^(diskutil unmountDisk|dd |sync$)' "${EVENT_LOG}"; then
        not_ok "${name} reached target mutation"
    else
        ok "refuses ${name} before target mutation"
    fi
}

assert_refused_before_mutation "an internal disk" /dev/disk0 internal
assert_refused_before_mutation "a partition" /dev/disk7s1 partition
assert_refused_before_mutation "a disk image or APFS virtual device" /dev/disk9 virtual
assert_refused_before_mutation "incomplete device facts" /dev/disk7 incomplete
assert_refused_before_mutation "a nonexistent path" /dev/disk99 missing

touch "${WORK}/regular-file"
mkdir "${WORK}/mount-point"
assert_refused_before_mutation "a regular file" "${WORK}/regular-file" external
assert_refused_before_mutation "a mount point" "${WORK}/mount-point" external
assert_refused_before_mutation "a bare device name" disk7 external
assert_refused_before_mutation "an unknown platform" /dev/disk7 external Plan9

assert_runtime_success() {
    local name="$1" selected="$2" docker_usable="$3" podman_usable="$4" other runtime_command
    reset_fixture
    FIXTURE_DOCKER_USABLE="${docker_usable}"
    FIXTURE_PODMAN_USABLE="${podman_usable}"
    if [[ "${selected}" == "docker" ]]; then
        other="podman"
    else
        other="docker"
    fi

    runtime_command=""
    if run_fixture /dev/disk7 external $'/dev/disk7\n' \
            > "${WORK}/runtime.out" 2> "${WORK}/runtime.err" &&
        runtime_command="$(grep "^${selected} run " "${EVENT_LOG}")" &&
        [[ "$(grep -c "^${selected} run " "${EVENT_LOG}")" -eq 1 ]] &&
        grep -q "^${selected} run " "${EVENT_LOG}" &&
        ! grep -q "^${other} run " "${EVENT_LOG}" &&
        [[ "${runtime_command}" == *" --volume ${REPO_ROOT}/output/installer:/iso:ro "* ]] &&
        [[ "${runtime_command}" == *" --volume "*":/out:rw "* ]] &&
        [[ "${runtime_command}" == *" ${COREOS_INSTALLER_IMAGE}@${COREOS_INSTALLER_DIGEST} iso customize --live-ignition /out/installer.ign --output /out/installer.iso /iso/"* ]] &&
        grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
        grep -q '^sync$' "${EVENT_LOG}" &&
        { [[ "${selected}" == "podman" && "${runtime_command}" == *" --security-opt label=disable "* ]] ||
          [[ "${selected}" == "docker" && "${runtime_command}" != *" --security-opt "* ]]; }; then
        ok "${name}"
    else
        not_ok "${name}"
        cat "${WORK}/runtime.err" >&2
        cat "${EVENT_LOG}" >&2
    fi
}

assert_runtime_success "Docker-only macOS uses Docker" docker 1 ""
assert_runtime_success "Podman-only macOS uses Podman" podman "" 1
assert_runtime_success "macOS prefers Docker when both runtimes are usable" docker 1 1

reset_fixture
FIXTURE_DOCKER_USABLE=""
FIXTURE_PODMAN_USABLE=""
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/no-runtime.out" 2> "${WORK}/no-runtime.err"; then
    not_ok "refuses macOS with no usable runtime"
elif grep -qF 'Docker Desktop' "${WORK}/no-runtime.err" &&
    grep -qF 'Podman' "${WORK}/no-runtime.err" &&
    ! grep -Eq '^(docker|podman) run |^diskutil unmountDisk|^dd |^sync$' "${EVENT_LOG}"; then
    ok "refuses macOS with no usable runtime before target mutation"
else
    not_ok "refuses macOS with no usable runtime before target mutation"
    cat "${WORK}/no-runtime.err" >&2
    cat "${EVENT_LOG}" >&2
fi

target_was_mutated() {
    grep -Eq '^diskutil unmountDisk|^dd |^sync$' "${EVENT_LOG}"
}

reset_fixture
FIXTURE_DOCKER_FAIL="1"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external $'podman\n/dev/disk7\n' \
        > "${WORK}/retry.out" 2> "${WORK}/retry.err" &&
    grep -qF 'Docker Desktop could not personalise the installer' "${WORK}/retry.err" &&
    grep -qF 'Type podman to retry with Podman' "${WORK}/retry.err" &&
    grep -q '^docker run ' "${EVENT_LOG}" &&
    grep -q '^podman run ' "${EVENT_LOG}" &&
    ! grep -q '^podman stale-output$' "${EVENT_LOG}" &&
    grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}"; then
    ok "an accepted Docker failure retry uses Podman and reaches the safe write flow"
else
    not_ok "an accepted Docker failure retry uses Podman and reaches the safe write flow"
    cat "${WORK}/retry.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_DOCKER_FAIL="1"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external $'no\n' \
        > "${WORK}/retry-decline.out" 2> "${WORK}/retry-decline.err"; then
    not_ok "a declined Podman retry is terminal"
elif grep -qF 'Docker Desktop could not personalise the installer' "${WORK}/retry-decline.err" &&
    grep -qF 'Podman retry declined' "${WORK}/retry-decline.err" &&
    ! grep -q '^podman run ' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "a declined Podman retry stops before target mutation"
else
    not_ok "a declined Podman retry stops before target mutation"
fi

reset_fixture
FIXTURE_DOCKER_FAIL="1"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external "" \
        > "${WORK}/retry-eof.out" 2> "${WORK}/retry-eof.err"; then
    not_ok "EOF at the Podman retry is terminal"
elif grep -qF 'Docker Desktop could not personalise the installer' "${WORK}/retry-eof.err" &&
    grep -qF 'Podman retry declined' "${WORK}/retry-eof.err" &&
    ! grep -q '^podman run ' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "EOF at the Podman retry stops before target mutation"
else
    not_ok "EOF at the Podman retry stops before target mutation"
fi

reset_fixture
FIXTURE_DOCKER_FAIL="1"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_FAIL="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external $'podman\n' \
        > "${WORK}/retry-fail.out" 2> "${WORK}/retry-fail.err"; then
    not_ok "a failed Podman retry is terminal"
elif grep -qF 'Docker Desktop could not personalise the installer' "${WORK}/retry-fail.err" &&
    grep -qF 'Podman could not personalise the installer' "${WORK}/retry-fail.err" &&
    grep -q '^docker run ' "${EVENT_LOG}" &&
    grep -q '^podman run ' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "a failed Podman retry stops before target mutation"
else
    not_ok "a failed Podman retry stops before target mutation"
fi

reset_fixture
FIXTURE_DOCKER_FAIL="1"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE=""
if run_fixture /dev/disk7 external $'podman\n/dev/disk7\n' \
        > "${WORK}/retry-unavailable.out" 2> "${WORK}/retry-unavailable.err"; then
    not_ok "Docker failure without usable Podman is terminal"
elif grep -qF 'Docker Desktop could not personalise the installer' "${WORK}/retry-unavailable.err" &&
    grep -qF 'Podman is not usable' "${WORK}/retry-unavailable.err" &&
    ! grep -qF 'Type podman to retry' "${WORK}/retry-unavailable.err" &&
    ! grep -q '^podman run ' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "Docker failure without usable Podman stops before target mutation"
else
    not_ok "Docker failure without usable Podman stops before target mutation"
fi

reset_fixture
if run_fixture /dev/disk7 external $'/dev/disk7\n' > "${WORK}/success.out" 2> "${WORK}/success.err" &&
    grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
    grep -q 'of=/dev/rdisk7' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}" &&
    grep -qF 'Eject /dev/disk7 manually' "${WORK}/success.err"; then
    ok "the real just flash path completes the ordinary macOS flow"
else
    not_ok "the real just flash path completes the ordinary macOS flow"
    cat "${WORK}/success.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
if run_fixture --advanced-device=/dev/null external $'/dev/null\n' \
        > "${WORK}/advanced.out" 2> "${WORK}/advanced.err" &&
    grep -qF 'ADVANCED OVERRIDE' "${WORK}/advanced.err" &&
    grep -q 'of=/dev/null' "${EVENT_LOG}" &&
    ! grep -q '^diskutil unmountDisk ' "${EVENT_LOG}"; then
    ok "the real just flash path requires and displays the advanced opt-in"
else
    not_ok "the real just flash path requires and displays the advanced opt-in"
fi

reset_fixture
if run_fixture /dev/disk7 external $'/dev/disk7\n' Darwin 1 \
        > "${WORK}/changed.out" 2> "${WORK}/changed.err"; then
    not_ok "refuses a changed device through just flash"
elif grep -qF 'changed after it was first checked' "${WORK}/changed.err" &&
    ! grep -Eq '^(diskutil unmountDisk|dd |sync$)' "${EVENT_LOG}"; then
    ok "a changed device stays before mutation through just flash"
else
    not_ok "a changed device stays before mutation through just flash"
    cat "${WORK}/changed.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
if run_fixture /dev/disk7 external $'no\n' > /dev/null 2>&1; then
    not_ok "refuses a declined real confirmation"
elif ! grep -Eq '^(diskutil unmountDisk|dd |sync$)' "${EVENT_LOG}"; then
    ok "a declined real confirmation stays before mutation"
else
    not_ok "a declined real confirmation stays before mutation"
fi

reset_fixture
if run_fixture /dev/disk7 external "" > /dev/null 2>&1; then
    not_ok "refuses EOF at the real confirmation"
elif ! grep -Eq '^(diskutil unmountDisk|dd |sync$)' "${EVENT_LOG}"; then
    ok "EOF at the real confirmation stays before mutation"
else
    not_ok "EOF at the real confirmation stays before mutation"
fi

### real disposable device evidence when the test itself is on macOS

if [[ "$(uname -s)" == "Darwin" ]]; then
    RAM_DEVICE="$(hdiutil attach -nomount ram://32768 | awk 'NR == 1 { print $1 }')"
    RAM_IMAGE="${WORK}/ram-image.iso"
    RAM_READBACK="${WORK}/ram-readback.iso"
    dd if=/dev/zero of="${RAM_IMAGE}" bs=4096 count=1 2> /dev/null

    ram_facts="$(kantainer_check_device "${RAM_DEVICE}" advanced)"
    if ram_output="$(printf '%s\n' "${RAM_DEVICE}" |
            kantainer_flash_device "${RAM_IMAGE}" "${RAM_DEVICE}" advanced "${ram_facts}" 2>&1)" &&
        kantainer_as_root dd if="/dev/r${RAM_DEVICE#/dev/}" of="${RAM_READBACK}" bs=4096 count=1 2> /dev/null &&
        cmp -s "${RAM_IMAGE}" "${RAM_READBACK}" &&
        [[ "${ram_output}" == *"Eject ${RAM_DEVICE} manually"* ]]; then
        ok "advanced mode writes and syncs every byte on a disposable macOS RAM disk"
    else
        not_ok "advanced mode writes and syncs every byte on a disposable macOS RAM disk"
    fi
else
    ok "macOS RAM-disk evidence is deferred to the macOS runner"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "the macOS flash entry point behaves as intended"
else
    echo "${failures} macOS flash check(s) misbehaved"
    exit 1
fi
