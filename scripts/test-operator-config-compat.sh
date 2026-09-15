#!/bin/bash
# Focused host-portability check for the real operator commands
# (SPEC.md §spec:operator-host-support).
#
# Usage: test-operator-config-compat.sh [artifact-directory] [reference-directory]
#
# With an artifact directory, the deterministic input, outcome record and
# rendered machine specification are retained for byte comparison with another
# host. Without one, `just test` exercises the same path and removes the files.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ARTIFACTS="${1:-${WORK}/artifacts}"
REFERENCE="${2-}"
mkdir -p "${ARTIFACTS}"

# Fixed public test material makes the config and rendered bytes identical on
# every host. There is no matching private key and these credentials belong to
# no machine. The compact suffix covers every literal-character promise while
# keeping the WPA passphrase inside its 63-byte limit.
LITERALS=$'\'"&\\\t $`@@ATTACH_IMAGE@@@@SSID@@@@PSK@@'
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHzks6d0NfXm47Zsj5rtshvfBUn5TjFUVrULCLNug5cu fixture ${LITERALS}"
PASSWORD="portainer-test-${LITERALS}"
CONSOLE_PASSWORD="console-test-${LITERALS}"
SSID="network-${LITERALS}"
PASSPHRASE="wireless-${LITERALS}"

VALID="${WORK}/operator.conf"
DUPLICATE="${WORK}/duplicate.conf"
RENDERED="${ARTIFACTS}/machine.ign"

printf '%s\n' \
    'KANTAINER_USERNAME=operator' \
    "KANTAINER_SSH_PUBLIC_KEY=${SSH_KEY}" \
    "KANTAINER_PORTAINER_PASSWORD=${PASSWORD}" \
    "KANTAINER_CONSOLE_PASSWORD=${CONSOLE_PASSWORD}" \
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

# SPEC.md §spec:console-password: the machine makes the hash during
# installation, precisely because the hosts this test compares do not agree on a
# tool that can. So what the render carries is the locked placeholder, on both
# hosts, and the artifacts stay byte-comparable - a salted hash never would be.
rendered_hash="$(jq -r '.passwd.users[0].passwordHash' < "${RENDERED}")"
if [[ "${rendered_hash}" != "*" ]]; then
    echo "NOT OK   - just render did not leave the console password for the machine to hash" >&2
    exit 1
fi
if grep -Fq "${CONSOLE_PASSWORD}" "${RENDERED}"; then
    echo "NOT OK   - just render put the console password into the machine specification" >&2
    exit 1
fi
echo "ok       - just render leaves the console password for the machine to hash"

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
    'render console password: left for the machine to hash' \
    'config-check empty-first duplicate: refused' \
    'render empty-first duplicate: refused without output' \
    > "${ARTIFACTS}/outcomes.txt"

if [[ -n "${REFERENCE}" ]]; then
    for artifact in operator.conf outcomes.txt machine.ign; do
        if [[ ! -f "${REFERENCE}/${artifact}" ]]; then
            echo "NOT OK   - reference artifacts do not contain ${artifact}" >&2
            exit 1
        fi
        if ! cmp -s "${REFERENCE}/${artifact}" "${ARTIFACTS}/${artifact}"; then
            echo "NOT OK   - ${artifact} differs from the reference host" >&2
            exit 1
        fi
    done
    echo "ok       - configuration inputs, outcomes and rendered bytes match the reference host"
fi

echo
echo "operator configuration commands are portable"
