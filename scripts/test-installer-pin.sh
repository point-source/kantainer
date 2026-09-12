#!/bin/bash
# Tests for check-installer-pin.sh.
#
# That check is the one thing standing between a bot raising FCOS_VERSION and a
# repository whose committed checksum belongs to the previous release. Every
# offline check in this repository passes in that state - check-pins.sh only
# polices the SHAPE of the pin - so if this comparison is wrong, nothing else
# notices and the failure surfaces on the operator's machine after a 1.3 GB
# download.
#
# Nothing here reaches the network. The script is SOURCED and its one fetching
# function is replaced with fixtures, the same move scripts/test-flash.sh and
# scripts/test-install-to-disk.sh make for hardware.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/scripts/check-installer-pin.sh"

# shellcheck source=/dev/null
. "${CHECK}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/versions.env"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

ARCH=x86_64

# Fedora's own shape, reduced to the two fields the check reads. Built with jq so
# the fixture is real JSON rather than a string that happens to look like it.
meta_json() {
    local path="$1" sha="$2"
    jq -cn --arg p "${path}" --arg s "${sha}" \
        '{buildid:"test", images:{"live-iso":{path:$p, sha256:$s, size:1074790400}}}'
}

# Run the comparison in a subshell: it calls fail(), which exits.
expect() {
    local want="$1" name="$2" meta="$3" version="$4" sha="$5"
    local got=0 err

    err="$( ( kantainer_check_installer_pin "${meta}" "${version}" "${sha}" "${ARCH}" ) 2>&1 )" || got=1

    if [[ "${got}" -ne "${want}" ]]; then
        not_ok "${name} (wanted exit ${want}, got ${got}: ${err})"
        return
    fi
    ok "${name}"
}

GOOD_ISO="fedora-coreos-${FCOS_VERSION}-live-iso.${ARCH}.iso"

expect 0 "accepts the release pinned in versions.env" \
    "$(meta_json "${GOOD_ISO}" "${FCOS_ISO_SHA256}")" "${FCOS_VERSION}" "${FCOS_ISO_SHA256}"

# The case this check exists for: a version bump that left the checksum behind.
expect 1 "refuses a checksum that belongs to a different release" \
    "$(meta_json "${GOOD_ISO}" "0000000000000000000000000000000000000000000000000000000000000000")" \
    "${FCOS_VERSION}" "${FCOS_ISO_SHA256}"

# ...and it must name the field to go and fix, because whoever reads it is reading
# a CI log without the repository in front of them.
err="$( ( kantainer_check_installer_pin \
    "$(meta_json "${GOOD_ISO}" "0000000000000000000000000000000000000000000000000000000000000000")" \
    "${FCOS_VERSION}" "${FCOS_ISO_SHA256}" "${ARCH}" ) 2>&1 )" || true
if [[ "${err}" == *"FCOS_ISO_SHA256"* && "${err}" == *"0000000000000000"* ]]; then
    ok "names the field to fix and prints the checksum to paste"
else
    not_ok "names the field to fix and prints the checksum to paste (got: ${err})"
fi

expect 1 "refuses a filename this repository would not have requested" \
    "$(meta_json "fedora-coreos-99.19700101.9.9-live-iso.${ARCH}.iso" "${FCOS_ISO_SHA256}")" \
    "${FCOS_VERSION}" "${FCOS_ISO_SHA256}"

# Metadata that describes no live ISO must be diagnosed as METADATA being wrong,
# not as a filename disagreement. Both produce a refusal either way, so the exit
# status cannot tell them apart - the message is the whole of the difference, and
# it is what a reader acts on. Asserted, or the guard that produces it would be
# indistinguishable from having no guard.
expect_says() {
    local name="$1" meta="$2" want="$3" err

    err="$( ( kantainer_check_installer_pin "${meta}" "${FCOS_VERSION}" "${FCOS_ISO_SHA256}" "${ARCH}" ) 2>&1 )" && {
        not_ok "${name} (it accepted the metadata)"
        return
    }
    if [[ "${err}" == *"${want}"* ]]; then
        ok "${name}"
    else
        not_ok "${name} (got: ${err})"
    fi
}

expect_says "refuses metadata describing no live ISO, and says so" \
    '{"buildid":"test","images":{}}' \
    "describes no live ISO"

expect_says "refuses a live ISO carrying no checksum, and says so" \
    "$(jq -cn --arg p "${GOOD_ISO}" '{images:{"live-iso":{path:$p}}}')" \
    "describes no live ISO"

# The name is derived, not hardcoded: a bumped version must change what we request.
if [[ "$(kantainer_expected_iso_name 44.20260817.3.2 x86_64)" == "fedora-coreos-44.20260817.3.2-live-iso.x86_64.iso" ]]; then
    ok "the requested filename is built from the pinned version"
else
    not_ok "the requested filename is built from the pinned version"
fi

if [[ "$(kantainer_meta_url stable 44.20260817.3.2 x86_64)" == \
    "https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/44.20260817.3.2/x86_64/meta.json" ]]; then
    ok "the metadata URL addresses the pinned build, not the newest one"
else
    not_ok "the metadata URL addresses the pinned build, not the newest one"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all installer pin checks behave as intended"
else
    echo "${failures} installer pin check(s) misbehaved"
    exit 1
fi
