#!/bin/bash
# Tests for check-config.sh and render-ignition.sh.
#
# The validator is the only thing standing between a mistyped configuration file
# and a machine that installs itself, reboots, and then refuses the operator's
# key. Every refusal has to name the field, because the operator is reading it
# without the file in front of them.
#
# The renderer's output is asserted with jq rather than grep. Every failure it
# can have is silent on a headless machine: a keyfile NetworkManager ignores
# because its mode is wrong, a wireless profile on a machine that was meant to
# be wired, a password file the Portainer unit cannot read.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/scripts/check-config.sh"
RENDER="${REPO_ROOT}/scripts/render-ignition.sh"

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

### render-ignition.sh

# Ignition carries file contents as a data: URL. Both forms appear depending on
# what is being carried, so both are decoded here.
decode() {
    local source="$1"
    case "${source}" in
        "data:;base64,"*)
            printf '%s' "${source#data:;base64,}" | base64 -d
            ;;
        "data:,"*)
            local body="${source#data:,}"
            body="${body//\\/\\\\}"
            printf '%b' "${body//%/\\x}"
            ;;
        *)
            printf '%s' "${source}"
            ;;
    esac
}

# Render a valid config with the given overrides into $WORK/out.json.
render() {
    config "${WORK}/conf" "$@"
    "${RENDER}" "${WORK}/conf" > "${WORK}/out.json"
}

# File contents at path $1 in the rendered output, decoded. Butane compresses
# anything past a size threshold, so the compression field decides whether what
# comes out of the data: URL is the file or a gzip stream of it.
file_at() {
    local path="$1" source compression
    source="$(jq -r --arg p "${path}" \
        '.storage.files[] | select(.path == $p) | .contents.source' < "${WORK}/out.json")"
    compression="$(jq -r --arg p "${path}" \
        '.storage.files[] | select(.path == $p) | .contents.compression // ""' < "${WORK}/out.json")"

    if [[ "${compression}" == "gzip" ]]; then
        decode "${source}" | gzip -d
    else
        decode "${source}"
    fi
}

# jq expression $1 against the rendered output, expecting $2.
assert_jq() {
    local name="$1" expr="$2" want="$3" got
    got="$(jq -r "${expr}" < "${WORK}/out.json")"
    if [[ "${got}" == "${want}" ]]; then
        ok "${name}"
    else
        not_ok "${name} (wanted ${want}, got ${got})"
    fi
}

render
assert_jq "renders an Ignition config" '.ignition.version' "3.5.0"
assert_jq "creates the login account" \
    '.passwd.users[0].name' "operator"
assert_jq "gives that account the operator's SSH key" \
    '.passwd.users[0].sshAuthorizedKeys[0]' "${TEST_SSH_KEY}"

if [[ "$(file_at /etc/ssh/sshd_config.d/10-kantainer-no-passwords.conf)" == *"PasswordAuthentication no"* ]]; then
    ok "sshd refuses password authentication"
else
    not_ok "sshd refuses password authentication"
fi
if [[ "$(file_at /etc/ssh/sshd_config.d/10-kantainer-no-passwords.conf)" == *"KbdInteractiveAuthentication no"* ]]; then
    ok "sshd refuses keyboard-interactive authentication too"
else
    not_ok "sshd refuses keyboard-interactive authentication too"
fi

assert_jq "the Portainer password file is mode 0600" \
    '.storage.files[] | select(.path == "/etc/kantainer/portainer-admin-password") | .mode' "384"
assert_jq "the Portainer password file is owned by root" \
    '.storage.files[] | select(.path == "/etc/kantainer/portainer-admin-password") | "\(.user.id):\(.group.id)"' "0:0"

if [[ "$(file_at /etc/kantainer/portainer-admin-password)" == "${TEST_PASSWORD}" ]]; then
    ok "the Portainer password file holds the password and nothing else"
else
    not_ok "the Portainer password file holds the password and nothing else"
fi

### wireless, or the pointed absence of it

render "KANTAINER_WIFI_SSID=" "KANTAINER_WIFI_PASSPHRASE="
if grep -qiE 'networkmanager|nmconnection|wifi|wireless|wpa' "${WORK}/out.json"; then
    not_ok "a wired machine carries no wireless configuration at all"
else
    ok "a wired machine carries no wireless configuration at all"
fi

render "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"
assert_jq "a wireless machine carries a NetworkManager profile" \
    '[.storage.files[] | select(.path == "/etc/NetworkManager/system-connections/kantainer-wireless.nmconnection")] | length' "1"
assert_jq "NetworkManager will not ignore that profile" \
    '.storage.files[] | select(.path == "/etc/NetworkManager/system-connections/kantainer-wireless.nmconnection") | "\(.mode) \(.user.id):\(.group.id)"' "384 0:0"

profile="$(file_at /etc/NetworkManager/system-connections/kantainer-wireless.nmconnection)"
if [[ "${profile}" == *"ssid=${TEST_SSID}"* ]]; then
    ok "the profile names the operator's network"
else
    not_ok "the profile names the operator's network"
fi
if [[ "${profile}" == *"psk=${TEST_PASSPHRASE}"* ]]; then
    ok "the profile carries the passphrase verbatim"
else
    not_ok "the profile carries the passphrase verbatim"
fi

### values that are hostile to a templating engine

# An SSH key comment and a WPA passphrase are free text. Both can contain the
# characters sed and awk reserve in replacement position - & is the whole match,
# \ starts an escape - and a value mangled there is not a syntax error: it is a
# key the machine will not accept, or a passphrase it cannot associate with,
# discovered in person.
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/awkward" -C 'a&b\c|d%e' < /dev/null
AWKWARD_KEY="$(cat "${WORK}/awkward.pub")"
AWKWARD_PSK='pass&word\slash|pipe%pct'
AWKWARD_SSID='net&work\one'

render "KANTAINER_SSH_PUBLIC_KEY=${AWKWARD_KEY}" \
    "KANTAINER_WIFI_SSID=${AWKWARD_SSID}" "KANTAINER_WIFI_PASSPHRASE=${AWKWARD_PSK}"

assert_jq "an SSH key comment containing & \\ | % survives intact" \
    '.passwd.users[0].sshAuthorizedKeys[0]' "${AWKWARD_KEY}"

profile="$(file_at /etc/NetworkManager/system-connections/kantainer-wireless.nmconnection)"
if [[ "${profile}" == *"ssid=${AWKWARD_SSID}"* ]]; then
    ok "an SSID containing & and \\ survives intact"
else
    not_ok "an SSID containing & and \\ survives intact"
fi
if [[ "${profile}" == *"psk=${AWKWARD_PSK}"* ]]; then
    ok "a passphrase containing & \\ | % survives intact"
else
    not_ok "a passphrase containing & \\ | % survives intact"
fi

AWKWARD_PASSWORD='p&ss\w|rd%123'
render "KANTAINER_PORTAINER_PASSWORD=${AWKWARD_PASSWORD}"
if [[ "$(file_at /etc/kantainer/portainer-admin-password)" == "${AWKWARD_PASSWORD}" ]]; then
    ok "a Portainer password containing & \\ | % survives intact"
else
    not_ok "a Portainer password containing & \\ | % survives intact"
fi

### refusals

# The renderer applies the validator's rules, so `just render` and `just flash`
# cannot disagree about what a valid config is.
render_refuses() {
    local name="$1" named="$2"
    shift 2
    config "${WORK}/conf" "$@"

    local status=0
    "${RENDER}" "${WORK}/conf" > "${WORK}/refused.json" 2> "${WORK}/refused.err" || status=$?

    if [[ "${status}" -eq 0 ]]; then
        not_ok "${name} (rendered anyway)"
        return
    fi
    if ! grep -q "${named}" "${WORK}/refused.err"; then
        not_ok "${name} (refusal never named ${named})"
        return
    fi
    if [[ -s "${WORK}/refused.json" ]]; then
        not_ok "${name} (wrote a specification anyway)"
        return
    fi
    ok "${name}"
}

render_refuses "refuses to render without an SSH public key" "KANTAINER_SSH_PUBLIC_KEY" \
    "KANTAINER_SSH_PUBLIC_KEY="
render_refuses "refuses to render a password Portainer would reject" "KANTAINER_PORTAINER_PASSWORD" \
    "KANTAINER_PORTAINER_PASSWORD=hunt"

### the repository stays clean

# Rendering produces a secret. Verify it goes to stdout and nowhere else - a
# password left in the working tree of a public repository is a password one
# `git add .` away from being published.
before="$(git -C "${REPO_ROOT}" status --porcelain)"
render "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"
after="$(git -C "${REPO_ROOT}" status --porcelain)"

if [[ "${before}" == "${after}" ]]; then
    ok "rendering leaves the working tree untouched"
else
    not_ok "rendering leaves the working tree untouched"
fi

if grep -rqF "${TEST_PASSWORD}" "${REPO_ROOT}" --exclude-dir=.git 2> /dev/null; then
    not_ok "rendering leaves no secret behind in the repository"
else
    ok "rendering leaves no secret behind in the repository"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all configuration checks behave as intended"
else
    echo "${failures} configuration check(s) misbehaved"
    exit 1
fi
