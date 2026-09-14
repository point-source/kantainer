#!/bin/bash
# Focused host-portability check for the real operator commands
# (SPEC.md §spec:operator-host-support).
#
# Usage: test-operator-config-compat.sh [artifact-directory]
#
# With an artifact directory, the deterministic input, outcome record and
# rendered machine specification are retained for byte comparison with another
# host. Without one, `just test` exercises the same path and removes the files.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ARTIFACTS="${1:-${WORK}/artifacts}"
mkdir -p "${ARTIFACTS}"

# Fixed public test material makes the config and rendered bytes identical on
# every host. There is no matching private key and these credentials belong to
# no machine. The compact suffix covers every literal-character promise while
# keeping the WPA passphrase inside its 63-byte limit.
LITERALS=$'\'"&\\\t $`@@ATTACH_IMAGE@@@@SSID@@@@PSK@@'
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzks6d0NfXm47Zsj5rtshvfBUn5TjFUVrULCLNug5cu fixture ${LITERALS}"
PASSWORD="portainer-test-${LITERALS}"
SSID="network-${LITERALS}"
PASSPHRASE="wireless-${LITERALS}"

VALID="${WORK}/operator.conf"
DUPLICATE="${WORK}/duplicate.conf"
RENDERED="${ARTIFACTS}/machine.ign"

printf '%s\n' \
    'KANTAINER_USERNAME=operator' \
    "KANTAINER_SSH_PUBLIC_KEY=${SSH_KEY}" \
    "KANTAINER_PORTAINER_PASSWORD=${PASSWORD}" \
    'KANTAINER_TARGET_DRIVE=' \
    "KANTAINER_WIFI_SSID=${SSID}" \
    "KANTAINER_WIFI_PASSPHRASE=${PASSPHRASE}" \
    > "${VALID}"

if ! (cd "${REPO_ROOT}" && just config-check "${VALID}") \
        > "${WORK}/check.out" 2> "${WORK}/check.err"; then
    echo "NOT OK   - just config-check rejected the portability fixture" >&2
    cat "${WORK}/check.err" >&2
    exit 1
fi
echo "ok       - just config-check accepts the portability fixture"

if ! (cd "${REPO_ROOT}" && just render "${VALID}") \
        > "${RENDERED}" 2> "${WORK}/render.err"; then
    echo "NOT OK   - just render rejected the portability fixture" >&2
    cat "${WORK}/render.err" >&2
    exit 1
fi

rendered_key="$(jq -r '.passwd.users[0].sshAuthorizedKeys[0]' < "${RENDERED}")"
if [[ "${rendered_key}" != "${SSH_KEY}" ]]; then
    echo "NOT OK   - just render changed literal or placeholder-shaped text" >&2
    exit 1
fi
echo "ok       - just render preserves literal and placeholder-shaped text"

cp "${VALID}" "${DUPLICATE}"
printf '%s\n' 'KANTAINER_TARGET_DRIVE=/dev/nvme0n1' >> "${DUPLICATE}"

if (cd "${REPO_ROOT}" && just config-check "${DUPLICATE}") \
        > "${WORK}/duplicate.out" 2> "${WORK}/duplicate.err"; then
    echo "NOT OK   - just config-check accepted an empty-first duplicate" >&2
    exit 1
fi
if ! grep -Fq 'sets KANTAINER_TARGET_DRIVE a second time' "${WORK}/duplicate.err"; then
    echo "NOT OK   - duplicate refusal did not name the second target-drive field" >&2
    cat "${WORK}/duplicate.err" >&2
    exit 1
fi
echo "ok       - just config-check refuses an empty-first duplicate"

if (cd "${REPO_ROOT}" && just render "${DUPLICATE}") \
        > "${WORK}/duplicate.ign" 2> "${WORK}/duplicate-render.err"; then
    echo "NOT OK   - just render accepted an empty-first duplicate" >&2
    exit 1
fi
if [[ -s "${WORK}/duplicate.ign" ]]; then
    echo "NOT OK   - refused duplicate still produced a machine specification" >&2
    exit 1
fi
echo "ok       - just render refuses the same duplicate without output"

cp "${VALID}" "${ARTIFACTS}/operator.conf"
printf '%s\n' \
    'config-check valid: accepted' \
    'render valid: accepted' \
    'config-check empty-first duplicate: refused' \
    'render empty-first duplicate: refused without output' \
    > "${ARTIFACTS}/outcomes.txt"

echo
echo "operator configuration commands are portable"
