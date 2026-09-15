#!/bin/bash
# Turns the operator's kantainer.conf into the machine specification Ignition
# reads at first boot (SPEC.md §spec:machine-configuration, §spec:remote-access,
# §spec:network-attachment).
#
# This is `just render`. It prints the specification to stdout and touches
# nothing else: no USB stick, no file in the working tree. `just flash` embeds
# this output in the installer media, which is why the validation lives in
# config-lib.sh rather than here - one set of rules for `just config-check`,
# `just render` and `just flash`.
#
# It also carries the signing material the machine needs to verify the image it
# attaches to on first boot, because at that moment the machine is still stock
# Fedora CoreOS and has nothing of ours on it (SPEC.md §spec:installer-media).
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

# The published image reference, and the signing policy generated from it. Both
# come from the same places the image build reads them, so the scope the machine
# verifies against and the image it attaches to cannot drift apart
# (SPEC.md §spec:installer-media).
# shellcheck source=/dev/null
. "${REPO_ROOT}/image.env"
# shellcheck source=/dev/null
. "${REPO_ROOT}/build_files/policy-lib.sh"

CONFIG="${1:-kantainer.conf}"

kantainer_load_config "${CONFIG}"
kantainer_validate_config "${CONFIG}"

command -v butane > /dev/null ||
    kantainer_fail "butane is not on PATH
    It is pinned in mise.toml: run \`mise install\`."

IMAGE_REF="$(kantainer_image_ref)"
ATTACH_IMAGE="${IMAGE_REF}:${DEFAULT_TAG}"

# The one value substituted into the Butane body rather than staged as a file.
# It is not the operator's to write - it comes from image.env - but it lands
# inside a systemd unit inside a YAML block scalar, where a stray newline or
# quote would produce a config that is valid and means something else. A
# registry reference has a known shape, so say so.
[[ "${ATTACH_IMAGE}" =~ ^[a-z0-9][a-z0-9._/-]*:[a-zA-Z0-9._-]+$ ]] ||
    kantainer_fail "image.env does not describe a container image reference: ${ATTACH_IMAGE}
    IMAGE_REGISTRY/REPO_ORGANIZATION/IMAGE_NAME and DEFAULT_TAG together are
    what the machine attaches itself to and what its signing policy names."

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

# Replace every literal placeholder found in the original text in one pass.
# Replacement text is appended to separate output and never searched again, so
# an SSH key comment containing another placeholder stays exactly that comment.
# The scanner also avoids pattern-substitution replacement rules, which differ
# between the Bash versions on supported operator hosts.
fill() {
    local remaining="$1"
    shift

    local -a placeholders replacements
    local placeholder matched rendered=""
    local i pair_count=0

    while [[ "$#" -gt 0 ]]; do
        pair_count=$(( pair_count + 1 ))
        placeholders[pair_count]="$1"
        replacements[pair_count]="$2"
        shift 2
    done

    while [[ -n "${remaining}" ]]; do
        matched=""
        for ((i = 1; i <= pair_count; i++)); do
            placeholder="${placeholders[${i}]}"
            if [[ "${remaining}" == "${placeholder}"* ]]; then
                rendered="${rendered}${replacements[${i}]}"
                remaining="${remaining:${#placeholder}}"
                matched=1
                break
            fi
        done

        if [[ -z "${matched}" ]]; then
            rendered="${rendered}${remaining:0:1}"
            remaining="${remaining:1}"
        fi
    done

    printf '%s' "${rendered}"
}

# What lets the machine verify its very first attachment, before any kantainer
# content exists on it. The key is the repository's committed public half; the
# policy and the lookaside configuration are generated from the same functions
# the image build uses (SPEC.md §spec:installer-media, §spec:os-updates).
cp "${REPO_ROOT}/cosign.pub" "${STAGING}/kantainer.pub"
kantainer_policy_json "${IMAGE_REF}" > "${STAGING}/policy.json"
kantainer_registries_d_yaml "${IMAGE_REF}" > "${STAGING}/kantainer-registries.yaml"

BUTANE="${STAGING}/kantainer.bu"

# The console password's HASH is not made here, and the password itself never
# enters this document (SPEC.md §spec:console-password). The machine converts it
# during installation, because the Bash and the OpenSSL macOS ships cannot
# produce the modern form and §req:constraints forbids requiring a Mac operator
# to install anything extra. scripts/render-installer.sh puts the readable value
# on the installer media; scripts/install-to-disk hashes it there and replaces
# the placeholder below.
#
# Blank substitutes to the empty string, so a machine with no console password
# renders exactly what it rendered before this field existed.
if [[ -n "${KANTAINER_CONSOLE_PASSWORD}" ]]; then
    CONSOLE_PASSWORD_HASH=$'\n      password_hash: "*"'
else
    CONSOLE_PASSWORD_HASH=""
fi

template="$(< "${REPO_ROOT}/butane/kantainer.bu.tmpl")"
template="$(fill "${template}" \
    "@@USERNAME@@" "$(yaml_string "${KANTAINER_USERNAME}")" \
    "@@SSH_PUBLIC_KEY@@" "$(yaml_string "${KANTAINER_SSH_PUBLIC_KEY}")" \
    "@@CONSOLE_PASSWORD_HASH@@" "${CONSOLE_PASSWORD_HASH}" \
    "@@ATTACH_IMAGE@@" "${ATTACH_IMAGE}")"
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
        # Use the same one-pass literal scanner as the Butane template. Pattern
        # substitution gives backslashes in replacement text different meaning
        # across supported Bash versions.
        local value
        value="$(fill "$1" "\\" "\\\\")"
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
