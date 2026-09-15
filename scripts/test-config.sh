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

# §spec:console-password: "Nothing in kantainer writes a second readable copy
# onto the installed machine." This document IS the installed machine, so the
# password has no business anywhere in it.
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

# The posture that must not move, checked again on the path that actually ships
# a password: §spec:remote-access closes SSH to passwords whether or not one is
# set, and the hash landing in the document must not touch that drop-in.
if [[ "$(sshd_dropin)" == "${sshd_without_console_password}" ]]; then
    ok "a supplied hash leaves the sshd drop-in byte-identical"
else
    not_ok "a supplied hash leaves the sshd drop-in byte-identical"
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
