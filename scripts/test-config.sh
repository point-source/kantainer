#!/bin/bash
# Tests for check-config.sh.
#
# The validator is the only thing standing between a mistyped configuration file
# and a machine that installs itself, reboots, and then refuses the operator's
# key. Every refusal has to name the field, because the operator is reading it
# without the file in front of them.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/scripts/check-config.sh"

failures=0

# Test material is GENERATED here, never committed. This repository is public
# (REQUIREMENTS.md §req:quality-attributes) and a key or a password written into
# a tracked file is a key or a password published.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C kantainer-test < /dev/null
TEST_SSH_KEY="$(cat "${WORK}/id.pub")"
TEST_PASSWORD="$(head -c 24 /dev/urandom | base64)"
TEST_PASSPHRASE="$(head -c 12 /dev/urandom | base64)"
TEST_SSID="kantainer test net"

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

# Write a valid configuration to $1, with the KEY=value overrides that follow
# applied on top. An override to the empty string blanks that field.
config() {
    local path="$1"
    shift

    local -A field=(
        [KANTAINER_USERNAME]="operator"
        [KANTAINER_SSH_PUBLIC_KEY]="${TEST_SSH_KEY}"
        [KANTAINER_PORTAINER_PASSWORD]="${TEST_PASSWORD}"
        [KANTAINER_TARGET_DRIVE]=""
        [KANTAINER_WIFI_SSID]=""
        [KANTAINER_WIFI_PASSPHRASE]=""
    )

    local override key
    for override in "$@"; do
        field["${override%%=*}"]="${override#*=}"
    done

    : > "${path}"
    for key in "${!field[@]}"; do
        printf '%s=%s\n' "${key}" "${field[${key}]}" >> "${path}"
    done
}

# accepts <name> [override ...]
accepts() {
    local name="$1"
    shift
    config "${WORK}/conf" "$@"

    local out status=0
    out="$("${CHECK}" "${WORK}/conf" 2>&1)" || status=$?

    if [[ "${status}" -ne 0 ]]; then
        not_ok "${name} (refused with: ${out})"
        return
    fi
    ok "${name}"
}

# refuses <name> <field the refusal must name> [override ...]
refuses() {
    local name="$1" named="$2"
    shift 2
    config "${WORK}/conf" "$@"

    local out status=0
    out="$("${CHECK}" "${WORK}/conf" 2>&1)" || status=$?

    if [[ "${status}" -eq 0 ]]; then
        not_ok "${name} (accepted it)"
        return
    fi
    if [[ "${out}" != *"${named}"* ]]; then
        not_ok "${name} (refusal never named ${named})"
        return
    fi
    ok "${name}"
}

accepts "accepts a filled-in configuration"

accepts "accepts a wired machine with no wireless fields" \
    "KANTAINER_WIFI_SSID=" "KANTAINER_WIFI_PASSPHRASE="

accepts "accepts a wireless machine" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"

accepts "accepts a named target drive" \
    "KANTAINER_TARGET_DRIVE=/dev/nvme0n1"

refuses "refuses a blank login account" "KANTAINER_USERNAME" \
    "KANTAINER_USERNAME="

refuses "refuses a login account that is not a Linux user name" "KANTAINER_USERNAME" \
    "KANTAINER_USERNAME=Some Person"

refuses "refuses a blank SSH public key" "KANTAINER_SSH_PUBLIC_KEY" \
    "KANTAINER_SSH_PUBLIC_KEY="

refuses "refuses a path where the SSH public key should be" "KANTAINER_SSH_PUBLIC_KEY" \
    "KANTAINER_SSH_PUBLIC_KEY=~/.ssh/id_ed25519.pub"

refuses "refuses the first line of a private key" "KANTAINER_SSH_PUBLIC_KEY" \
    "KANTAINER_SSH_PUBLIC_KEY=-----BEGIN OPENSSH PRIVATE KEY-----"

refuses "refuses a blank Portainer password" "KANTAINER_PORTAINER_PASSWORD" \
    "KANTAINER_PORTAINER_PASSWORD="

refuses "refuses a Portainer password Portainer would force a change on" "KANTAINER_PORTAINER_PASSWORD" \
    "KANTAINER_PORTAINER_PASSWORD=hunt"

refuses "refuses a wireless network with no passphrase" "KANTAINER_WIFI_PASSPHRASE" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE="

refuses "refuses a wireless passphrase with no network" "KANTAINER_WIFI_SSID" \
    "KANTAINER_WIFI_SSID=" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"

refuses "refuses a passphrase WPA-PSK would not accept" "KANTAINER_WIFI_PASSPHRASE" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=short"

refuses "refuses a misspelt field rather than ignoring it" "KANTAINER_USERNMAE" \
    "KANTAINER_USERNMAE=operator"

run_missing() {
    local out status=0
    out="$("${CHECK}" "${WORK}/absent" 2>&1)" || status=$?
    if [[ "${status}" -ne 0 && "${out}" == *"${WORK}/absent"* ]]; then
        ok "names the configuration file it could not find"
    else
        not_ok "names the configuration file it could not find"
    fi
}
run_missing

# The summary is the operator's confirmation that the file is right. It must not
# be a place the password turns up — in a terminal, in a scrollback, in a paste.
secrecy() {
    config "${WORK}/conf" \
        "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"
    local out
    out="$("${CHECK}" "${WORK}/conf" 2>&1)"
    if [[ "${out}" == *"${TEST_PASSWORD}"* ]]; then
        not_ok "never prints the Portainer password"
    else
        ok "never prints the Portainer password"
    fi
    if [[ "${out}" == *"${TEST_PASSPHRASE}"* ]]; then
        not_ok "never prints the wireless passphrase"
    else
        ok "never prints the wireless passphrase"
    fi
}
secrecy

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all configuration checks behave as intended"
else
    echo "${failures} configuration check(s) misbehaved"
    exit 1
fi
