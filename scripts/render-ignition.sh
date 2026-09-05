#!/bin/bash
# Turns the operator's kantainer.conf into the machine specification Ignition
# reads at first boot (SPEC.md §spec:machine-configuration, §spec:remote-access,
# §spec:network-attachment).
#
# This is `just render`. It prints the specification to stdout and touches
# nothing else: no USB stick, no file in the working tree. Batch 4's `just
# flash` is this command's output piped into the installer image, which is why
# the validation lives in config-lib.sh rather than here - one set of rules for
# `just config-check`, `just render` and `just flash`.
#
# The specification carries the Portainer password in plain text. It is staged
# in a private temporary directory and handed to butane as a local file, so the
# password never passes through a substitution and never lands anywhere the
# operator did not ask for it.
#
# Usage: render-ignition.sh [config-file]

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/config-lib.sh"

CONFIG="${1:-kantainer.conf}"

kantainer_load_config "${CONFIG}"
kantainer_validate_config

command -v butane > /dev/null ||
    kantainer_fail "butane is not on PATH
    It is pinned in mise.toml: run \`mise install\`."

# mktemp gives 0700, and the trap is armed before anything secret is written.
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

# No trailing newline: the file is the password and nothing else.
printf '%s' "${KANTAINER_PORTAINER_PASSWORD}" > "${STAGING}/portainer-admin-password"

# Values that do go into the Butane text are quoted by jq as JSON strings, which
# YAML accepts verbatim. Hand-rolled quoting is how a key with a space or a
# name with a colon turns into a config that is valid YAML and means something
# other than what the operator wrote.
yaml_string() {
    jq -Rn --arg value "$1" '$value'
}

BUTANE="${STAGING}/kantainer.bu"

sed \
    -e "s|@@USERNAME@@|$(yaml_string "${KANTAINER_USERNAME}")|" \
    -e "s|@@SSH_PUBLIC_KEY@@|$(yaml_string "${KANTAINER_SSH_PUBLIC_KEY}")|" \
    "${REPO_ROOT}/butane/kantainer.bu.tmpl" > "${BUTANE}"

# The wireless profile exists only when the operator named a network. A wired
# machine carries no wireless configuration at all (§spec:network-attachment),
# and wired DHCP needs none.
if [[ -n "${KANTAINER_WIFI_SSID}" ]]; then
    # Keyfile values run to the end of the line, so the SSID and passphrase are
    # written literally. They are placed with awk rather than sed because a
    # passphrase may contain any character, including sed's delimiters and
    # backreferences.
    awk -v ssid="${KANTAINER_WIFI_SSID}" -v psk="${KANTAINER_WIFI_PASSPHRASE}" '
        { sub(/@@SSID@@/, ssid); sub(/@@PSK@@/, psk); print }
    ' "${REPO_ROOT}/butane/wireless.nmconnection.tmpl" \
        > "${STAGING}/kantainer-wireless.nmconnection"

    cat "${REPO_ROOT}/butane/wireless.bu.tmpl" >> "${BUTANE}"
fi

# --strict so a warning fails the render rather than reaching a machine.
butane --strict --files-dir "${STAGING}" "${BUTANE}"
