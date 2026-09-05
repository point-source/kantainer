#!/bin/bash
# Tests for fetch-installer.sh.
#
# The installer media is the one artifact this repository does not build and
# does not publish: it is Fedora CoreOS, fetched at flash time and pinned in
# versions.env (SPEC.md §spec:installer-media). The only thing standing between
# a corrupted download and a USB stick that boots into something nobody
# reviewed is the checksum comparison, so that is what these tests drive.
#
# Nothing here downloads anything. Every case is a cached file whose bytes the
# test chose, with the pin rewritten to match or to disagree - a 1.3 GB download
# has no place in a gate that runs on every change.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="${REPO_ROOT}/scripts/fetch-installer.sh"

# shellcheck source=/dev/null
. "${REPO_ROOT}/versions.env"

# Must match the name fetch-installer.sh derives from the same pin. Written out
# here rather than imported, so a change to that naming has to be made twice on
# purpose instead of once by accident.
ISO_NAME="fedora-coreos-${FCOS_VERSION}-live-iso.x86_64.iso"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

# Build a throwaway repository root carrying the one file the script reads,
# plus a cached "installer" of the test's own making. The pin is rewritten to
# the real digest of those bytes unless the caller supplies a different one.
stage() {
    local dir="$1" content="$2" pin="${3-}"

    mkdir -p "${dir}/output/installer"
    cp "${REPO_ROOT}/versions.env" "${dir}/versions.env"

    printf '%s' "${content}" > "${dir}/output/installer/${ISO_NAME}"
    if [[ -z "${pin}" ]]; then
        pin="$(printf '%s' "${content}" | sha256sum | cut -d ' ' -f 1)"
    fi
    sed -i "s/^FCOS_ISO_SHA256=.*/FCOS_ISO_SHA256=${pin}/" "${dir}/versions.env"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

### A cached installer that matches the pin is used as it is

root="${WORK}/good"
stage "${root}" "pretend this is Fedora CoreOS"

if out="$("${FETCH}" "${root}" 2> "${WORK}/good.err")"; then
    ok "accepts a cached installer that matches the pin"
else
    not_ok "accepts a cached installer that matches the pin"
    cat "${WORK}/good.err" >&2
fi

# `just flash` consumes this as a command substitution, so anything else on
# stdout becomes part of the path it tries to write to the stick.
if [[ "${out:-}" == "${root}/output/installer/${ISO_NAME}" ]]; then
    ok "prints the verified path on stdout and nothing else"
else
    not_ok "prints the verified path on stdout and nothing else (got: ${out:-})"
fi

### A cached installer that does not match the pin is refused

# Bit rot, a half-finished copy, a file swapped underneath us: from here they
# are one condition, and the answer to all of them is to stop before anything
# is written.
root="${WORK}/corrupt"
stage "${root}" "not the installer you pinned" \
    "0000000000000000000000000000000000000000000000000000000000000000"

if "${FETCH}" "${root}" > "${WORK}/corrupt.out" 2> "${WORK}/corrupt.err"; then
    not_ok "refuses a cached installer that does not match the pin"
else
    ok "refuses a cached installer that does not match the pin"
fi

if [[ ! -s "${WORK}/corrupt.out" ]]; then
    ok "prints no path when the installer does not match the pin"
else
    not_ok "prints no path when the installer does not match the pin"
fi

# The operator is being told to go and delete a file. Name it, or they cannot.
if grep -qF "${ISO_NAME}" "${WORK}/corrupt.err"; then
    ok "names the installer file it refused"
else
    not_ok "names the installer file it refused"
fi

### Truncation is the same refusal

root="${WORK}/truncated"
full="pretend this is Fedora CoreOS"
stage "${root}" "${full:0:8}" "$(printf '%s' "${full}" | sha256sum | cut -d ' ' -f 1)"

if "${FETCH}" "${root}" > /dev/null 2>&1; then
    not_ok "refuses a truncated cached installer"
else
    ok "refuses a truncated cached installer"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all installer checks behave as intended"
else
    echo "${failures} installer check(s) misbehaved"
    exit 1
fi
