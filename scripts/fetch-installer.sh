#!/bin/bash
# Produces a VERIFIED Fedora CoreOS live ISO for `just flash` to personalise
# (SPEC.md §spec:installer-media).
#
# uCore ships no installer of its own and cannot be installed directly. It is a
# Fedora CoreOS derivative, and the only supported way to reach it is to install
# Fedora CoreOS and then attach the derived image. This script fetches the half
# of that story the repository does not build.
#
# The release is pinned in versions.env, and FCOS_ISO_SHA256 is the trust
# anchor: it is committed to this repository, so it pins the exact bytes rather
# than merely proving Fedora signed something. Fedora publishes a detached
# signature beside the ISO; verifying that as well would be a second check with
# a keyring to keep correct, and it would not pin the release the way the
# committed digest already does.
#
# The download is cached, and the CACHE IS RE-VERIFIED ON EVERY RUN rather than
# only when it is written. A file that verified once and rotted since is the
# realistic corruption, and it is the one that would otherwise reach a USB stick.
# A cached file that disagrees with the pin is a refusal, never a silent
# re-download: silently replacing it would erase the evidence and turn a
# detected corruption into an invisible one.
#
# Prints the verified path on stdout. Everything else goes to stderr, because
# `just flash` consumes this as a command substitution.
#
# Usage: fetch-installer.sh [repo-root]

set -oue pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOST="$(uname -s)"

fail() {
    echo "fetch-installer: $*" >&2
    exit 1
}

[[ -f "${ROOT}/versions.env" ]] || fail "no versions.env in ${ROOT}"

case "${HOST}" in
    Linux | Darwin) ;;
    *) fail "${HOST:-unknown} is not a supported host for installer verification" ;;
esac

# shellcheck source=/dev/null
. "${ROOT}/versions.env"

for var in FCOS_STREAM FCOS_VERSION FCOS_ISO_SHA256; do
    [[ -n "${!var:-}" ]] || fail "versions.env does not set ${var}"
done

# One target profile: 64-bit x86 (REQUIREMENTS.md §req:quality-attributes).
# ARM boards are out of scope, so the architecture is written down rather than
# detected - a stick built on an ARM laptop for an x86 machine is the case
# detection would get wrong.
ARCH=x86_64

# The published layout of builds.coreos.fedoraproject.org. Constructed from the
# pin rather than read from the stream's metadata index, because that index only
# ever describes the CURRENT release: the moment the pin lags the stream - which
# is the normal state of a pinned dependency - the index stops being able to
# answer. The committed digest is what decides whether the bytes are right.
ISO_NAME="fedora-coreos-${FCOS_VERSION}-live-iso.${ARCH}.iso"
ISO_URL="https://builds.coreos.fedoraproject.org/prod/streams/${FCOS_STREAM}/builds/${FCOS_VERSION}/${ARCH}/${ISO_NAME}"

CACHE="${ROOT}/output/installer"
ISO="${CACHE}/${ISO_NAME}"

# Compare against the pin using the host tool's own check verdict. macOS ships
# shasum; requiring GNU coreutils would break the stock-host contract.
verify() {
    case "${HOST}" in
        Linux)
            printf '%s  %s\n' "${FCOS_ISO_SHA256}" "$1" |
                sha256sum --quiet --check - > /dev/null 2>&1
            ;;
        Darwin)
            printf '%s  %s\n' "${FCOS_ISO_SHA256}" "$1" |
                shasum -a 256 --check - > /dev/null 2>&1
            ;;
    esac
}

actual_digest() {
    case "${HOST}" in
        Linux) sha256sum "$1" | cut -d ' ' -f 1 ;;
        Darwin) shasum -a 256 "$1" | awk '{ print $1 }' ;;
    esac
}

if [[ -e "${ISO}" ]]; then
    if verify "${ISO}"; then
        printf '%s\n' "${ISO}"
        exit 0
    fi
    fail "the cached installer does not match the release pinned in versions.env
    file:     ${ISO}
    expected: ${FCOS_ISO_SHA256}
    actual:   $(actual_digest "${ISO}")
    Nothing was written. Delete that file to fetch it again, or correct
    FCOS_ISO_SHA256 if you meant to change the pinned release."
fi

mkdir -p "${CACHE}"

# Downloaded beside the cache entry and renamed only after it verifies, so an
# interrupted or corrupted download can never be picked up as a good one by the
# next run. mktemp keeps it out of the way of a parallel invocation.
PARTIAL="$(mktemp "${CACHE}/.${ISO_NAME}.XXXXXXXX")"
trap 'rm -f "${PARTIAL}"' EXIT

echo "fetch-installer: downloading Fedora CoreOS ${FCOS_STREAM} ${FCOS_VERSION}" >&2
curl --fail --location --show-error --silent --retry 3 \
    --output "${PARTIAL}" "${ISO_URL}" ||
    fail "could not download ${ISO_URL}"

verify "${PARTIAL}" ||
    fail "the downloaded installer does not match the release pinned in versions.env
    url:      ${ISO_URL}
    expected: ${FCOS_ISO_SHA256}
    actual:   $(actual_digest "${PARTIAL}")
    Nothing was written. The download was discarded."

mv "${PARTIAL}" "${ISO}"
printf '%s\n' "${ISO}"
