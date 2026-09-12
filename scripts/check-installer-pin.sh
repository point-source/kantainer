#!/bin/bash
# Confirms the pinned Fedora CoreOS release still describes the bytes versions.env
# claims (SPEC.md §spec:installer-media).
#
# WHY THIS EXISTS. FCOS_VERSION and FCOS_ISO_SHA256 are two halves of one pin, and
# only a human or a bot ever moves them. Renovate can raise the version - it reads
# Fedora's own build index - but it cannot hash a 1.3 GB ISO, so it leaves the
# checksum behind. A pull request in that state passes every offline check in this
# repository and produces a `just flash` that refuses on the operator's machine
# after a 1.3 GB download. This turns that into a red pull request instead.
#
# WHY IT IS NOT IN `just ci`. It reaches the network. `just ci` is offline and
# deterministic on purpose, so every batch can run it anywhere; a gate that needs
# builds.coreos.fedoraproject.org would be a gate that fails on a train. It runs as
# its own step in .github/workflows/ci.yml, where the network already exists.
#
# It checks Fedora's own metadata for the pinned build rather than the newest one:
# being behind the stream is the normal state of a pin and is not what this catches.
# What it catches is a pin that does not describe a real, matching artifact.
#
# Usage: check-installer-pin.sh [repo-root]

set -oue pipefail

fail() {
    echo "check-installer-pin: $*" >&2
    exit 1
}

# One target profile: 64-bit x86, the same architecture scripts/fetch-installer.sh
# writes down for the same reason (REQUIREMENTS.md §req:quality-attributes).
KANTAINER_ARCH=x86_64

# Fedora's published metadata for one build. Replaced by the tests, which have no
# network and no business downloading anything to check a comparison.
kantainer_fetch_meta() {
    curl --fail --location --show-error --silent --retry 3 --max-time 60 "$1"
}

kantainer_meta_url() {
    local stream="$1" version="$2" arch="$3"
    printf 'https://builds.coreos.fedoraproject.org/prod/streams/%s/builds/%s/%s/meta.json\n' \
        "${stream}" "${version}" "${arch}"
}

# The filename fetch-installer.sh downloads. Written out in both places on purpose,
# the same way scripts/test-installer.sh does: a change to this naming should have
# to be made twice deliberately rather than once by accident. The check below
# compares it against the name Fedora actually published, so a drift is caught here
# rather than by a 404 on the operator's machine.
kantainer_expected_iso_name() {
    local version="$1" arch="$2"
    printf 'fedora-coreos-%s-live-iso.%s.iso\n' "${version}" "${arch}"
}

# The comparison itself, split out so it can be driven from fixtures.
kantainer_check_installer_pin() {
    local meta="$1" version="$2" want_sha="$3" arch="$4"
    local got_path got_sha want_path

    got_path="$(jq -r '.images["live-iso"].path // empty' <<< "${meta}")"
    got_sha="$(jq -r '.images["live-iso"].sha256 // empty' <<< "${meta}")"

    [[ -n "${got_path}" && -n "${got_sha}" ]] ||
        fail "Fedora's metadata for ${version} describes no live ISO.
    Checked .images[\"live-iso\"].path and .sha256 and found nothing there.
    Either the pin names a build that does not exist, or the published layout
    changed and this check needs updating."

    want_path="$(kantainer_expected_iso_name "${version}" "${arch}")"
    [[ "${got_path}" == "${want_path}" ]] ||
        fail "the installer filename this repository builds does not match Fedora's.
    we download:   ${want_path}
    Fedora ships:  ${got_path}
    scripts/fetch-installer.sh would request a URL that does not exist."

    [[ "${got_sha}" == "${want_sha}" ]] ||
        fail "FCOS_ISO_SHA256 does not match Fedora CoreOS ${version}.
    versions.env: ${want_sha}
    Fedora says:  ${got_sha}

    If the version was just raised - by Renovate, or by hand - the checksum is
    the half that did not move with it. Set FCOS_ISO_SHA256 to the value above.
    Until then \`just flash\` refuses the download on the operator's machine,
    which is a worse place to find this out than here."

    echo "check-installer-pin: Fedora CoreOS ${FCOS_STREAM-} ${version} matches ${got_path}"
}

main() {
    local root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}" meta url

    [[ -f "${root}/versions.env" ]] || fail "no versions.env in ${root}"
    # shellcheck source=/dev/null
    . "${root}/versions.env"

    for var in FCOS_STREAM FCOS_VERSION FCOS_ISO_SHA256; do
        [[ -n "${!var:-}" ]] || fail "versions.env does not set ${var}"
    done

    url="$(kantainer_meta_url "${FCOS_STREAM}" "${FCOS_VERSION}" "${KANTAINER_ARCH}")"
    meta="$(kantainer_fetch_meta "${url}")" ||
        fail "could not read Fedora's metadata at ${url}
    A pinned build that 404s is a pin naming a release that was never published,
    or one Fedora has since withdrawn."

    kantainer_check_installer_pin \
        "${meta}" "${FCOS_VERSION}" "${FCOS_ISO_SHA256}" "${KANTAINER_ARCH}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
