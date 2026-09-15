#!/bin/bash
# Turns the operator's kantainer.conf into the configuration the INSTALLER
# MEDIA boots with (SPEC.md §spec:installer-media, §spec:drive-selection).
#
# Two documents are involved and they are easy to confuse:
#
#   scripts/render-ignition.sh  -> the machine that results from the install
#   this script                 -> the live environment that performs it
#
# The second carries the first inside it, as /etc/kantainer/machine.ign, along
# with the drive rule and the drive the operator named. `just flash` embeds the
# result in the Fedora CoreOS live ISO.
#
# Prints the specification to stdout and touches nothing else. It carries the
# operator's SSH key and their Portainer password, so every intermediate file is
# staged in a private temporary directory that is removed on exit.
#
# NO CONTAINER, so this stays runnable by hand. The console password's hash is
# the one thing that needs one, and `just flash` makes it before calling this,
# handing it down through KANTAINER_RENDER_CONSOLE_PASSWORD_HASH for
# scripts/render-ignition.sh to substitute (SPEC.md §spec:console-password). Run
# this directly and the machine configuration inside carries the locked
# placeholder instead.
#
# Usage: render-installer.sh [config-file]

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

# mktemp gives 0700, and the trap is armed before the machine configuration -
# which contains the password - is written into it.
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

"${REPO_ROOT}/scripts/render-ignition.sh" "${CONFIG}" > "${STAGING}/machine.ign"

# Verbatim, with a trailing newline: the installer reads the first line and
# takes it as the device path. Empty when the operator named no drive.
printf '%s\n' "${KANTAINER_TARGET_DRIVE}" > "${STAGING}/target-drive"

# The console password, readable, for the installer to hash ON THE MACHINE
# (SPEC.md §spec:console-password). It travels here rather than inside
# machine.ign so that no readable copy can reach the INSTALLED machine: this
# document configures the live environment, which is RAM and is gone the moment
# the machine reboots.
#
# No trailing newline: the file is the password and nothing else. Empty when the
# operator set none, which is the case that leaves the machine exactly as it is
# today - the same shape as target-drive above.
printf '%s' "${KANTAINER_CONSOLE_PASSWORD}" > "${STAGING}/console-password"

cp "${REPO_ROOT}/scripts/install-to-disk" "${STAGING}/install-to-disk"

# --strict so a warning fails the render rather than reaching a USB stick.
butane --strict --files-dir "${STAGING}" "${REPO_ROOT}/butane/installer.bu.tmpl"
