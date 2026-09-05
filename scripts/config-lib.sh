# shellcheck shell=bash
# Reads and validates the operator's machine configuration file
# (SPEC.md §spec:machine-configuration).
#
# Sourced by check-config.sh and render-ignition.sh, and by `just flash` once
# Batch 4 lands, so that every one of them agrees on what a valid config is.
# A second copy of these rules would drift, and the failure would be a machine
# that installed itself and then refused the operator's key.
#
# The file is PARSED, not sourced. It carries a password, and sourcing it would
# put the operator on the hook for shell-quoting exactly the characters a good
# password contains: $ ` " ' \ and spaces. Instead every value is taken
# literally — everything after the first `=` to the end of the line. This is the
# shape os-release and systemd's EnvironmentFile already use.

# The complete set of fields. A key outside this list is a refusal rather than a
# silently ignored line: a misspelt field name is otherwise indistinguishable
# from an unset one, and the value the operator meant to set never arrives.
KANTAINER_FIELDS=(
    KANTAINER_USERNAME
    KANTAINER_SSH_PUBLIC_KEY
    KANTAINER_PORTAINER_PASSWORD
    KANTAINER_TARGET_DRIVE
    KANTAINER_WIFI_SSID
    KANTAINER_WIFI_PASSPHRASE
)

# Portainer's own minimum for the initial administrator password. Their setup
# documentation states "at least 12 characters", and their internal
# authentication applies the same minimum to existing accounts — anyone under it
# is made to change it at next login, which is the outcome
# §spec:machine-configuration exists to avoid.
# https://docs.portainer.io/start/install/server/setup
KANTAINER_MIN_PASSWORD_LENGTH=12

# WPA-PSK passphrase bounds, fixed by the standard: wpa_supplicant refuses
# anything outside them. Checked here so the refusal arrives now rather than on
# a headless machine that has already installed itself.
KANTAINER_MIN_PASSPHRASE_LENGTH=8
KANTAINER_MAX_PASSPHRASE_LENGTH=63

kantainer_fail() {
    echo "${0##*/}: $*" >&2
    exit 1
}

# Parse <path> into the KANTAINER_* variables named above.
kantainer_load_config() {
    local path="$1"

    [[ -e "${path}" ]] || kantainer_fail "no configuration file at ${path}
    Copy kantainer.conf.example to ${path} and fill it in."
    [[ -f "${path}" && -r "${path}" ]] || kantainer_fail "cannot read ${path}"

    local field
    for field in "${KANTAINER_FIELDS[@]}"; do
        printf -v "${field}" '%s' ''
    done

    local -A seen=()
    local lineno=0 line key value known
    while IFS= read -r line || [[ -n "${line}" ]]; do
        lineno=$(( lineno + 1 ))

        # Leading whitespace is not meaningful; trailing whitespace is part of
        # the value, which is why only the front is trimmed.
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "${line}" || "${line}" == \#* ]]; then
            continue
        fi

        if [[ "${line}" != *=* ]]; then
            kantainer_fail "${path} line ${lineno} is not a KEY=value line:
    ${line}"
        fi

        key="${line%%=*}"
        value="${line#*=}"

        # Matched one field at a time. Testing against the list joined by spaces
        # would accept a key that is merely a run of real field names, and the
        # refusal would then arrive as a raw bash error about an invalid
        # identifier instead of the line below.
        known=""
        for field in "${KANTAINER_FIELDS[@]}"; do
            if [[ "${key}" == "${field}" ]]; then
                known="${field}"
                break
            fi
        done
        if [[ -z "${known}" ]]; then
            kantainer_fail "${path} line ${lineno} sets an unknown field: ${key}
    kantainer.conf.example lists every field this file may set."
        fi

        if [[ -n "${seen[${key}]:-}" ]]; then
            kantainer_fail "${path} line ${lineno} sets ${key} a second time
    Two values for one field, and no way to tell which you meant. Delete one."
        fi
        seen["${key}"]=1

        printf -v "${key}" '%s' "${value}"
    done < "${path}"
}

# Refuse anything the machine cannot be built from. Every refusal names the
# field, so the operator is told which line to go and fix.
kantainer_validate_config() {
    [[ -n "${KANTAINER_USERNAME}" ]] ||
        kantainer_fail "KANTAINER_USERNAME is not set — the login account the machine creates"

    # An invalid user name renders happily and then fails on the machine, after
    # the install, with nobody watching.
    [[ "${KANTAINER_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ && "${#KANTAINER_USERNAME}" -le 32 ]] ||
        kantainer_fail "KANTAINER_USERNAME is not a valid Linux user name: ${KANTAINER_USERNAME}
    Lower-case letters, digits, underscore and dash; starting with a letter or
    underscore; at most 32 characters."

    [[ -n "${KANTAINER_SSH_PUBLIC_KEY}" ]] ||
        kantainer_fail "KANTAINER_SSH_PUBLIC_KEY is not set — the machine refuses password logins, so this is the only way in"

    # ssh-keygen's own verdict, rather than a regex of ours that would go stale
    # as key types come and go. It rejects the classic mistakes: a path to the
    # key instead of the key, or the first line of a private key.
    printf '%s\n' "${KANTAINER_SSH_PUBLIC_KEY}" | ssh-keygen -l -f - > /dev/null 2>&1 ||
        kantainer_fail "KANTAINER_SSH_PUBLIC_KEY is not an SSH public key
    Paste the contents of your .pub file, not its path and not the private key:
        cat ~/.ssh/id_ed25519.pub"

    [[ -n "${KANTAINER_PORTAINER_PASSWORD}" ]] ||
        kantainer_fail "KANTAINER_PORTAINER_PASSWORD is not set — required, because Portainer will not create its first administrator without it"

    [[ "${#KANTAINER_PORTAINER_PASSWORD}" -ge "${KANTAINER_MIN_PASSWORD_LENGTH}" ]] ||
        kantainer_fail "KANTAINER_PORTAINER_PASSWORD is shorter than ${KANTAINER_MIN_PASSWORD_LENGTH} characters
    Portainer forces a change at first login below that, which is the trip to
    the machine this password exists to avoid."

    # A drive is named the way the machine will look for it. `sda` renders
    # happily and then refuses on a machine that has already been carried to
    # wherever it lives, with nobody watching (SPEC.md §spec:drive-selection).
    if [[ -n "${KANTAINER_TARGET_DRIVE}" ]]; then
        [[ "${KANTAINER_TARGET_DRIVE}" == /dev/* ]] ||
            kantainer_fail "KANTAINER_TARGET_DRIVE is not a device path: ${KANTAINER_TARGET_DRIVE}
    Name it as the machine will see it, e.g. /dev/sda or /dev/nvme0n1, or leave
    it blank to install to the machine's only drive."
    fi

    # Wireless is optional as a pair. Half of it renders a profile that cannot
    # associate, and nothing says so until someone walks to the machine.
    if [[ -n "${KANTAINER_WIFI_SSID}" && -z "${KANTAINER_WIFI_PASSPHRASE}" ]]; then
        kantainer_fail "KANTAINER_WIFI_PASSPHRASE is not set, but KANTAINER_WIFI_SSID names a network
    Set both, or leave both blank for a wired machine."
    fi
    if [[ -z "${KANTAINER_WIFI_SSID}" && -n "${KANTAINER_WIFI_PASSPHRASE}" ]]; then
        kantainer_fail "KANTAINER_WIFI_SSID is not set, but KANTAINER_WIFI_PASSPHRASE is
    Set both, or leave both blank for a wired machine."
    fi

    if [[ -n "${KANTAINER_WIFI_SSID}" ]]; then
        [[ "${#KANTAINER_WIFI_PASSPHRASE}" -ge "${KANTAINER_MIN_PASSPHRASE_LENGTH}" &&
           "${#KANTAINER_WIFI_PASSPHRASE}" -le "${KANTAINER_MAX_PASSPHRASE_LENGTH}" ]] ||
            kantainer_fail "KANTAINER_WIFI_PASSPHRASE must be ${KANTAINER_MIN_PASSPHRASE_LENGTH}-${KANTAINER_MAX_PASSPHRASE_LENGTH} characters
    That range is WPA-PSK's, not ours: the machine's supplicant refuses anything
    outside it."
    fi

    kantainer_refuse_if_publishable "${1:-}"
}

# This repository is public and the configuration file carries a password in
# plain text. A copy kept inside the working tree under a name .gitignore does
# not cover is one `git add .` from being published, and a published password
# stays published - rotating it means reflashing the machine.
#
# git's check-ignore is the verdict. Reimplementing its rules here would be a
# second copy of someone else's logic, and ours would be the one that goes stale.
kantainer_refuse_if_publishable() {
    local path="$1" dir
    [[ -n "${path}" ]] || return 0

    dir="$(cd "$(dirname "${path}")" && pwd)"
    git -C "${dir}" rev-parse --show-toplevel > /dev/null 2>&1 || return 0
    git -C "${dir}" check-ignore -q "${path}" && return 0

    kantainer_fail "${path} is inside this repository and git does not ignore it
    It carries your Portainer password, and this repository is public. Either add
    it to .gitignore, or keep it outside the repository and name it:
        just render config=/path/to/your.conf"
}
