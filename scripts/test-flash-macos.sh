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

# The same machine with a console password. `just flash` has to convert it on
# this host before it writes anything (SPEC.md §spec:console-password), so this
# config is what drives the container call the fixtures below answer.
CONSOLE_PASSWORD="console-test-password"
{
    cat "${WORK}/operator.conf"
    echo "KANTAINER_CONSOLE_PASSWORD=${CONSOLE_PASSWORD}"
} > "${WORK}/console.conf"

BIN="${WORK}/bin"
mkdir -p "${BIN}"

printf '%s\n' \
    '#!/bin/bash' \
    'case "${1-}" in' \
    '    -m) printf "%s\n" "${FIXTURE_ARCH:-arm64}" ;;' \
    '    *) printf "%s\n" "${FIXTURE_UNAME:-Darwin}" ;;' \
    'esac' \
    > "${BIN}/uname"

printf '%s\n' \
    '#!/bin/bash' \
    '[[ "${1-}" == "-productVersion" ]] || exit 2' \
    'printf "%s\n" "${FIXTURE_MACOS_VERSION:-26.0}"' \
    > "${BIN}/sw_vers"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "lsblk %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'printf "%s\n" "{\"blockdevices\":[{\"type\":\"disk\",\"model\":\"Fixture Linux USB\",\"size\":\"32G\",\"pkname\":null}]}"' \
    > "${BIN}/lsblk"

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
    'for arg in "$@"; do' \
    '    [[ "${arg}" == "--entrypoint" ]] || continue' \
    '    cat > "${FIXTURE_HASH_STDIN}"' \
    '    [[ -z "${FIXTURE_DOCKER_HASH_FAIL-}" ]] || exit 1' \
    '    printf "%s\n" "${FIXTURE_HASH_OUTPUT}"' \
    '    exit 0' \
    'done' \
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
    'for arg in "$@"; do' \
    '    [[ "${arg}" == "--entrypoint" ]] || continue' \
    '    cat > "${FIXTURE_HASH_STDIN}"' \
    '    [[ -z "${FIXTURE_PODMAN_HASH_FAIL-}" ]] || exit 1' \
    '    printf "%s\n" "${FIXTURE_HASH_OUTPUT}"' \
    '    exit 0' \
    'done' \
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
    'printf "sha256sum %s\n" "$*" >> "${FIXTURE_EVENT_LOG}"' \
    'exit 0' \
    > "${BIN}/sha256sum"

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
    'input=""' \
    'for arg in "$@"; do' \
    '    case "${arg}" in if=*) input="${arg#if=}" ;; esac' \
    'done' \
    '[[ -n "${input}" ]] || exit 2' \
    '[[ -z "${FIXTURE_FAIL_WRITE-}" ]] || exit 1' \
    'cp "${input}" "${FIXTURE_WRITE_CAPTURE}"' \
    > "${BIN}/dd"

printf '%s\n' \
    '#!/bin/bash' \
    'printf "sync\n" >> "${FIXTURE_EVENT_LOG}"' \
    '[[ -z "${FIXTURE_FAIL_SYNC-}" ]]' \
    > "${BIN}/sync"

chmod +x "${BIN}"/*

EVENT_LOG="${WORK}/events.log"
INFO_COUNT="${WORK}/info-count"
WRITE_CAPTURE="${WORK}/written-installer.iso"
# What the fake runtimes were handed on stdin for the hash run, and what they
# hand back. A fixed hash rather than a real one: a $6$ salt is random and these
# assertions are exact.
HASH_STDIN="${WORK}/hash-stdin"
# shellcheck disable=SC2016  # `$6$` is crypt's literal method marker
FIXTURE_HASH_VALUE='$6$fixturesalt$fixtureHASHvalue0123456789'
ALIGNED_EXPECTED="${WORK}/aligned-installer.iso"
UNALIGNED_EXPECTED="${WORK}/unaligned-installer.iso"
FIXTURE_PATH="${BIN}:${PATH}"
FIXTURE_ARCH="arm64"
FIXTURE_DOCKER_FAIL=""
FIXTURE_DOCKER_USABLE=""
FIXTURE_FAIL_SYNC=""
FIXTURE_FAIL_UNMOUNT=""
FIXTURE_FAIL_WRITE=""
FIXTURE_UNALIGNED=""
FIXTURE_PODMAN_FAIL=""
FIXTURE_PODMAN_USABLE="1"
FIXTURE_MACOS_VERSION="26.0"
FIXTURE_DOCKER_HASH_FAIL=""
FIXTURE_PODMAN_HASH_FAIL=""
FIXTURE_CONFIG="${WORK}/operator.conf"

i=0
while [[ "${i}" -lt 4096 ]]; do
    printf x
    i=$(( i + 1 ))
done > "${ALIGNED_EXPECTED}"
cp "${ALIGNED_EXPECTED}" "${UNALIGNED_EXPECTED}"
printf y >> "${UNALIGNED_EXPECTED}"

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
    rm -f "${INFO_COUNT}" "${WRITE_CAPTURE}" "${HASH_STDIN}"
    FIXTURE_DOCKER_HASH_FAIL=""
    FIXTURE_PODMAN_HASH_FAIL=""
    FIXTURE_CONFIG="${WORK}/operator.conf"
    FIXTURE_ARCH="arm64"
    FIXTURE_DOCKER_FAIL=""
    FIXTURE_DOCKER_USABLE=""
    FIXTURE_FAIL_SYNC=""
    FIXTURE_FAIL_UNMOUNT=""
    FIXTURE_FAIL_WRITE=""
    FIXTURE_UNALIGNED=""
    FIXTURE_PODMAN_FAIL=""
    FIXTURE_PODMAN_USABLE="1"
    FIXTURE_MACOS_VERSION="26.0"
}

run_fixture() {
    local device="$1" class="$2" input="$3" host="${4:-Darwin}" change="${5-}"
    printf '%s' "${input}" | (
        cd "${REPO_ROOT}"
        env \
            PATH="${FIXTURE_PATH}" \
            FIXTURE_ARCH="${FIXTURE_ARCH}" \
            FIXTURE_UNAME="${host}" \
            FIXTURE_CLASS="${class}" \
            FIXTURE_CHANGE="${change}" \
            FIXTURE_DOCKER_FAIL="${FIXTURE_DOCKER_FAIL}" \
            FIXTURE_DOCKER_USABLE="${FIXTURE_DOCKER_USABLE}" \
            FIXTURE_EVENT_LOG="${EVENT_LOG}" \
            FIXTURE_FAIL_SYNC="${FIXTURE_FAIL_SYNC}" \
            FIXTURE_FAIL_UNMOUNT="${FIXTURE_FAIL_UNMOUNT}" \
            FIXTURE_FAIL_WRITE="${FIXTURE_FAIL_WRITE}" \
            FIXTURE_INFO_COUNT="${INFO_COUNT}" \
            FIXTURE_MACOS_VERSION="${FIXTURE_MACOS_VERSION}" \
            FIXTURE_PODMAN_FAIL="${FIXTURE_PODMAN_FAIL}" \
            FIXTURE_PODMAN_USABLE="${FIXTURE_PODMAN_USABLE}" \
            FIXTURE_UNALIGNED="${FIXTURE_UNALIGNED}" \
            FIXTURE_WRITE_CAPTURE="${WRITE_CAPTURE}" \
            FIXTURE_DOCKER_HASH_FAIL="${FIXTURE_DOCKER_HASH_FAIL}" \
            FIXTURE_PODMAN_HASH_FAIL="${FIXTURE_PODMAN_HASH_FAIL}" \
            FIXTURE_HASH_OUTPUT="${FIXTURE_HASH_VALUE}" \
            FIXTURE_HASH_STDIN="${HASH_STDIN}" \
            TMPDIR="${WORK}" \
            just flash "${device}" "${FIXTURE_CONFIG}"
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

reset_fixture
FIXTURE_ARCH="x86_64"
if run_fixture /dev/disk7 external "" > "${WORK}/case.out" 2> "${WORK}/case.err"; then
    not_ok "refuses an Intel Mac"
elif grep -q "Apple-silicon Mac" "${WORK}/case.err" && [[ ! -s "${EVENT_LOG}" ]]; then
    ok "refuses an Intel Mac before inspecting or changing the target"
else
    not_ok "explains the Apple-silicon requirement before touching the target"
fi

reset_fixture
FIXTURE_MACOS_VERSION="25.9"
if run_fixture /dev/disk7 external "" > "${WORK}/case.out" 2> "${WORK}/case.err"; then
    not_ok "refuses an older macOS release"
elif grep -q "macOS 26 or newer" "${WORK}/case.err" && [[ ! -s "${EVENT_LOG}" ]]; then
    ok "refuses an older macOS release before inspecting or changing the target"
else
    not_ok "explains the macOS version requirement before touching the target"
fi

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
    grep -q '^sync$' "${EVENT_LOG}" &&
    docker_run_line="$(grep -n '^docker run ' "${EVENT_LOG}" | cut -d: -f1)" &&
    podman_run_line="$(grep -n '^podman run ' "${EVENT_LOG}" | cut -d: -f1)" &&
    unmount_line="$(grep -n '^diskutil unmountDisk ' "${EVENT_LOG}" | cut -d: -f1)" &&
    write_line="$(grep -n '^dd ' "${EVENT_LOG}" | cut -d: -f1)" &&
    sync_line="$(grep -n '^sync$' "${EVENT_LOG}" | cut -d: -f1)" &&
    (( docker_run_line < podman_run_line &&
       podman_run_line < unmount_line &&
       unmount_line < write_line &&
       write_line < sync_line )); then
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
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/sdb external $'/dev/sdb\n' Linux \
        > "${WORK}/linux.out" 2> "${WORK}/linux.err" &&
    grep -q '^podman info$' "${EVENT_LOG}" &&
    grep -q '^podman run ' "${EVENT_LOG}" &&
    ! grep -q '^docker ' "${EVENT_LOG}" &&
    ! grep -qF 'retry with Podman' "${WORK}/linux.err" &&
    grep -q 'of=/dev/sdb' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}"; then
    ok "Linux uses Podman and ignores Docker through the real flash path"
else
    not_ok "Linux uses Podman and ignores Docker through the real flash path"
    cat "${WORK}/linux.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_USABLE=""
if run_fixture /dev/sdb external $'/dev/sdb\n' Linux \
        > "${WORK}/linux-no-podman.out" 2> "${WORK}/linux-no-podman.err"; then
    not_ok "Linux refuses to replace unavailable Podman with Docker"
elif grep -qF 'Podman is not usable' "${WORK}/linux-no-podman.err" &&
    ! grep -q '^docker ' "${EVENT_LOG}" &&
    ! grep -qF 'retry with Podman' "${WORK}/linux-no-podman.err" &&
    ! target_was_mutated; then
    ok "Linux requires Podman without offering Docker or a retry"
else
    not_ok "Linux requires Podman without offering Docker or a retry"
fi

reset_fixture
FIXTURE_DOCKER_USABLE="1"
FIXTURE_PODMAN_FAIL="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/sdb external $'/dev/sdb\n' Linux \
        > "${WORK}/linux-podman-fail.out" 2> "${WORK}/linux-podman-fail.err"; then
    not_ok "Linux Podman personalisation failure is terminal"
elif grep -qF 'Podman could not personalise the installer' "${WORK}/linux-podman-fail.err" &&
    grep -q '^podman run ' "${EVENT_LOG}" &&
    ! grep -q '^docker ' "${EVENT_LOG}" &&
    ! grep -qF 'retry with Podman' "${WORK}/linux-podman-fail.err" &&
    ! target_was_mutated; then
    ok "Linux Podman failure stops before mutation without a retry prompt"
else
    not_ok "Linux Podman failure stops before mutation without a retry prompt"
fi

### the console password, converted on THIS host before anything is written

# SPEC.md §spec:console-password. The conversion happens here, in the
# coreos-installer container `just flash` already pulls, so no readable console
# password ever reaches the stick. Everything below drives the real flash path
# with the fake runtimes answering the hash run.

reset_fixture
FIXTURE_CONFIG="${WORK}/console.conf"
FIXTURE_DOCKER_USABLE="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/hash.out" 2> "${WORK}/hash.err" &&
    hash_command="$(grep -m 1 '^docker run .*--entrypoint' "${EVENT_LOG}")" &&
    [[ "${hash_command}" == *" --entrypoint bash "* ]] &&
    [[ "${hash_command}" == *" ${COREOS_INSTALLER_IMAGE}@${COREOS_INSTALLER_DIGEST} "* ]] &&
    [[ "${hash_command}" != *" --volume "* ]]; then
    ok "hashes the console password in the image the flash command already pulls"
else
    not_ok "hashes the console password in the image the flash command already pulls"
    cat "${WORK}/hash.err" >&2
    cat "${EVENT_LOG}" >&2
fi

# The promise that the readable password reaches no artifact starts here: it
# goes in on stdin, never in an argument, because /proc/<pid>/cmdline is
# readable by anyone on the host while /proc/<pid>/environ is not.
if [[ "$(cat "${HASH_STDIN}")" == "${CONSOLE_PASSWORD}" ]] &&
    ! grep -qF "${CONSOLE_PASSWORD}" "${EVENT_LOG}"; then
    ok "hands the password on stdin and puts it in no command line"
else
    not_ok "hands the password on stdin and puts it in no command line"
fi

# Before the installer is fetched and before the ISO is built. A conversion that
# cannot happen costs the operator nothing if it is discovered here.
#
# Matched against the checksum rather than curl: fetch-installer.sh verifies the
# cached ISO on every run but only downloads when the cache is cold, and an
# earlier case in this file has already warmed it.
hash_line="$(grep -n -m 1 -- '--entrypoint' "${EVENT_LOG}" | cut -d: -f1 || true)"
fetch_line="$(grep -nE -m 1 '^(sha256sum|shasum|curl)' "${EVENT_LOG}" | cut -d: -f1 || true)"
iso_line="$(grep -n -m 1 '^docker run .*iso customize' "${EVENT_LOG}" | cut -d: -f1 || true)"
if [[ -n "${hash_line}" && -n "${fetch_line}" && -n "${iso_line}" ]] &&
    (( hash_line < fetch_line && fetch_line < iso_line )); then
    ok "converts the password before fetching the installer or building it"
else
    not_ok "converts the password before fetching the installer or building it"
    cat "${EVENT_LOG}" >&2
fi

# A machine with no console password calls no container to hash nothing.
reset_fixture
FIXTURE_DOCKER_USABLE="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/nohash.out" 2> "${WORK}/nohash.err" &&
    ! grep -q -- '--entrypoint' "${EVENT_LOG}" &&
    [[ ! -e "${HASH_STDIN}" ]] &&
    grep -q '^sync$' "${EVENT_LOG}"; then
    ok "a blank console password runs no conversion at all"
else
    not_ok "a blank console password runs no conversion at all"
    cat "${WORK}/nohash.err" >&2
fi

# The failure §spec:console-password moves onto this host: it stops here, says
# so, and writes no stick. Linux, where Podman is the only runtime and there is
# no retry to offer.
reset_fixture
FIXTURE_CONFIG="${WORK}/console.conf"
FIXTURE_PODMAN_USABLE="1"
FIXTURE_PODMAN_HASH_FAIL="1"
if run_fixture /dev/sdb external $'/dev/sdb\n' Linux \
        > "${WORK}/hashfail.out" 2> "${WORK}/hashfail.err"; then
    not_ok "a failed conversion stops the command"
elif grep -qF 'console password' "${WORK}/hashfail.err" &&
    ! grep -q '^curl$' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "a failed conversion stops before the download and writes no stick"
else
    not_ok "a failed conversion stops before the download and writes no stick"
    cat "${WORK}/hashfail.err" >&2
fi

# REQUIREMENTS.md §req:constraints: "a failed Docker attempt never falls back to
# Podman without the operator choosing that retry". That applies to this step
# too, or a Mac operator whose Docker cannot run a container loses a path the
# specification gives them.
reset_fixture
FIXTURE_CONFIG="${WORK}/console.conf"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_DOCKER_HASH_FAIL="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external $'podman\n/dev/disk7\n' \
        > "${WORK}/hashretry.out" 2> "${WORK}/hashretry.err" &&
    grep -qF 'Type podman to retry with Podman' "${WORK}/hashretry.err" &&
    grep -q '^docker run .*--entrypoint' "${EVENT_LOG}" &&
    grep -q '^podman run .*--entrypoint' "${EVENT_LOG}" &&
    grep -q '^podman run .*iso customize' "${EVENT_LOG}" &&
    ! grep -q '^docker run .*iso customize' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}"; then
    ok "an accepted Podman retry converts and then builds with Podman"
else
    not_ok "an accepted Podman retry converts and then builds with Podman"
    cat "${WORK}/hashretry.err" >&2
    cat "${EVENT_LOG}" >&2
fi

# Declined, and nothing was written.
reset_fixture
FIXTURE_CONFIG="${WORK}/console.conf"
FIXTURE_DOCKER_USABLE="1"
FIXTURE_DOCKER_HASH_FAIL="1"
FIXTURE_PODMAN_USABLE="1"
if run_fixture /dev/disk7 external $'no\n' \
        > "${WORK}/hashdecline.out" 2> "${WORK}/hashdecline.err"; then
    not_ok "a declined Podman retry stops the conversion"
elif grep -qF 'Nothing was written to /dev/disk7' "${WORK}/hashdecline.err" &&
    ! grep -q '^podman run ' "${EVENT_LOG}" &&
    ! target_was_mutated; then
    ok "a declined Podman retry writes no stick"
else
    not_ok "a declined Podman retry writes no stick"
    cat "${WORK}/hashdecline.err" >&2
fi

reset_fixture
if run_fixture /dev/disk7 external $'/dev/disk7\n' > "${WORK}/success.out" 2> "${WORK}/success.err" &&
    grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
    grep -q 'of=/dev/rdisk7' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}" &&
    cmp -s "${ALIGNED_EXPECTED}" "${WRITE_CAPTURE}" &&
    grep -qF 'Eject /dev/disk7 manually' "${WORK}/success.err"; then
    ok "the real just flash path writes every aligned byte through the raw device"
else
    not_ok "the real just flash path writes every aligned byte through the raw device"
    cat "${WORK}/success.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_UNALIGNED="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/unaligned.out" 2> "${WORK}/unaligned.err" &&
    grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
    grep -q 'of=/dev/disk7' "${EVENT_LOG}" &&
    ! grep -q 'of=/dev/rdisk7' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}" &&
    cmp -s "${UNALIGNED_EXPECTED}" "${WRITE_CAPTURE}"; then
    ok "the real just flash path writes every unaligned byte through the buffered device"
else
    not_ok "the real just flash path writes every unaligned byte through the buffered device"
    cat "${WORK}/unaligned.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_FAIL_UNMOUNT="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/unmount-failure.out" 2> "${WORK}/unmount-failure.err"; then
    not_ok "an unmount failure stops the real just flash path"
elif grep -qF 'Nothing was written to /dev/disk7' "${WORK}/unmount-failure.err" &&
    grep -q '^diskutil unmountDisk /dev/disk7$' "${EVENT_LOG}" &&
    ! grep -Eq '^dd |^sync$' "${EVENT_LOG}" &&
    [[ ! -e "${WRITE_CAPTURE}" ]]; then
    ok "an unmount failure stops before write and sync"
else
    not_ok "an unmount failure stops before write and sync"
    cat "${WORK}/unmount-failure.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_FAIL_WRITE="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/write-failure.out" 2> "${WORK}/write-failure.err"; then
    not_ok "a write failure stops the real just flash path"
elif grep -qF 'The target may be incomplete' "${WORK}/write-failure.err" &&
    grep -q '^dd ' "${EVENT_LOG}" &&
    ! grep -q '^sync$' "${EVENT_LOG}" &&
    ! grep -qF 'is ready' "${WORK}/write-failure.err"; then
    ok "a write failure reports a possible partial target without syncing or succeeding"
else
    not_ok "a write failure reports a possible partial target without syncing or succeeding"
    cat "${WORK}/write-failure.err" >&2
    cat "${EVENT_LOG}" >&2
fi

reset_fixture
FIXTURE_FAIL_SYNC="1"
if run_fixture /dev/disk7 external $'/dev/disk7\n' \
        > "${WORK}/sync-failure.out" 2> "${WORK}/sync-failure.err"; then
    not_ok "a sync failure stops the real just flash path"
elif grep -qF 'The target may be incomplete' "${WORK}/sync-failure.err" &&
    grep -q '^dd ' "${EVENT_LOG}" &&
    grep -q '^sync$' "${EVENT_LOG}" &&
    cmp -s "${ALIGNED_EXPECTED}" "${WRITE_CAPTURE}" &&
    ! grep -qF 'is ready' "${WORK}/sync-failure.err"; then
    ok "a sync failure follows a complete write without reporting success"
else
    not_ok "a sync failure follows a complete write without reporting success"
    cat "${WORK}/sync-failure.err" >&2
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
