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
. "${REPO_ROOT}/scripts/ignition-lib.sh"

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

### The installer media's own configuration

# scripts/render-installer.sh produces what the USB stick boots with. Every
# assertion below is something that fails silently on a machine nobody is
# watching: a machine configuration the installer cannot read, a script systemd
# will not execute, a unit that is present but not enabled.

RENDER_INSTALLER="${REPO_ROOT}/scripts/render-installer.sh"

# Generated, never committed - this repository is public
# (REQUIREMENTS.md §req:quality-attributes).
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C kantainer-test < /dev/null
TEST_SSH_KEY="$(cat "${WORK}/id.pub")"
TEST_PASSWORD="$(head -c 24 /dev/urandom | base64)"

# Write a valid configuration carrying the KEY=value overrides that follow.
config() {
    local path="$1"
    shift
    {
        echo "KANTAINER_USERNAME=operator"
        echo "KANTAINER_SSH_PUBLIC_KEY=${TEST_SSH_KEY}"
        echo "KANTAINER_PORTAINER_PASSWORD=${TEST_PASSWORD}"
        printf '%s\n' "$@"
    } > "${path}"
}

# Ignition carries file contents as a data: URL, and butane compresses anything
# past a size threshold. scripts/ignition-lib.sh undoes both, for this file and
# for scripts/test-config.sh, so the two cannot disagree about what the machine
# will actually receive.
file_contents() { kantainer_ignition_file "$@"; }

config "${WORK}/wired.conf"
"${RENDER_INSTALLER}" "${WORK}/wired.conf" > "${WORK}/wired.ign"

# The whole of the second stage travels inside the first. If this does not come
# back as the machine configuration, the installed machine has no account, no
# key and no Portainer password, and there is no way in to find out why.
if file_contents "${WORK}/wired.ign" /etc/kantainer/machine.ign |
        jq -e --arg u operator '.passwd.users[0].name == $u' > /dev/null 2>&1; then
    ok "carries the machine configuration inside the installer media"
else
    not_ok "carries the machine configuration inside the installer media"
fi

# 384 = 0600. It holds the Portainer password in plain text.
if [[ "$(jq -r '.storage.files[] | select(.path == "/etc/kantainer/machine.ign") | .mode' "${WORK}/wired.ign")" == "384" ]]; then
    ok "keeps the machine configuration unreadable to anyone but root"
else
    not_ok "keeps the machine configuration unreadable to anyone but root"
fi

# 493 = 0755. systemd runs this; a file it cannot execute is a machine that
# stops at a login prompt having installed nothing.
if [[ "$(jq -r '.storage.files[] | select(.path == "/usr/local/bin/kantainer-install-to-disk") | .mode' "${WORK}/wired.ign")" == "493" ]]; then
    ok "makes the drive rule executable"
else
    not_ok "makes the drive rule executable"
fi

if [[ "$(file_contents "${WORK}/wired.ign" /usr/local/bin/kantainer-install-to-disk)" == "$(cat "${REPO_ROOT}/scripts/install-to-disk")" ]]; then
    ok "ships the drive rule this repository tests, byte for byte"
else
    not_ok "ships the drive rule this repository tests, byte for byte"
fi

if jq -e '.systemd.units[] | select(.name == "kantainer-install.service") | .enabled' "${WORK}/wired.ign" > /dev/null 2>&1; then
    ok "enables the first-stage installer"
else
    not_ok "enables the first-stage installer"
fi

# No drive named: the file is present and empty, which is what makes the
# installer count the drives it finds (SPEC.md §spec:drive-selection).
if [[ "$(file_contents "${WORK}/wired.ign" /etc/kantainer/target-drive)" == "" ]]; then
    ok "names no drive when the configuration names none"
else
    not_ok "names no drive when the configuration names none"
fi

config "${WORK}/named.conf" "KANTAINER_TARGET_DRIVE=/dev/nvme0n1"
"${RENDER_INSTALLER}" "${WORK}/named.conf" > "${WORK}/named.ign"

if [[ "$(file_contents "${WORK}/named.ign" /etc/kantainer/target-drive)" == "/dev/nvme0n1" ]]; then
    ok "carries the drive the configuration names"
else
    not_ok "carries the drive the configuration names"
fi

### The repository stays clean

# The installer media carries the operator's password, which is why it is built
# here and never published. Nothing of it may be left behind in a public
# repository.
before="$(git -C "${REPO_ROOT}" status --porcelain)"
"${RENDER_INSTALLER}" "${WORK}/named.conf" > /dev/null
after="$(git -C "${REPO_ROOT}" status --porcelain)"

if [[ "${before}" == "${after}" ]]; then
    ok "rendering the installer leaves the working tree untouched"
else
    not_ok "rendering the installer leaves the working tree untouched"
fi

if grep -rqF "${TEST_PASSWORD}" "${REPO_ROOT}" --exclude-dir=.git 2> /dev/null; then
    not_ok "rendering the installer leaves no secret behind in the repository"
else
    ok "rendering the installer leaves no secret behind in the repository"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all installer checks behave as intended"
else
    echo "${failures} installer check(s) misbehaved"
    exit 1
fi
