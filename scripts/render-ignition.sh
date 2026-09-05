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
kantainer_validate_config "${CONFIG}"

command -v butane > /dev/null ||
    kantainer_fail "butane is not on PATH
    It is pinned in mise.toml: run \`mise install\`."

# mktemp gives 0700, and the trap is armed before anything secret is written.
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

# No trailing newline: the file is the password and nothing else.
printf '%s' "${KANTAINER_PORTAINER_PASSWORD}" > "${STAGING}/portainer-admin-password"

# Values that do go into the Butane text are quoted by jq as JSON strings, which
# YAML accepts verbatim. Hand-rolled quoting is how a key with a space or a name
# with a colon turns into a config that is valid YAML and means something other
# than what the operator wrote.
yaml_string() {
    jq -Rn --arg value "$1" '$value'
}

# Placeholders are filled by bash parameter expansion, not sed or awk. An SSH
# key comment is free text, and both of those tools reserve characters in
# replacement position - & is the whole match, \ starts an escape - so a key
# comment containing them comes out mangled or breaks the expression outright.
# Bash substitutes the replacement literally.
fill() {
    local text="$1" placeholder="$2" value="$3"
    printf '%s' "${text//"${placeholder}"/"${value}"}"
}

BUTANE="${STAGING}/kantainer.bu"

template="$(< "${REPO_ROOT}/butane/kantainer.bu.tmpl")"
template="$(fill "${template}" "@@USERNAME@@" "$(yaml_string "${KANTAINER_USERNAME}")")"
template="$(fill "${template}" "@@SSH_PUBLIC_KEY@@" "$(yaml_string "${KANTAINER_SSH_PUBLIC_KEY}")")"
printf '%s\n' "${template}" > "${BUTANE}"

# The wireless profile exists only when the operator named a network. A wired
# machine carries no wireless configuration at all (§spec:network-attachment),
# and wired DHCP needs none.
if [[ -n "${KANTAINER_WIFI_SSID}" ]]; then
    # The keyfile is read by NetworkManager through GLib, whose key-file parser
    # is NOT "everything to the end of the line". A backslash starts an escape
    # sequence, and an unrecognised one makes the whole value unreadable: the
    # profile is then rejected, the machine never joins the network, and nobody
    # finds out until they walk to it. A leading space or tab is dropped just as
    # quietly, which associates with the wrong secret. Both are escaped here;
    # every other character, & | % and quotes included, goes in as it is.
    keyfile_escape() {
        local value="${1//\\/\\\\}"
        case "${value}" in
            " "*) value="\\s${value#" "}" ;;
            "	"*) value="\\t${value#"	"}" ;;
        esac
        printf '%s' "${value}"
    }

    # Matched on the whole line rather than on the placeholder anywhere in the
    # file, so a network name that happens to contain the other placeholder
    # cannot have the passphrase substituted into it.
    profile=""
    while IFS= read -r line; do
        case "${line}" in
            "ssid=@@SSID@@") line="ssid=$(keyfile_escape "${KANTAINER_WIFI_SSID}")" ;;
            "psk=@@PSK@@") line="psk=$(keyfile_escape "${KANTAINER_WIFI_PASSPHRASE}")" ;;
        esac
        profile+="${line}"$'\n'
    done < "${REPO_ROOT}/butane/wireless.nmconnection.tmpl"

    printf '%s' "${profile}" > "${STAGING}/kantainer-wireless.nmconnection"

    cat "${REPO_ROOT}/butane/wireless.bu.tmpl" >> "${BUTANE}"
fi

# --strict so a warning fails the render rather than reaching a machine.
butane --strict --files-dir "${STAGING}" "${BUTANE}"
