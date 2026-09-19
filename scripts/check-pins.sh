#!/bin/bash
# Checks that the repository's version pins agree with each other.
#
# SPEC.md §spec:image-publication requires that a rebuild be a rebuild. That
# holds only while three things stay true, and nothing else in the repository
# notices when one stops:
#
#   - the base image is pinned by digest, not just a moving tag
#   - the Containerfile's FROM and versions.env name the same base image
#   - versions.env records the Fedora CoreOS release the installer comes from,
#     as a checksum `just flash` can actually verify a download against
#   - every pin here is the shape of a pin, rather than a floating tag that
#     would resolve to something new tomorrow
#
# Usage: check-pins.sh [repo-root]

set -oue pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
    echo "check-pins: $*" >&2
    exit 1
}

[[ -f "${ROOT}/Containerfile" ]] || fail "no Containerfile in ${ROOT}"
[[ -f "${ROOT}/versions.env" ]] || fail "no versions.env in ${ROOT}"

# shellcheck source=/dev/null
. "${ROOT}/versions.env"

for var in UCORE_IMAGE UCORE_TAG UCORE_DIGEST FCOS_STREAM FCOS_VERSION FCOS_ISO_SHA256 \
    PORTAINER_IMAGE PORTAINER_TAG PORTAINER_DIGEST \
    COREOS_INSTALLER_IMAGE COREOS_INSTALLER_TAG COREOS_INSTALLER_DIGEST \
    WATCHTOWER_IMAGE WATCHTOWER_TAG WATCHTOWER_DIGEST; do
    [[ -n "${!var:-}" ]] || fail "versions.env does not set ${var}"
done

# A pin that is not the shape of a pin is a floating tag wearing its name.
#
# Neither consumer would accept one: sha256sum refuses a malformed checksum line
# outright, and podman cannot parse `image@release` as a reference at all. This
# check buys WHEN the refusal arrives, not whether - here on a pull request,
# rather than on the operator's machine after a 1.3 GB download. That is the
# same trade the PORTAINER_DIGEST check below already makes.
require_digest() {
    [[ "${!1}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        fail "${1} is not a sha256 digest: ${!1}
    Pin it as sha256: followed by 64 hex characters."
}

# The base image is the only FROM that is not the scratch build-context stage.
from_line="$(grep -E '^FROM ' "${ROOT}/Containerfile" | grep -v '^FROM scratch' || true)"
[[ -n "${from_line}" ]] || fail "Containerfile has no base image FROM line"
[[ "$(wc -l <<< "${from_line}")" -eq 1 ]] || fail "Containerfile has more than one base image FROM line"

from_ref="${from_line#FROM }"

case "${from_ref}" in
    *@sha256:*) ;;
    *) fail "base image is not pinned by digest: ${from_ref}
    A moving tag makes a rebuild a different image. Pin it as image:tag@sha256:..." ;;
esac

from_digest="${from_ref#*@}"
from_image_tag="${from_ref%@*}"
from_image="${from_image_tag%:*}"
from_tag="${from_image_tag##*:}"

[[ "${from_image}" == "${UCORE_IMAGE}" ]] ||
    fail "base image disagrees with versions.env
    Containerfile: ${from_image}
    versions.env:  ${UCORE_IMAGE}"

[[ "${from_tag}" == "${UCORE_TAG}" ]] ||
    fail "base tag disagrees with versions.env
    Containerfile: ${from_tag}
    versions.env:  ${UCORE_TAG}"

[[ "${from_digest}" == "${UCORE_DIGEST}" ]] ||
    fail "base digest disagrees with versions.env
    Containerfile: ${from_digest}
    versions.env:  ${UCORE_DIGEST}"

# Agreeing is not the same as being a digest. The case above only asked whether
# the FROM line contains `@sha256:`, so two files both saying `sha256:latest`
# agreed with each other and passed - a floating tag wearing a digest's clothes,
# in the one pin that decides what the whole image is built from.
require_digest UCORE_DIGEST

# Portainer is pulled by digest alone - skopeo refuses a reference carrying both
# a tag and a digest, so the tag beside it is documentation and the digest is the
# only thing that decides which bytes ship. A digest that is not a digest would
# quietly become a floating tag, and the image would stop being reproducible.
require_digest PORTAINER_DIGEST

# The tool `just flash` personalises the installer with, and the checksum that
# same command verifies the installer against (SPEC.md §spec:installer-media).
require_digest COREOS_INSTALLER_DIGEST

# Watchtower is carried the same way Portainer is, and held to the same pin
# (SPEC.md §spec:container-updates). It earns the check twice over: it is the one
# image on the machine that runs holding the Docker control socket, which is
# root-equivalent, and watchtower-run passes --pull=never so a reference that
# stopped naming these bytes cannot be corrected at runtime - it just fails to
# start, on a machine, with nobody watching.
require_digest WATCHTOWER_DIGEST

[[ "${FCOS_ISO_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
    fail "FCOS_ISO_SHA256 is not a sha256 checksum: ${FCOS_ISO_SHA256}
    It is the bare 64-character digest of the live ISO, with no sha256: prefix."

# The pin is only a pin while the build reads it from here. A digest written
# straight into build.sh would still produce a working image, so nothing else
# would notice - versions.env would quietly become decorative and Renovate would
# keep bumping a number nothing consumes.
build_sh="${ROOT}/build_files/build.sh"
[[ -f "${build_sh}" ]] || fail "no build_files/build.sh in ${ROOT}"

# Literal, not expanded: we are looking for the reference itself in the source.
# shellcheck disable=SC2016
grep -q '${PORTAINER_DIGEST}' "${build_sh}" ||
    fail "build_files/build.sh does not read PORTAINER_DIGEST from versions.env
    Pull Portainer as \${PORTAINER_IMAGE}@\${PORTAINER_DIGEST}, never a literal digest."

# shellcheck disable=SC2016
grep -q '${WATCHTOWER_DIGEST}' "${build_sh}" ||
    fail "build_files/build.sh does not read WATCHTOWER_DIGEST from versions.env
    Pull Watchtower as \${WATCHTOWER_IMAGE}@\${WATCHTOWER_DIGEST}, never a literal digest."

if literal="$(grep -nE 'sha256:[0-9a-f]{64}' "${build_sh}")"; then
    fail "build_files/build.sh carries a literal digest:
    ${literal}
    Digests belong in versions.env, which check-pins.sh and Renovate both watch."
fi

# A malformed cosign.pub already fails closed at publish time, when the workflow
# verifies its own signature against it. Checking here buys the same answer on
# the pull request instead of after merge. It cannot detect the case that
# matters more - a key that parses but does not match SIGNING_SECRET - which
# only that publish-time verify catches.
[[ -f "${ROOT}/cosign.pub" ]] || fail "cosign.pub is missing"
openssl pkey -pubin -noout -in "${ROOT}/cosign.pub" 2> /dev/null ||
    fail "cosign.pub does not parse as a public key"

echo "check-pins: ${UCORE_IMAGE}:${UCORE_TAG} pinned by digest; Fedora CoreOS ${FCOS_STREAM} ${FCOS_VERSION}; Portainer ${PORTAINER_TAG}, Watchtower ${WATCHTOWER_TAG} and coreos-installer ${COREOS_INSTALLER_TAG} pinned by digest"
