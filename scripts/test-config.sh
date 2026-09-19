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

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/ignition-lib.sh"

failures=0

# Test material is GENERATED here, never committed. This repository is public
# (REQUIREMENTS.md §req:quality-attributes) and a key or a password written into
# a tracked file is a key or a password published.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C kantainer-test < /dev/null
TEST_SSH_KEY="$(cat "${WORK}/id.pub")"
TEST_PASSWORD="$(head -c 24 /dev/urandom | base64)"
TEST_CONSOLE_PASSWORD="$(head -c 24 /dev/urandom | base64)"
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
        [KANTAINER_CONSOLE_PASSWORD]=""
        [KANTAINER_TARGET_DRIVE]=""
        [KANTAINER_WIFI_SSID]=""
        [KANTAINER_WIFI_PASSPHRASE]=""
        [KANTAINER_WATCHTOWER_ENABLED]=""
        [KANTAINER_TAILSCALE_AUTHKEY]=""
        [KANTAINER_TAILSCALE_HOSTNAME]=""
        [KANTAINER_TAILSCALE_EXIT_NODE]=""
        [KANTAINER_TAILSCALE_ROUTES]=""
        [KANTAINER_PORTAINER_TAILNET_ONLY]=""
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

# The console password is the one optional field whose absence is REPORTED
# rather than refused (SPEC.md §spec:machine-configuration). Blank is a
# supported machine; too short is not, because the login prompt is the whole of
# the gate - privileged commands never ask again (§spec:console-password).
accepts "accepts a blank console password" \
    "KANTAINER_CONSOLE_PASSWORD="

accepts "accepts a console password at the twelve-character floor" \
    "KANTAINER_CONSOLE_PASSWORD=123456789012"

accepts "accepts a console password above the floor" \
    "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"

refuses "refuses a console password one character under the floor" "KANTAINER_CONSOLE_PASSWORD" \
    "KANTAINER_CONSOLE_PASSWORD=12345678901"

# The file's whole promise is that a value is taken literally to the end of the
# line. A console password is the second place that promise is load-bearing.
accepts "accepts a console password full of characters a shell would eat" \
    "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"'$`"'"'"'\ &|%@@SSID@@'

refuses "refuses a wireless network with no passphrase" "KANTAINER_WIFI_PASSPHRASE" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE="

refuses "refuses a wireless passphrase with no network" "KANTAINER_WIFI_SSID" \
    "KANTAINER_WIFI_SSID=" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"

refuses "refuses a passphrase WPA-PSK would not accept" "KANTAINER_WIFI_PASSPHRASE" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=short"

# WPA-PSK's 8-63 counts OCTETS. Thirty-two of these is 32 characters and 64
# bytes: a character count accepts it, the supplicant does not, and the headless
# machine never joins the network with nobody there to see why.
refuses "refuses a passphrase that is short in characters but too long in bytes" "KANTAINER_WIFI_PASSPHRASE" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=áááááááááááááááááááááááááááááááá"

# ...and the same rule must not reject a passphrase that is legal in bytes.
accepts "accepts a non-ASCII passphrase that fits in the byte limit" \
    "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=café-córrect-horse"

# The installer matches this string against `lsblk --nodeps`, which only ever
# reports /dev/<kernel name>. A by-id symlink is the stable form a careful person
# reaches for, and it would pass a looser check here and then strand the install
# on the machine, hours later, with nobody watching.
refuses "refuses a drive named by a symlink the installer cannot resolve" "KANTAINER_TARGET_DRIVE" \
    "KANTAINER_TARGET_DRIVE=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_S1234567890"

refuses "refuses a misspelt field rather than ignoring it" "KANTAINER_USERNMAE" \
    "KANTAINER_USERNMAE=operator"

# A key made of two real field names is a substring of the field list joined by
# spaces, so a membership test done by substring match lets it through and the
# refusal arrives as a raw bash error instead.
refuses "refuses a key that merely looks like two fields" "unknown field: KANTAINER_USERNAME KANTAINER_SSH_PUBLIC_KEY" \
    "KANTAINER_USERNAME KANTAINER_SSH_PUBLIC_KEY=x"

# Duplicate tracking is separate from the value itself. In particular, a blank
# optional field still counts as its first occurrence; accepting the later value
# would silently turn a malformed configuration into a different machine.
duplicate_refuses() {
    local name="$1" key_name="$2" first="$3" second="$4"
    config "${WORK}/conf" "${key_name}=${first}"
    printf '%s=%s\n' "${key_name}" "${second}" >> "${WORK}/conf"

    local out status=0
    out="$("${CHECK}" "${WORK}/conf" 2>&1)" || status=$?
    if [[ "${status}" -eq 0 ]]; then
        not_ok "${name} (accepted it)"
    elif [[ "${out}" != *"sets ${key_name} a second time"* ]]; then
        not_ok "${name} (wrong refusal: ${out})"
    else
        ok "${name}"
    fi
}

duplicate_refuses "refuses a duplicate field" KANTAINER_USERNAME operator another-operator
duplicate_refuses "refuses a duplicate whose first value is empty" KANTAINER_TARGET_DRIVE "" /dev/nvme0n1

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

    config "${WORK}/conf" "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"
    out="$("${CHECK}" "${WORK}/conf" 2>&1)"
    if [[ "${out}" == *"${TEST_CONSOLE_PASSWORD}"* ]]; then
        not_ok "never prints the console password"
    else
        ok "never prints the console password"
    fi
}
secrecy

# SPEC.md §spec:console-password: a blank console password is accepted, and the
# check says plainly what declining costs, "so that the operator declines the
# insurance knowingly rather than discovering it later with a keyboard in their
# hand". A silent acceptance is the failure this asserts against.
advises() {
    local name="$1" phrase="$2"
    shift 2
    config "${WORK}/conf" "$@"

    local out status=0
    out="$("${CHECK}" "${WORK}/conf" 2>&1)" || status=$?

    if [[ "${status}" -ne 0 ]]; then
        not_ok "${name} (refused with: ${out})"
    elif [[ "${out}" != *"${phrase}"* ]]; then
        not_ok "${name} (never said: ${phrase})"
    else
        ok "${name}"
    fi
}

advises "says what a machine with no console password costs" \
    "you cannot reach it at all" \
    "KANTAINER_CONSOLE_PASSWORD="

advises "says the console password is set, without printing it" \
    "Console password is set" \
    "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"

### KANTAINER_WATCHTOWER_ENABLED (§spec:container-updates)

# `yes`, `1`, `True` and `on` all read as agreement to a person, and the
# renderer tests for none of them. Accepting one quietly would produce a machine
# that does not update its containers and an operator certain that it does -
# and nothing on that machine contradicts them, because a Watchtower that was
# never switched on looks exactly like one with nothing to do.
accepts "accepts a machine that asked for Watchtower" \
    "KANTAINER_WATCHTOWER_ENABLED=true"

# false is accepted alongside blank so the decision can be written down rather
# than left as an absent line the next reader has to interpret.
accepts "accepts a machine that wrote down declining it" \
    "KANTAINER_WATCHTOWER_ENABLED=false"

accepts "accepts a machine that left the field blank" \
    "KANTAINER_WATCHTOWER_ENABLED="

refuses "refuses a yes that is not the word the renderer tests for" \
    "KANTAINER_WATCHTOWER_ENABLED" "KANTAINER_WATCHTOWER_ENABLED=yes"

refuses "refuses a capitalised True" \
    "KANTAINER_WATCHTOWER_ENABLED" "KANTAINER_WATCHTOWER_ENABLED=True"

refuses "refuses a numeric 1" \
    "KANTAINER_WATCHTOWER_ENABLED" "KANTAINER_WATCHTOWER_ENABLED=1"

advises "names the label when Watchtower is switched on" \
    "com.centurylinklabs.watchtower.enable=true" \
    "KANTAINER_WATCHTOWER_ENABLED=true"

advises "says Watchtower is carried but not running when it is off" \
    "Watchtower will not run" \
    "KANTAINER_WATCHTOWER_ENABLED="

### The Tailscale fields (§spec:tailscale)

TEST_AUTHKEY=tskey-auth-fixture0CNTRL-thiskeyauthenticatesnothing

accepts "accepts a machine that joins a tailnet" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}"

accepts "accepts a machine that names itself on the tailnet" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" \
    "KANTAINER_TAILSCALE_HOSTNAME=garage-box"

accepts "accepts a machine that routes for the tailnet" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" \
    "KANTAINER_TAILSCALE_EXIT_NODE=true" \
    "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24,fd00::/64"

accepts "accepts a machine with no Tailscale at all" \
    "KANTAINER_TAILSCALE_AUTHKEY="

# THE KEY IS THE SWITCH, so every other field without one describes a machine
# that never joins anything. Written down and never used is the failure this
# repository refuses everywhere else it appears, and each field is refused BY
# NAME so the operator is told which line to go and fix.
refuses "refuses a node name on a machine that never joins" \
    "KANTAINER_TAILSCALE_HOSTNAME" "KANTAINER_TAILSCALE_HOSTNAME=garage-box"

refuses "refuses an exit node on a machine that never joins" \
    "KANTAINER_TAILSCALE_EXIT_NODE" "KANTAINER_TAILSCALE_EXIT_NODE=true"

refuses "refuses routes on a machine that never joins" \
    "KANTAINER_TAILSCALE_ROUTES" "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24"

# The worst of the four to accept quietly: it would render a machine whose
# Portainer binds to a tailnet address that never exists, so it would serve
# nothing at all.
refuses "refuses a tailnet-only Portainer on a machine that never joins" \
    "KANTAINER_PORTAINER_TAILNET_ONLY" "KANTAINER_PORTAINER_TAILNET_ONLY=true"

# An API access token and an auth key look alike and are issued from pages that
# look alike. Only one can bring a machine onto a tailnet; the other fails at
# first boot with "invalid key", which reads like a typo.
refuses "refuses an API token pasted where an auth key belongs" \
    "API access token" "KANTAINER_TAILSCALE_AUTHKEY=tskey-api-fixture0CNTRL-notanauthkey"

refuses "refuses something that is not a Tailscale key at all" \
    "KANTAINER_TAILSCALE_AUTHKEY" "KANTAINER_TAILSCALE_AUTHKEY=hunter2hunter2"

# Whitespace is what a key picks up on its way through a terminal or a chat
# window, and tailscaled would refuse it hours later on a headless machine.
refuses "refuses a key with a space in it" \
    "KANTAINER_TAILSCALE_AUTHKEY" "KANTAINER_TAILSCALE_AUTHKEY=tskey-auth-fix ture"

# Tailscale lowercases and trims whatever it is given, so any other shape would
# appear in the operator's tailnet as a name they did not write.
refuses "refuses a node name Tailscale would silently rewrite" \
    "KANTAINER_TAILSCALE_HOSTNAME" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_HOSTNAME=Garage_Box"

refuses "refuses a node name that starts with a dash" \
    "KANTAINER_TAILSCALE_HOSTNAME" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_HOSTNAME=-box"

# Same reasoning as the Watchtower switch: the renderer tests for `true` and
# nothing else, so anything the validator lets past and does not recognise is a
# machine that silently does not do the thing.
refuses "refuses a yes where the exit node wants true" \
    "KANTAINER_TAILSCALE_EXIT_NODE" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_EXIT_NODE=yes"

refuses "refuses a yes where the tailnet-only switch wants true" \
    "KANTAINER_PORTAINER_TAILNET_ONLY" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_PORTAINER_TAILNET_ONLY=yes"

# A route is a block, not an address. `tailscale up` would refuse a bare address
# too, on the machine, with nobody watching.
refuses "refuses a single address where a route block belongs" \
    "not a network block" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=192.168.1.5"

refuses "refuses a prefix length out of range" \
    "not a network block" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/33"

refuses "refuses an octet out of range" \
    "not a network block" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=256.1.1.0/24"

# Different parsers disagree about whether a leading zero means octal, so the
# address an operator meant is not the address every reader would see.
refuses "refuses an octet with a leading zero" \
    "not a network block" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=010.0.0.0/8"

refuses "refuses a space after the comma separating two routes" \
    "not a network block" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" \
    "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24, 10.0.0.0/8"

# The one the obvious loop walks straight past: consuming routes until nothing
# is left never examines the field AFTER a final comma.
refuses "refuses a trailing comma" \
    "empty entry" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24,"

refuses "refuses a leading comma" \
    "empty entry" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=,10.0.0.0/8"

# What the operator gets read back to them. The key itself is never echoed: this
# line ends up in terminals, scrollbacks and pastes, and a key that reaches one
# of those is a key to regenerate.
advises "names the machine as the tailnet will show it" \
    "as 'garage-box'" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_HOSTNAME=garage-box"

advises "falls back to kantainer when no node name was given" \
    "as 'kantainer'" "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}"

# The commonest surprise with both routing settings: the field is set, the
# machine advertises, and nothing routes, because the other half of the switch
# lives in Tailscale's admin console.
advises "says an exit node still needs approving" \
    "Approve it in the admin console" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_EXIT_NODE=true"

advises "says routes still need approving" \
    "Approve them in the admin console" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24"

advises "says what a tailnet-only Portainer costs" \
    "Portainer does not start" \
    "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_PORTAINER_TAILNET_ONLY=true"

# An auth key expires on the key rather than on the machine, so a stick flashed
# today installs a machine next year with a key that joins nothing.
advises "warns that the key expires" \
    "expires" "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}"

advises "says Tailscale is in the image when it is off" \
    "Tailscale will not run" "KANTAINER_TAILSCALE_AUTHKEY="

# The key must not be read back. Checked as the absence of the secret rather
# than the presence of a phrase, because this is the assertion that catches a
# well-meaning change to the reporting line.
config "${WORK}/conf" "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}"
if "${CHECK}" "${WORK}/conf" 2>&1 | grep -qF "${TEST_AUTHKEY}"; then
    not_ok "the configuration check never echoes the authentication key"
else
    ok "the configuration check never echoes the authentication key"
fi

### render-ignition.sh

# Render a valid config with the given overrides into $WORK/out.json. A failure
# is reported and the run continues: under `set -e` one broken render would
# otherwise abort the suite and hide every test after it.
render() {
    config "${WORK}/conf" "$@"
    if ! "${RENDER}" "${WORK}/conf" > "${WORK}/out.json" 2> "${WORK}/out.err"; then
        not_ok "render failed: $(cat "${WORK}/out.err")"
        : > "${WORK}/out.json"
    fi
}

# File contents at path $1 in the rendered output, decoded by
# scripts/ignition-lib.sh - the same reader scripts/test-installer.sh uses.
file_at() {
    kantainer_ignition_file "${WORK}/out.json" "$1"
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

# A machine with no console password is the machine this repository built before
# the field existed: no account has a password at all (§spec:console-password).
assert_jq "a blank console password leaves the account with no password at all" \
    '.passwd.users[0] | has("passwordHash")' "false"

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

### the console password, and what it must NOT change

# SPEC.md §spec:console-password: setting one "widens physical access and
# nothing else". The remote posture is the thing that must not move, so the
# whole drop-in object is compared between the two renders rather than the two
# keywords grepped again - a change to its mode or its owner would slip past a
# grep and open exactly the door §spec:remote-access closes.
sshd_dropin() {
    jq -S '.storage.files[]
        | select(.path == "/etc/ssh/sshd_config.d/10-kantainer-no-passwords.conf")' \
        < "${WORK}/out.json"
}
sshd_without_console_password="$(sshd_dropin)"

render "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"

if [[ "$(sshd_dropin)" == "${sshd_without_console_password}" ]]; then
    ok "setting a console password leaves the sshd drop-in byte-identical"
else
    not_ok "setting a console password leaves the sshd drop-in byte-identical"
fi

# The hash is NOT produced here, and `just render` is the reason. It is a
# documented standalone command, it runs without a container, and
# scripts/test-operator-config-compat.sh byte-compares its output between Linux
# and macOS - which a $6$ hash, with its random salt, would break on the first
# run. So this path emits the placeholder and `just flash` substitutes the real
# hash before butane runs (§spec:console-password).
#
# `*` rather than a token of ours: it is crypt's own "no password will ever
# match this account", so a machine that somehow receives this document
# unsubstituted has a locked account rather than an unknown credential.
assert_jq "the login account carries a locked password placeholder" \
    '.passwd.users[0].passwordHash' "*"

# §spec:console-password: "After installation the password exists on the machine
# only in its account database." This document IS the installed machine, so the
# readable password has no business anywhere in it.
if grep -Fq "${TEST_CONSOLE_PASSWORD}" "${WORK}/out.json"; then
    not_ok "the console password never reaches the machine specification"
else
    ok "the console password never reaches the machine specification"
fi

### the flash path's seam: a hash supplied from outside

# KANTAINER_RENDER_CONSOLE_PASSWORD_HASH is how `just flash` hands this script
# the hash it obtained from the coreos-installer container. It is deliberately
# NOT one of scripts/config-lib.sh's KANTAINER_FIELDS: the config parser refuses
# an unknown key, so an operator cannot set it from kantainer.conf and `just
# render` can never emit anything but the placeholder above.
#
# A fixed fixture hash rather than a real one, because a real $6$ salt is random
# and this assertion has to be exact.
# The single quotes are the point: `$6$` is crypt's literal method marker, not
# an expansion.
# shellcheck disable=SC2016
FIXTURE_HASH='$6$fixturesalt$fixtureHASHvalue.WithDots/AndSlashes0123456789'

KANTAINER_RENDER_CONSOLE_PASSWORD_HASH="${FIXTURE_HASH}" \
    render "KANTAINER_CONSOLE_PASSWORD=${TEST_CONSOLE_PASSWORD}"

assert_jq "a supplied hash replaces the placeholder verbatim" \
    '.passwd.users[0].passwordHash' "${FIXTURE_HASH}"

# The whole reason the substitution happens BEFORE butane: the readable password
# is never an input to this document, only the hash is.
if grep -Fq "${TEST_CONSOLE_PASSWORD}" "${WORK}/out.json"; then
    not_ok "a supplied hash keeps the readable password out of the specification"
else
    ok "a supplied hash keeps the readable password out of the specification"
fi

# Blank console password wins over a supplied hash: there is no account to put
# one on. This is the case §req:constraints calls a supported machine, and it
# must stay the machine this repository built before the field existed.
KANTAINER_RENDER_CONSOLE_PASSWORD_HASH="${FIXTURE_HASH}" \
    render "KANTAINER_CONSOLE_PASSWORD="

assert_jq "a supplied hash is ignored when no console password is set" \
    '.passwd.users[0] | has("passwordHash")' "false"

render

assert_jq "the Portainer password file is mode 0600" \
    '.storage.files[] | select(.path == "/etc/kantainer/portainer-admin-password") | .mode' "384"
assert_jq "the Portainer password file is owned by root" \
    '.storage.files[] | select(.path == "/etc/kantainer/portainer-admin-password") | "\(.user.id):\(.group.id)"' "0:0"

if [[ "$(file_at /etc/kantainer/portainer-admin-password)" == "${TEST_PASSWORD}" ]]; then
    ok "the Portainer password file holds the password and nothing else"
else
    not_ok "the Portainer password file holds the password and nothing else"
fi

### the signing material, placed during installation

# SPEC.md §spec:installer-media: the machine attaches itself to the published
# image on first boot, and that FIRST attachment is signature-verified like
# every later update. That only works if the policy is on the machine before the
# image is, which means it is placed here - while the machine is still stock
# Fedora CoreOS with nothing of ours on it.
#
# Every failure below is silent from outside. A machine that accepts an unsigned
# image looks exactly like one that verified it, right up until someone
# publishes to the registry who should not have.
IMAGE_REF="$(
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/image.env"
    echo "${IMAGE_REGISTRY}/${REPO_ORGANIZATION}/${IMAGE_NAME}" | tr '[:upper:]' '[:lower:]'
)"
ATTACH_TAG="$(
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/image.env"
    echo "${DEFAULT_TAG}"
)"

if [[ "$(file_at /etc/pki/containers/kantainer.pub)" == "$(cat "${REPO_ROOT}/cosign.pub")" ]]; then
    ok "the machine carries this repository's signing key"
else
    not_ok "the machine carries this repository's signing key"
fi

assert_jq "the machine carries a container signing policy at all" \
    '[.storage.files[] | select(.path == "/etc/containers/policy.json")] | length' "1"

# Fedora CoreOS already carries this file. Ignition must replace it before the
# machine can perform its first signed attachment.
assert_jq "the signing policy replaces the one Fedora CoreOS ships" \
    '.storage.files[] | select(.path == "/etc/containers/policy.json") | .overwrite' "true"

policy="$(file_at /etc/containers/policy.json)"

if jq -e --arg ref "${IMAGE_REF}" --arg key /etc/pki/containers/kantainer.pub '
        .transports.docker[$ref]
        | any(.type == "sigstoreSigned"
              and .keyPath == $key
              and .signedIdentity.type == "matchRepository")' <<< "${policy}" > /dev/null; then
    ok "the published image is accepted only with a signature from that key"
else
    not_ok "the published image is accepted only with a signature from that key"
fi

# The docker transport default is consulted BEFORE the top-level default. A
# machine that inherited an accept-anything transport default would take an
# unsigned image no matter what the top-level default said.
if jq -e '.transports.docker[""] | all(.type == "reject")' <<< "${policy}" > /dev/null &&
        jq -e '.default | all(.type == "reject")' <<< "${policy}" > /dev/null; then
    ok "an image outside that scope is rejected rather than accepted unsigned"
else
    not_ok "an image outside that scope is rejected rather than accepted unsigned"
fi

# Without this, containers/image never looks for a cosign signature, finds none,
# and refuses an image that is in fact correctly signed.
if [[ "$(file_at /etc/containers/registries.d/kantainer.yaml)" == *"${IMAGE_REF}:"* &&
      "$(file_at /etc/containers/registries.d/kantainer.yaml)" == *"use-sigstore-attachments: true"* ]]; then
    ok "containers/image is told to look for cosign signatures on that image"
else
    not_ok "containers/image is told to look for cosign signatures on that image"
fi

### the second stage

assert_jq "the machine is set up to attach itself to its own image" \
    '.systemd.units[] | select(.name == "kantainer-attach.service") | .enabled' "true"

attach="$(jq -r '.systemd.units[] | select(.name == "kantainer-attach.service") | .contents' < "${WORK}/out.json")"

# ostree-image-signed: is what makes the rebase consult policy.json above.
# Without the prefix the machine would pull the same image and verify nothing.
#
# If this assertion fails, do not just update the expected string. The prefix
# decides the verification mode recorded in the deployment origin, and
# update-preflight (§spec:os-updates) refuses to update any machine whose mode
# is not `containerPolicy`. Getting it wrong ships a machine that installs,
# serves, and then never updates again without saying so.
if [[ "${attach}" == *"ostree-image-signed:docker://${IMAGE_REF}:${ATTACH_TAG}"* ]]; then
    ok "it attaches to the image image.env names, verifying the signature"
else
    not_ok "it attaches to the image image.env names, verifying the signature"
fi

# The scope the machine verifies against and the image it attaches to are
# generated from one string. If they ever named different things the machine
# would look up a scope that is not in its policy, and the refusal would arrive
# months later as an update that silently stopped happening.
if jq -e --arg ref "${IMAGE_REF}" '.transports.docker | has($ref)' <<< "${policy}" > /dev/null &&
        [[ "${attach}" == *"${IMAGE_REF}:"* ]]; then
    ok "the policy scope and the attachment name the same image"
else
    not_ok "the policy scope and the attachment name the same image"
fi

# A machine that has already attached must not attach again: the rebase merges
# /etc into the new deployment as part of its own transaction, so a stamp
# written afterwards would be left behind and the machine would loop.
if [[ "${attach}" == *"ConditionPathExists=!/usr/lib/kantainer/os-image"* ]]; then
    ok "it stops once the machine is running the kantainer image"
else
    not_ok "it stops once the machine is running the kantainer image"
fi

### wireless, or the pointed absence of it

# Matched against the document's STRUCTURE, not its raw bytes. The test material
# is freshly generated per run, and an SSH key is base64 - one in a few hundred
# contains the literal "WpA", which a case-insensitive grep for "wpa" over the
# whole file reads as a wireless profile that is not there. Asserting on paths
# and unit names is the same question asked where the answer actually lives.
render "KANTAINER_WIFI_SSID=" "KANTAINER_WIFI_PASSPHRASE="
if jq -e '
        [ (.storage.files // [])[].path,
          (.storage.directories // [])[].path,
          (.systemd.units // [])[].name ]
        | map(select(test("networkmanager|nmconnection|wifi|wireless|wpa"; "i")))
        | length == 0' "${WORK}/out.json" > /dev/null; then
    ok "a wired machine carries no wireless configuration at all"
else
    not_ok "a wired machine carries no wireless configuration at all"
fi

render "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${TEST_PASSPHRASE}"
assert_jq "a wireless machine carries a NetworkManager profile" \
    '[.storage.files[] | select(.path == "/etc/NetworkManager/system-connections/kantainer-wireless.nmconnection")] | length' "1"
assert_jq "NetworkManager will not ignore that profile" \
    '.storage.files[] | select(.path == "/etc/NetworkManager/system-connections/kantainer-wireless.nmconnection") | "\(.mode) \(.user.id):\(.group.id)"' "384 0:0"

# NetworkManager reads its keyfiles through GLib, and GLib's key-file parser
# treats a backslash as an escape and strips a leading space. Asserting the raw
# bytes we wrote would pass for a profile NetworkManager refuses to read, so the
# assertions below go through GLib itself and compare what it reads BACK.
cat > "${WORK}/keyfile-read.py" << 'PYEOF'
import ctypes, ctypes.util, sys

name = ctypes.util.find_library("glib-2.0")
if not name:
    sys.exit(3)
glib = ctypes.CDLL(name)
glib.g_key_file_new.restype = ctypes.c_void_p
glib.g_key_file_load_from_data.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
    ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
glib.g_key_file_get_string.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_void_p)]
glib.g_key_file_get_string.restype = ctypes.c_char_p

data = open(sys.argv[1], "rb").read()
handle = glib.g_key_file_new()
err = ctypes.c_void_p()
if not glib.g_key_file_load_from_data(handle, data, len(data), 0, ctypes.byref(err)):
    sys.exit(1)
err = ctypes.c_void_p()
value = glib.g_key_file_get_string(
    handle, sys.argv[2].encode(), sys.argv[3].encode(), ctypes.byref(err))
if err:
    sys.exit(1)
sys.stdout.buffer.write(value)
PYEOF

# keyfile_value <group> <key> - what GLib reads back from the rendered profile.
keyfile_value() {
    file_at /etc/NetworkManager/system-connections/kantainer-wireless.nmconnection \
        > "${WORK}/profile.keyfile"
    python3 "${WORK}/keyfile-read.py" "${WORK}/profile.keyfile" "$1" "$2"
}

# reads_back <name> <group> <key> <expected>
reads_back() {
    local name="$1" group="$2" key="$3" want="$4" got status=0
    got="$(keyfile_value "${group}" "${key}")" || status=$?

    if [[ "${status}" -eq 3 ]]; then
        not_ok "${name} (GLib not available - install libglib2.0 to run this check)"
        return
    fi
    if [[ "${status}" -ne 0 ]]; then
        not_ok "${name} (NetworkManager's parser rejects the profile)"
        return
    fi
    if [[ "${got}" != "${want}" ]]; then
        not_ok "${name} (NetworkManager would read '${got}')"
        return
    fi
    ok "${name}"
}

reads_back "NetworkManager reads back the operator's network" wifi ssid "${TEST_SSID}"
reads_back "NetworkManager reads back the passphrase" wifi-security psk "${TEST_PASSPHRASE}"

# 2 is NetworkManager's "disable". Asserted through GLib like everything else
# here, because a profile that carries the key with a value NetworkManager reads
# as something else is a machine that still goes unreachable.
reads_back "the profile turns wifi power save off" wifi powersave "2"

### values that are hostile to a templating engine

# An SSH key comment and a WPA passphrase are free text. Both can contain the
# characters sed and awk reserve in replacement position - & is the whole match,
# \ starts an escape - and a value mangled there is not a syntax error: it is a
# key the machine will not accept, or a passphrase it cannot associate with,
# discovered in person.
AWKWARD_KEY_COMMENT=$'single\'quote double"quote & back\\slash tab\t space $ ` @@ATTACH_IMAGE@@'
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/awkward" -C "${AWKWARD_KEY_COMMENT}" < /dev/null
AWKWARD_KEY="$(cat "${WORK}/awkward.pub")"
AWKWARD_PSK=$'valid-pass \'" & back\\slash tab\t space $ ` | % @@SSID@@'
AWKWARD_SSID=$'net \'" & back\\slash tab\t space $ ` | % @@PSK@@'

render "KANTAINER_SSH_PUBLIC_KEY=${AWKWARD_KEY}" \
    "KANTAINER_WIFI_SSID=${AWKWARD_SSID}" "KANTAINER_WIFI_PASSPHRASE=${AWKWARD_PSK}"

assert_jq "an SSH key comment keeps literal characters and placeholder text" \
    '.passwd.users[0].sshAuthorizedKeys[0]' "${AWKWARD_KEY}"

reads_back "an SSID keeps literal characters and placeholder text" \
    wifi ssid "${AWKWARD_SSID}"
reads_back "a passphrase keeps literal characters and placeholder text" \
    wifi-security psk "${AWKWARD_PSK}"

# A leading space is the other half of GLib's escaping rule: written raw it is
# silently dropped, and the machine tries to associate with the wrong secret.
render "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE= ${TEST_PASSPHRASE} "
reads_back "a passphrase with a leading space keeps it" \
    wifi-security psk " ${TEST_PASSPHRASE} "

LEADING_TAB_PSK=$'\t'"${TEST_PASSPHRASE} "
render "KANTAINER_WIFI_SSID=${TEST_SSID}" "KANTAINER_WIFI_PASSPHRASE=${LEADING_TAB_PSK}"
reads_back "a passphrase with a leading tab keeps it" \
    wifi-security psk "${LEADING_TAB_PSK}"

AWKWARD_PASSWORD="${TEST_PASSWORD}"'&\|%'
render "KANTAINER_PORTAINER_PASSWORD=${AWKWARD_PASSWORD}"
if [[ "$(file_at /etc/kantainer/portainer-admin-password)" == "${AWKWARD_PASSWORD}" ]]; then
    ok "a Portainer password containing & \\ | % survives intact"
else
    not_ok "a Portainer password containing & \\ | % survives intact"
fi

### the Watchtower switch (§spec:container-updates)

# THE GATE IS A FILE, and nothing reads what is in it: kantainer-watchtower's
# ConditionPathExists asks only whether the path is there. So the two states are
# a file that exists and a file that does not, and every assertion below is
# about which of those the renderer produced.
#
# scripts/test-watchtower.sh checks that the renderer's source says `== "true"`.
# That is a different question from what a render actually contains, and a
# regression in the fragment, the append, or the Butane template would leave it
# passing while every machine flashed from this repository either ran Watchtower
# unasked or refused to run it when asked.
GATE=/etc/kantainer/watchtower-enabled

render "KANTAINER_WATCHTOWER_ENABLED=true"

assert_jq "a machine that asked for Watchtower carries the gate file" \
    '[.storage.files[] | select(.path == "'"${GATE}"'")] | length' "1"
assert_jq "the gate file is readable by the unit that reads it" \
    '.storage.files[] | select(.path == "'"${GATE}"'") | "\(.mode) \(.user.id):\(.group.id)"' "420 0:0"

# The file says what it is for, because the one thing an operator cannot learn
# by opening it is that its contents do not matter.
if [[ "$(file_at "${GATE}")" == *"rm ${GATE}"* ]]; then
    ok "the gate file tells whoever opens it how to switch Watchtower off"
else
    not_ok "the gate file tells whoever opens it how to switch Watchtower off"
fi

cp "${WORK}/out.json" "${WORK}/watchtower-on.json"

# A machine that did not ask carries NO TRACE of Watchtower, exactly as a wired
# machine carries no wireless profile. Absent, not present-and-empty: the unit
# would start on a gate file containing the word false.
render "KANTAINER_WATCHTOWER_ENABLED=false"

assert_jq "a machine that declined Watchtower carries no gate file" \
    '[.storage.files[] | select(.path == "'"${GATE}"'")] | length' "0"

cp "${WORK}/out.json" "${WORK}/watchtower-off.json"

render "KANTAINER_WATCHTOWER_ENABLED="

assert_jq "a machine that left the field blank carries no gate file" \
    '[.storage.files[] | select(.path == "'"${GATE}"'")] | length' "0"

# false and blank are the same machine, and true differs from them by the gate
# file ALONE. Compared whole rather than by the one path, so a fragment that
# also moved a unit, a mode or an owner is caught here rather than on a machine.
if cmp -s "${WORK}/out.json" "${WORK}/watchtower-off.json"; then
    ok "writing false down renders the same machine as leaving it blank"
else
    not_ok "writing false down renders the same machine as leaving it blank"
fi

difference="$(jq -S '.storage.files[].path' "${WORK}/watchtower-on.json" |
    diff - <(jq -S '.storage.files[].path' "${WORK}/watchtower-off.json") || true)"
if [[ "$(grep -c '^[<>]' <<< "${difference}")" -eq 1 && "${difference}" == *"${GATE}"* ]]; then
    ok "switching Watchtower on adds the gate file and nothing else"
else
    not_ok "switching Watchtower on changes more than the gate file:
${difference}"
fi

### the Tailscale files (§spec:tailscale)
#
# Same reasoning as the Watchtower gate above, and more of it: Tailscale renders
# FIVE files across three fragments, each appended under its own condition. A
# regression in any one append would leave scripts/test-tailscale.sh passing on
# source that still reads correctly, while every machine flashed from this
# repository either joined a tailnet it was not asked to join or refused to join
# the one it was.
TS_GATE=/etc/kantainer/tailscale-enabled
TS_KEY=/etc/kantainer/tailscale-authkey
TS_ENV=/etc/kantainer/tailscale.env
TS_FORWARDING=/etc/sysctl.d/99-kantainer-tailscale-forwarding.conf
TS_TAILNET_ONLY=/etc/kantainer/portainer-tailnet-only

render "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}"

assert_jq "a machine that asked for Tailscale carries the gate file" \
    '[.storage.files[] | select(.path == "'"${TS_GATE}"'")] | length' "1"

assert_jq "it carries the authentication key" \
    '[.storage.files[] | select(.path == "'"${TS_KEY}"'")] | length' "1"

# 0600 root:root. The key is a credential to the operator's whole private
# network rather than to this machine, so a mode that let any account on the
# machine read it would be a worse leak than the Portainer password.
assert_jq "the key is readable only by root" \
    '.storage.files[] | select(.path == "'"${TS_KEY}"'") | "\(.mode) \(.user.id):\(.group.id)"' "384 0:0"

assert_jq "it carries the settings the unit reads" \
    '[.storage.files[] | select(.path == "'"${TS_ENV}"'")] | length' "1"

# The key reaches the machine EXACTLY as the operator wrote it, with no trailing
# newline: `tailscale up --auth-key=file:` is handed this file, and the file is
# the key and nothing else.
if [[ "$(file_at "${TS_KEY}")" == "${TEST_AUTHKEY}" ]]; then
    ok "the key is rendered exactly, with nothing around it"
else
    not_ok "the key is rendered exactly, with nothing around it (got: $(file_at "${TS_KEY}"))"
fi

# Every setting is written even at its default, so an operator reading the file
# on the machine can tell a default from a setting nobody thought about - and
# the empty string is what --advertise-routes wants for "advertise nothing".
settings="$(file_at "${TS_ENV}")"
for want in "KANTAINER_TAILSCALE_HOSTNAME=kantainer" \
    "KANTAINER_TAILSCALE_EXIT_NODE=false" \
    "KANTAINER_TAILSCALE_ROUTES="; do
    if [[ "${settings}" == *"${want}"* ]]; then
        ok "the settings file states ${want%%=*}"
    else
        not_ok "the settings file states ${want%%=*} (wanted ${want}, got: ${settings})"
    fi
done

# A machine that joins for its own sake forwards nothing. Turning on forwarding
# widens what a machine does with packets not addressed to it, which is not a
# side effect to hand somebody who asked for a VPN.
assert_jq "a machine that only joins does not turn on forwarding" \
    '[.storage.files[] | select(.path == "'"${TS_FORWARDING}"'")] | length' "0"

assert_jq "a machine that only joins keeps Portainer on every address" \
    '[.storage.files[] | select(.path == "'"${TS_TAILNET_ONLY}"'")] | length' "0"

cp "${WORK}/out.json" "${WORK}/tailscale-on.json"

# WITHOUT THE KEY, NO TRACE OF ANY OF IT - exactly as a wired machine carries no
# wireless profile.
render "KANTAINER_TAILSCALE_AUTHKEY="

for absent in "${TS_GATE}" "${TS_KEY}" "${TS_ENV}" "${TS_FORWARDING}" "${TS_TAILNET_ONLY}"; do
    assert_jq "a machine without a key carries no ${absent##*/}" \
        '[.storage.files[] | select(.path == "'"${absent}"'")] | length' "0"
done

cp "${WORK}/out.json" "${WORK}/tailscale-off.json"

# Switching Tailscale on adds those three files and NOTHING ELSE. Compared whole
# rather than path by path, so a fragment that also moved a unit, a mode or an
# owner is caught here rather than on a machine.
difference="$(jq -S '.storage.files[].path' "${WORK}/tailscale-on.json" |
    diff - <(jq -S '.storage.files[].path' "${WORK}/tailscale-off.json") || true)"
added="$(grep -c '^<' <<< "${difference}" || true)"
if [[ "${added}" -eq 3 && "$(grep -c '^>' <<< "${difference}" || true)" -eq 0 ]]; then
    ok "joining a tailnet adds the gate, the key and the settings, and nothing else"
else
    not_ok "joining a tailnet changes more than its three files:
${difference}"
fi

# Routing is the kernel's half as well as Tailscale's. Without the sysctl the
# route is approved, looks correct everywhere, and drops every packet.
render "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_TAILSCALE_EXIT_NODE=true"

assert_jq "an exit node turns forwarding on" \
    '[.storage.files[] | select(.path == "'"${TS_FORWARDING}"'")] | length' "1"

render "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" \
    "KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24,fd00::/64"

assert_jq "advertised routes turn forwarding on" \
    '[.storage.files[] | select(.path == "'"${TS_FORWARDING}"'")] | length' "1"

# Both families. An IPv6 route with only IPv4 forwarding enabled is the same
# silent drop, and only this assertion separates the two lines.
forwarding="$(file_at "${TS_FORWARDING}")"
for want in "net.ipv4.ip_forward = 1" "net.ipv6.conf.all.forwarding = 1"; do
    if [[ "${forwarding}" == *"${want}"* ]]; then
        ok "forwarding is enabled for ${want%%.*}$( [[ "${want}" == *ipv6* ]] && echo "6" || echo "4" )"
    else
        not_ok "forwarding is missing: ${want}"
    fi
done

# The routes reach the machine as `tailscale up --advertise-routes` takes them,
# unchanged. A renderer that reordered or re-spaced them would advertise
# something the operator did not write.
if [[ "$(file_at "${TS_ENV}")" == *"KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24,fd00::/64"* ]]; then
    ok "the routes are passed through exactly as written"
else
    not_ok "the routes are passed through exactly as written (got: $(file_at "${TS_ENV}"))"
fi

render "KANTAINER_TAILSCALE_AUTHKEY=${TEST_AUTHKEY}" "KANTAINER_PORTAINER_TAILNET_ONLY=true"

assert_jq "a tailnet-only Portainer carries its gate file" \
    '[.storage.files[] | select(.path == "'"${TS_TAILNET_ONLY}"'")] | length' "1"

# Asking for a tailnet-only Portainer must not quietly also make the machine a
# router. They are separate decisions with separate costs.
assert_jq "a tailnet-only Portainer does not turn on forwarding by itself" \
    '[.storage.files[] | select(.path == "'"${TS_FORWARDING}"'")] | length' "0"

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

# The renderer tests for `true` and nothing else, so anything it does not refuse
# and does not recognise renders a machine with Watchtower silently off. The
# refusal is what makes `== "true"` safe to write.
render_refuses "refuses to render a Watchtower switch it would silently ignore" \
    "KANTAINER_WATCHTOWER_ENABLED" "KANTAINER_WATCHTOWER_ENABLED=yes"

### a config the operator could publish by accident

# This repository is public and the file carries a password. A config kept
# inside the working tree under a name .gitignore does not cover is one
# `git add .` away from being published, and a published password stays
# published. git's own check-ignore is the verdict.
publishable() {
    local name="$1" want="$2" path="${REPO_ROOT}/$3"
    config "${path}"

    local out status=0
    out="$("${CHECK}" "${path}" 2>&1)" || status=$?
    rm -f "${path}"

    if [[ "${want}" == "refused" && "${status}" -eq 0 ]]; then
        not_ok "${name} (accepted it)"
    elif [[ "${want}" == "refused" && "${out}" != *"git does not ignore"* ]]; then
        not_ok "${name} (refused for another reason: ${out})"
    elif [[ "${want}" == "accepted" && "${status}" -ne 0 ]]; then
        not_ok "${name} (refused: ${out})"
    else
        ok "${name}"
    fi
}

# A drive is named as a device path, or the installer has nothing to look for.
# `sda` renders happily and then refuses on a headless machine that has already
# been carried to wherever it lives.
config "${WORK}/bare-drive.conf" "KANTAINER_TARGET_DRIVE=sda"
if err="$("${CHECK}" "${WORK}/bare-drive.conf" 2>&1)"; then
    not_ok "refuses a target drive that is not a device path"
elif [[ "${err}" == *KANTAINER_TARGET_DRIVE* ]]; then
    ok "refuses a target drive that is not a device path"
else
    not_ok "refuses a target drive that is not a device path (wrong reason: ${err})"
fi

config "${WORK}/drive.conf" "KANTAINER_TARGET_DRIVE=/dev/nvme0n1"
if "${CHECK}" "${WORK}/drive.conf" > /dev/null 2>&1; then
    ok "accepts a target drive that is a device path"
else
    not_ok "accepts a target drive that is a device path"
fi

publishable "refuses a config the repository would publish" refused "operator-secrets.conf"
publishable "accepts a config the repository already ignores" accepted "kantainer.conf"

# A config outside the repository is the operator's business, not ours.
config "${WORK}/elsewhere.conf"
if "${CHECK}" "${WORK}/elsewhere.conf" > /dev/null 2>&1; then
    ok "accepts a config kept outside the repository"
else
    not_ok "accepts a config kept outside the repository"
fi

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
