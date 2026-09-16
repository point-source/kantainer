#!/bin/bash
# Refuses a machine configuration the machine cannot be built from, and names
# the field to go and fix (SPEC.md §spec:machine-configuration).
#
# This is `just config-check`. It reads the operator's file, says what the
# machine it describes will be, and writes nothing anywhere. `just render` and
# `just flash` apply the same rules through the same library, so a config this
# accepts is a config those two can build from.
#
# Usage: check-config.sh [config-file]

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/config-lib.sh"

CONFIG="${1:-kantainer.conf}"

kantainer_load_config "${CONFIG}"
kantainer_validate_config "${CONFIG}"

# What the operator gets to check at a glance. The password and the passphrase
# are deliberately absent: this line ends up in terminals, scrollbacks and
# pastes, and neither value is one the operator needs read back to them.
if [[ -n "${KANTAINER_WIFI_SSID}" ]]; then
    network="wireless network '${KANTAINER_WIFI_SSID}', joined after installation"
else
    network="wired"
fi

if [[ -n "${KANTAINER_TARGET_DRIVE}" ]]; then
    drive="installs to ${KANTAINER_TARGET_DRIVE}"
else
    drive="installs to the machine's only drive, or stops and asks if there is more than one"
fi

echo "${CONFIG} is complete."
echo "  login account: ${KANTAINER_USERNAME}, SSH by key only"
echo "  network:       ${network}"
echo "  drive:         ${drive}"
echo "  Portainer administrator password is set."

# The console password is the one field whose absence is reported rather than
# refused (SPEC.md §spec:console-password). Blank is a supported machine, so
# this is not a warning to be fixed - it is the cost of the choice, stated at
# the moment it is made, rather than discovered later with a keyboard in hand.
if [[ -n "${KANTAINER_CONSOLE_PASSWORD}" ]]; then
    echo "  Console password is set. You can log in at the machine's own keyboard."
else
    echo "  Console password is not set."
    echo "  If this machine's network fails, you cannot reach it at all. Reflashing is the only way back."
fi

# Reported for the same reason the console password is: it is a choice with a
# cost either way, and the moment the operator is reading their own config back
# is the moment to state it (SPEC.md §spec:container-updates). The `true` case
# names the label, because the commonest surprise is the opposite of the one
# people expect: Watchtower running, and updating nothing, because nothing is
# labelled.
if [[ "${KANTAINER_WATCHTOWER_ENABLED}" == "true" ]]; then
    echo "  Watchtower will run nightly at 05:00 UTC, unattended."
    echo "  It updates only containers labelled com.centurylinklabs.watchtower.enable=true. See docs/watchtower.md."
else
    echo "  Watchtower will not run. It is carried in the image and can be started later."
fi
